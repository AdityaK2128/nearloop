# SPDX-License-Identifier: Apache-2.0
"""Loads MLX checkpoints that the stock mlx-lm and mlx-vlm loaders get wrong, in two ways.

1. Vision encoder under a top-level `visual.` prefix. Some MLX conversions of Qwen-VL-style models
   (Qwen3.5/3.6/3.8 with vision) save the encoder as `visual.*` instead of `vision_tower.*` or
   `model.visual.*`. mlx-lm then rejects them ("parameters not in model") when loading the text
   decoder, and mlx-vlm does too, since it only renames the other spellings. Both sanitize steps convert
   weights by suffix (conv layouts, norm offsets), so only the prefix is in the way: it is renamed to
   `vision_tower.` when the model has a vision tower and dropped when the model is the text decoder alone.
   A model whose own class has a `visual` attribute is left alone.

2. Zero-centred RMSNorm weights in an already-converted checkpoint. Qwen3.5-family models store their
   norms as `w` and compute with `1 + w`; MLX's port computes with `w`, so its sanitize adds 1, but only
   when it sees an unconverted checkpoint (conv1d weights in PyTorch layout). A checkpoint saved with
   MLX-layout conv weights and the original norms then loads without the 1 and writes garbage. The
   weights tell which it is: converted layer norms average near 1, original ones near 0. When a Qwen3.5-
   family model's layer norms average under 0.4, the same norms mlx-lm's sanitize would shift get 1 added,
   including those of a multi-token-prediction head (`mtp.*`), whose drafts are otherwise all rejected.

Every other key, and every other model, loads as before.
"""

from __future__ import annotations

_installed = False

# The model types whose MLX port expects norms already shifted by 1 (mlx-lm qwen3_5 / qwen3_5_moe /
# qwen3_next sanitize), and the norm weights that sanitize shifts.
_SHIFTED_NORM_TYPES = {"qwen3_5", "qwen3_5_text", "qwen3_5_moe", "qwen3_5_moe_text", "qwen3_next"}
_NORM_SUFFIXES = (".input_layernorm.weight", ".post_attention_layernorm.weight", "model.norm.weight",
                  ".q_norm.weight", ".k_norm.weight",
                  # The multi-token-prediction head's own norms (oMLX's MTP sanitize shifts these too).
                  ".pre_fc_norm_hidden.weight", ".pre_fc_norm_embedding.weight", "mtp.norm.weight")
_LAYER_NORMS = (".input_layernorm.weight", ".post_attention_layernorm.weight")


def _has(module, name: str) -> bool:
    try:
        return hasattr(module, name)
    except Exception:  # noqa: BLE001 - an odd module: leave its keys alone
        return True


def _model_type(model) -> str:
    for obj in (model, getattr(model, "language_model", None)):
        for holder in ("args", "config"):
            value = getattr(getattr(obj, holder, None), "model_type", None) if obj is not None else None
            if isinstance(value, str):
                return value
    return ""


def _rename_visual(model, items):
    vision = _has(model, "vision_tower") and not _has(model, "visual")
    language = getattr(model, "language_model", None)
    fixed, changed = [], False
    for key, value in items:
        if key.startswith("visual.") and not _has(model, "visual"):
            changed = True
            if not vision:
                continue  # the text decoder alone: the vision encoder isn't used
            key = "vision_tower." + key[len("visual."):]
        elif key.startswith("language_model.visual.") and language is not None and not _has(language, "visual"):
            changed = True
            if not vision:
                continue
            key = "vision_tower." + key[len("language_model.visual."):]
        fixed.append((key, value))
    return fixed if changed else items


def _shift_norms(model, items):
    if _model_type(model) not in _SHIFTED_NORM_TYPES:
        return items
    import mlx.core as mx

    layer_norms = [v for k, v in items if k.endswith(_LAYER_NORMS) and getattr(v, "ndim", 0) == 1]
    if not layer_norms:
        return items
    average = mx.mean(mx.stack([v.astype(mx.float32).mean() for v in layer_norms])).item()
    if average >= 0.4:
        return items
    return [(k, v + 1.0 if k.endswith(_NORM_SUFFIXES) and getattr(v, "ndim", 0) == 1 else v) for k, v in items]


def install() -> None:
    """Patches mlx.nn.Module.load_weights and, when present, mlx-vlm's sanitize step, once per process.

    mlx-vlm has to see the new vision names before it sanitizes: it quantizes a layer only when the
    checkpoint has `<layer>.scales` under the layer's own name, and a 4-bit vision tower would otherwise be
    built unquantized and refuse its weights. Norms are shifted at load, after either library's sanitize.
    """
    global _installed
    if _installed:
        return
    import mlx.nn as nn

    original = nn.Module.load_weights

    def load_weights(self, file_or_weights, *args, **kwargs):
        if not isinstance(file_or_weights, str):
            file_or_weights = _shift_norms(self, _rename_visual(self, list(file_or_weights)))
        return original(self, file_or_weights, *args, **kwargs)

    nn.Module.load_weights = load_weights

    try:
        import mlx_vlm.utils as vlm_utils
    except Exception:  # noqa: BLE001 - mlx-lm only: nothing more to do
        vlm_utils = None
    if vlm_utils is not None and hasattr(vlm_utils, "sanitize_weights"):
        sanitize = vlm_utils.sanitize_weights

        def sanitize_weights(model_obj, weights, config=None):
            if config is None and isinstance(model_obj, nn.Module) and isinstance(weights, dict):
                items = list(weights.items())
                fixed = _rename_visual(model_obj, items)
                if fixed is not items:
                    weights = dict(fixed)
            return sanitize(model_obj, weights, config)

        vlm_utils.sanitize_weights = sanitize_weights
    _installed = True
