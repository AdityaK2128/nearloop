"""Running a slice of an mlx-lm model's decoder layers.

Handles two families of decoders:

- dense attention models (Qwen3, Qwen2, Llama, Mistral): every layer has a
  KVCache that grows by one entry per token;
- Qwen3.5-family hybrids (Qwen3.5/3.6/3.8, dense or MoE): three of every four
  layers are Gated DeltaNet linear attention, whose cache is a fixed-size
  ArraysCache of [conv_state, recurrent_state]; the rest are gated attention
  with a KVCache.

Sliding windows, quantized KV caches and other cache types are rejected.
"""

import hashlib

import mlx.core as mx
import numpy as np
from mlx.utils import tree_flatten
from mlx_lm.models.base import create_attention_mask, create_ssm_mask
from mlx_lm.models.cache import ArraysCache, KVCache, make_prompt_cache

SUPPORTED_MODEL_TYPES = {"qwen3", "qwen2", "llama", "mistral", "qwen3_5", "qwen3_5_moe"}


def text_args(model):
    """The decoder's config: multimodal wrappers keep it on language_model."""
    return getattr(model, "language_model", model).args


def is_linear(layer) -> bool:
    return getattr(layer, "is_linear", False)


def check_supported(model):
    model_type = model.args.model_type
    if model_type not in SUPPORTED_MODEL_TYPES:
        raise SystemExit(
            f"model_type {model_type!r} is not supported by the split prototype "
            f"(supported: {', '.join(sorted(SUPPORTED_MODEL_TYPES))})"
        )
    for layer, cache in zip(model.layers, make_prompt_cache(model)):
        expected = ArraysCache if is_linear(layer) else KVCache
        if type(cache) is not expected:
            raise SystemExit(f"unsupported cache {type(cache).__name__} on a {type(layer).__name__}")


def fingerprint(model) -> str:
    """Identifies the exact weights, so a worker can't serve a shard cut from another model."""
    digest = hashlib.sha256()
    for _, w in sorted(tree_flatten(model.layers[-1].parameters()))[:4]:
        if w.dtype == mx.bfloat16:
            w = w.view(mx.uint16)
        digest.update(np.asarray(w).tobytes())
    return digest.hexdigest()[:16]


def model_info(model) -> dict:
    """The facts a worker checks before accepting a session."""
    args = text_args(model)
    return {
        "model_type": model.args.model_type,
        "num_layers": len(model.layers),
        "hidden_size": args.hidden_size,
        "num_kv_heads": args.num_key_value_heads,
        "head_dim": getattr(args, "head_dim", None)
        or args.hidden_size // args.num_attention_heads,
        "fingerprint": fingerprint(model),
    }


def embed(model, token_ids) -> mx.array:
    return model.model.embed_tokens(mx.array(token_ids)[None])


def run_layers(layers, h: mx.array, caches) -> mx.array:
    """Push hidden states through consecutive decoder layers, filling their caches."""
    attention = next((c for l, c in zip(layers, caches) if not is_linear(l)), None)
    linear = next((c for l, c in zip(layers, caches) if is_linear(l)), None)
    attention_mask = create_attention_mask(h, attention)
    linear_mask = create_ssm_mask(h, linear) if linear is not None else None
    for layer, cache in zip(layers, caches):
        h = layer(h, linear_mask if is_linear(layer) else attention_mask, cache)
    return h


def kv_caches(layers, caches):
    return [c for l, c in zip(layers, caches) if not is_linear(l)]


def linear_caches(layers, caches):
    return [c for l, c in zip(layers, caches) if is_linear(l)]


def chunk_kv(caches, offset: int, n: int) -> mx.array:
    """K and V that KV `caches` gained for positions [offset, offset + n), as [L, 2, H, n, Dh]."""
    return mx.stack(
        [
            mx.stack([c.keys[0, :, offset : offset + n], c.values[0, :, offset : offset + n]])
            for c in caches
        ]
    )


def append_kv(caches, kv: mx.array):
    """Append a [L, 2, H, n, Dh] block of KV to the matching caches."""
    for cache, layer_kv in zip(caches, kv):
        cache.update_and_fetch(layer_kv[0][None], layer_kv[1][None])


def linear_state(caches):
    """The [conv_state, recurrent_state] arrays of each linear-attention cache, in order."""
    return [array for c in caches for array in (c[0], c[1])]


def set_linear_state(caches, arrays):
    for i, cache in enumerate(caches):
        cache[0], cache[1] = arrays[2 * i], arrays[2 * i + 1]
