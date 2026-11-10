"""Cut the last N decoder layers of an MLX model into one file for the Swift tail worker.

    python mac/export_tail.py --model mlx-community/Qwen3-1.7B-4bit --tail-layers 8 \\
        --out shards/qwen3-1.7b-tail8.safetensors

The file holds those layers' weights exactly as mlx-lm loaded them (still
quantized, mixed precision included) plus a JSON spec under the "getfaster"
metadata key telling the worker how to run them. The spec is read off the
loaded mlx-lm modules, so the worker never has to interpret a Hugging Face
config. Only the exported layers are read from disk.
"""

import argparse
import json
import os

import mlx.core as mx
import mlx.nn as nn
from mlx.utils import tree_flatten
from mlx_lm import load

import splitmodel

FORMAT = "getfaster-tail/2"

_QUANT = ("weight", "scales", "biases", "bias")


def _params(prefix, modules, suffixes=_QUANT):
    return {f"{prefix}.{m}.{s}" for m in modules for s in suffixes}


# Every parameter each kind of block may have. Anything else means the Swift
# worker would compute something different, so export refuses.
_ALLOWED = {
    "attention": _params("self_attn", ["q_proj", "k_proj", "v_proj", "o_proj"])
    | {"self_attn.q_norm.weight", "self_attn.k_norm.weight"},
    "linear": _params("linear_attn", ["in_proj_qkv", "in_proj_z", "in_proj_b", "in_proj_a", "out_proj"])
    | {"linear_attn.conv1d.weight", "linear_attn.dt_bias", "linear_attn.A_log", "linear_attn.norm.weight"},
    "dense": _params("mlp", ["gate_proj", "up_proj", "down_proj"]),
    "moe": _params("mlp", ["gate", "shared_expert_gate"])
    | _params("mlp.switch_mlp", ["gate_proj", "up_proj", "down_proj"])
    | _params("mlp.shared_expert", ["gate_proj", "up_proj", "down_proj"]),
    "norms": {"input_layernorm.weight", "post_attention_layernorm.weight"},
}


def rope_spec(rope):
    if type(rope) is nn.RoPE:
        return {"dims": rope.dims, "traditional": rope.traditional,
                "base": float(rope.base), "scale": float(rope.scale)}, None
    freqs = getattr(rope, "_freqs", None)
    if freqs is not None and type(rope).__name__ == "Llama3RoPE":
        # Llama 3 scaling is plain fast.rope with precomputed frequencies.
        return {"dims": rope.dims, "traditional": rope.traditional,
                "base": None, "scale": 1.0}, freqs
    raise SystemExit(f"RoPE variant {type(rope).__name__} is not supported by the Swift worker yet")


def layer_kind(layer):
    if splitmodel.is_linear(layer):
        mixer = "linear"
    elif type(layer.self_attn).__name__ == "Qwen3NextAttention":
        mixer = "gated_attention"  # q_proj also yields a sigmoid gate on the output
    else:
        mixer = "attention"
    mlp = "moe" if type(layer.mlp).__name__ == "Qwen3NextSparseMoeBlock" else "dense"
    return {"mixer": mixer, "mlp": mlp}


def export(model, tail_start: int):
    layers = model.layers
    kinds = [layer_kind(layers[i]) for i in range(tail_start, len(layers))]
    spec = {
        "format": FORMAT,
        **splitmodel.model_info(model),
        "tail_start": tail_start,
        "rms_norm_eps": float(layers[tail_start].input_layernorm.eps),
        "layers": kinds,
        "quantized": {},
    }

    attention = next((layers[i].self_attn for i in range(tail_start, len(layers))
                      if not splitmodel.is_linear(layers[i])), None)
    freqs = None
    if attention is not None:
        rope, freqs = rope_spec(attention.rope)
        spec["attention"] = {
            "num_heads": getattr(attention, "n_heads", None) or attention.num_attention_heads,
            "num_kv_heads": getattr(attention, "n_kv_heads", None) or attention.num_key_value_heads,
            "head_dim": spec["head_dim"],
            "scale": float(attention.scale),
            "rope": rope,
        }
    linear = next((layers[i].linear_attn for i in range(tail_start, len(layers))
                   if splitmodel.is_linear(layers[i])), None)
    if linear is not None:
        spec["linear"] = {
            "num_v_heads": linear.num_v_heads, "num_k_heads": linear.num_k_heads,
            "head_k_dim": linear.head_k_dim, "head_v_dim": linear.head_v_dim,
            "conv_kernel": linear.conv_kernel_size, "norm_eps": float(linear.norm.eps),
        }
    moe = next((layers[i].mlp for i in range(tail_start, len(layers))
                if layer_kind(layers[i])["mlp"] == "moe"), None)
    if moe is not None:
        spec["moe"] = {"num_experts": moe.num_experts, "top_k": moe.top_k,
                       "norm_topk_prob": bool(moe.norm_topk_prob)}

    arrays = {}
    for i, kind in zip(range(tail_start, len(layers)), kinds):
        layer = layers[i]
        allowed = _ALLOWED["attention" if kind["mixer"] != "linear" else "linear"] \
            | _ALLOWED[kind["mlp"]] | _ALLOWED["norms"]
        params = dict(tree_flatten(layer.parameters()))
        unknown = set(params) - allowed
        if unknown:
            raise SystemExit(f"layer {i} has parameters the Swift worker can't run: {sorted(unknown)}")
        for name, value in params.items():
            arrays[f"layers.{i}.{name}"] = value
        for path, module in layer.named_modules():
            if hasattr(module, "bits") and hasattr(module, "group_size"):
                spec["quantized"][f"layers.{i}.{path}"] = {
                    "bits": module.bits, "group_size": module.group_size,
                    "mode": getattr(module, "mode", "affine")}
    if freqs is not None:
        arrays["rope.freqs"] = freqs
    return arrays, spec


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--model", required=True)
    parser.add_argument("--tail-layers", type=int, required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    model, _ = load(args.model, lazy=True)
    splitmodel.check_supported(model)
    tail_start = len(model.layers) - args.tail_layers
    if not 0 < tail_start < len(model.layers):
        raise SystemExit(f"--tail-layers must be between 1 and {len(model.layers) - 1}")

    arrays, spec = export(model, tail_start)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    mx.save_safetensors(args.out, arrays, metadata={"getfaster": json.dumps(spec)})
    size = sum(a.nbytes for a in arrays.values())
    mixers = [k["mixer"] for k in spec["layers"]]
    print(f"wrote {args.out}: layers {tail_start}..{len(model.layers) - 1} "
          f"({mixers.count('linear')} linear-attention, {len(mixers) - mixers.count('linear')} attention), "
          f"{len(arrays)} tensors, {size / 1e9:.2f} GB")


if __name__ == "__main__":
    main()
