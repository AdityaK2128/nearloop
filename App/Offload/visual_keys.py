# SPDX-License-Identifier: Apache-2.0
"""Loads checkpoints that keep their vision encoder under a top-level `visual.` prefix.

Some MLX conversions of Qwen-VL-style models (Qwen3.5/3.6/3.8 with vision) save the encoder as
`visual.*` instead of `vision_tower.*` or `model.visual.*`. mlx-lm then rejects them ("parameters not
in model") when loading the text decoder, and mlx-vlm does too, since it only renames the other
spellings. Both sanitize steps convert weights by suffix (conv layouts, norm offsets), so only the
prefix is in the way: this renames it to `vision_tower.` when the model has a vision tower and drops
it when the model is the text decoder alone. A model whose own class has a `visual` attribute is
left alone, as is every key that already loads.
"""

from __future__ import annotations

_installed = False


def _has(module, name: str) -> bool:
    try:
        return hasattr(module, name)
    except Exception:  # noqa: BLE001 - an odd module: leave its keys alone
        return True


def _fix(model, items):
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


def install() -> None:
    """Patches mlx.nn.Module.load_weights and, when present, mlx-vlm's sanitize step, once per process.

    mlx-vlm has to see the new names before it sanitizes: it quantizes a layer only when the checkpoint
    has `<layer>.scales` under the layer's own name, and a 4-bit vision tower would otherwise be built
    unquantized and refuse its weights. mlx-lm loads the text decoder only, so dropping at load is enough.
    """
    global _installed
    if _installed:
        return
    import mlx.nn as nn

    original = nn.Module.load_weights

    def load_weights(self, file_or_weights, *args, **kwargs):
        if not isinstance(file_or_weights, str):
            file_or_weights = _fix(self, list(file_or_weights))
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
                fixed = _fix(model_obj, items)
                if fixed is not items:
                    weights = dict(fixed)
            return sanitize(model_obj, weights, config)

        vlm_utils.sanitize_weights = sanitize_weights
    _installed = True
