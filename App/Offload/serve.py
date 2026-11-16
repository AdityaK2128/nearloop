# SPDX-License-Identifier: Apache-2.0
"""Run the installed oMLX with the iPhone prefill hook (Nearloop › Experimental).

    python3 serve.py serve --model-dir DIR --port 8000 ...   (arguments go to `omlx`)

Nothing in oMLX.app is modified. An import hook serves `omlx.phone_prefill` and
`omlx.phone_control` from this folder and inserts one call into the source of
`omlx.scheduler` as it is imported, at the start of the prefill loop in
`_do_external_prefill`. If that loop can't be found (an oMLX version this
doesn't know), the server runs unchanged and the status file says why.
"""

from __future__ import annotations

import importlib.abc
import importlib.machinery
import importlib.util
import json
import os
import runpy
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
EXTRA = {
    "omlx.load_fixes": os.path.join(HERE, "load_fixes.py"),
    "omlx.phone_prefill": os.path.join(HERE, "phone_prefill.py"),
    "omlx.phone_control": os.path.join(HERE, "phone_control.py"),
}

HOOK = """\
        # Nearloop: a connected iPhone runs the model's last layers for long prompts.
        from .phone_prefill import run_from_locals as _nearloop_phone_prefill
        _nearloop_phone_done = _nearloop_phone_prefill(self, locals())
        if _nearloop_phone_done:
            processed_tokens += _nearloop_phone_done
            with mx.stream(self._stream):
                input_arr = input_arr[:, _nearloop_phone_done:]

"""

PATCH = {"applied": False, "detail": "oMLX's scheduler was not loaded"}


def patch_scheduler(source: str) -> str:
    """Insert HOOK before the first prefill loop of _do_external_prefill."""
    start = source.find("    def _do_external_prefill(")
    if start < 0:
        raise LookupError("no _do_external_prefill in this oMLX")
    end = source.find("\n    def ", start + 10)
    loop = source.find("\n        while input_arr.shape[1] > 0:\n", start, end if end > 0 else None)
    if loop < 0:
        raise LookupError("the prefill loop of _do_external_prefill has changed")
    body = source[start:loop]
    for name in ("processed_tokens", "input_arr", "prefill_tokens", "prompt_cache", "self._stream"):
        if name not in body:
            raise LookupError(f"_do_external_prefill no longer defines {name}")
    return source[: loop + 1] + HOOK + source[loop + 1 :]


class _PatchedScheduler(importlib.machinery.SourceFileLoader):
    def get_code(self, fullname):
        source = self.get_data(self.path).decode("utf-8")
        try:
            source = patch_scheduler(source)
            PATCH.update(applied=True, detail="iPhone hook installed")
        except LookupError as exc:
            PATCH.update(applied=False, detail=f"This oMLX version can't use the iPhone: {exc}")
        # Compiled fresh every time: a cached .pyc would be the unpatched module.
        return compile(source, self.path, "exec", dont_inherit=True)


class _Finder(importlib.abc.MetaPathFinder):
    def find_spec(self, name, path=None, target=None):
        if name in EXTRA:
            return importlib.util.spec_from_file_location(name, EXTRA[name])
        if name == "omlx.scheduler":
            spec = importlib.machinery.PathFinder.find_spec(name, path)
            if spec is not None and spec.origin and spec.origin.endswith(".py"):
                spec.loader = _PatchedScheduler(name, spec.origin)
                return spec
            PATCH.update(applied=False, detail="oMLX's scheduler ships without source; the iPhone can't be used")
        return None


def _context_of(entry: dict) -> int | None:
    for value in (entry.get("max_model_len"), os.environ.get("NEARLOOP_MODEL_CONTEXT")):
        try:
            if value and int(value) > 0:
                return int(value)
        except (TypeError, ValueError):
            pass
    return None


def kapitsa_model_list(body: bytes) -> bytes:
    """Lists the served model the way Kapitsa's /v1/models does, so `kapitsa claude`, `kapitsa codex`,
    `kapitsa opencode` and `kapitsa pi` (from Nearloop or any terminal) use this server instead of refusing
    the port: the first entry must be owned by "nace" and give its context_length. oMLX serves the APIs
    those agents call (/v1/messages, /v1/responses, /v1/chat/completions); only this listing differs."""
    try:
        listing = json.loads(body)
        models = listing["data"]
    except (ValueError, KeyError, TypeError):
        return body
    served, others = [], []
    for entry in models:
        context = _context_of(entry) if isinstance(entry, dict) else None
        # Helpers such as oMLX's markitdown converter have no context window; they stay oMLX's.
        if context is None or entry.get("id") == "markitdown":
            others.append(entry)
            continue
        served.append({**entry, "owned_by": "nace", "context_length": context})
    listing["data"] = served + others
    return json.dumps(listing).encode()


class _KapitsaModels:
    """ASGI middleware: rewrites GET /v1/models with kapitsa_model_list; every other request passes through."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope.get("type") != "http" or scope.get("method") != "GET" or scope.get("path", "").rstrip("/") != "/v1/models":
            return await self.app(scope, receive, send)
        start, chunks = {}, []

        async def capture(message):
            if message["type"] == "http.response.start":
                start.update(message)
                return
            if message["type"] != "http.response.body":
                return await send(message)
            chunks.append(message.get("body", b""))
            if message.get("more_body"):
                return
            body = b"".join(chunks)
            if start.get("status") == 200:
                body = kapitsa_model_list(body)
            headers = [(k, v) for k, v in start.get("headers", []) if k.lower() != b"content-length"]
            await send({**start, "headers": headers + [(b"content-length", str(len(body)).encode())]})
            await send({"type": "http.response.body", "body": body})

        await self.app(scope, receive, capture)


def _argument(name: str) -> str | None:
    args = sys.argv[1:]
    for i, arg in enumerate(args):
        if arg == name and i + 1 < len(args):
            return args[i + 1]
        if arg.startswith(name + "="):
            return arg.split("=", 1)[1]
    return None


def choose_drafter() -> None:
    """Speculative decoding as Kapitsa does it: with the model's DFlash drafter (NEARLOOP_DFLASH_DRAFT, the
    folder Nearloop pairs with the model, quantized to 4 bits as Kapitsa runs it) instead of an MTP head,
    which drafts fewer tokens per step. Without a drafter the model keeps oMLX's own choice. Written to
    oMLX's per-model settings before it starts; a model new to them first gets oMLX's recommended sampling
    values, as oMLX itself would give it."""
    model_id, base, model_dir = os.environ.get("NEARLOOP_MODEL_ID"), _argument("--base-path"), _argument("--model-dir")
    draft = os.environ.get("NEARLOOP_DFLASH_DRAFT") or None
    if not (model_id and base and model_dir):
        return
    path, model_path = os.path.join(base, "model_settings.json"), os.path.join(model_dir, model_id)
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError):
        data = {}
    if not isinstance(data, dict) or not isinstance(data.get("models", {}), dict):
        data = {}
    data.setdefault("version", 1)
    models = data.setdefault("models", {})
    entry = models.get(model_id)
    if not isinstance(entry, dict):
        if not draft:
            return  # oMLX gives a new model its own defaults, an MTP head included
        entry = {}
        try:
            from omlx.utils.generation_config import load_sampling_defaults

            with open(os.path.join(model_path, "config.json")) as f:
                model_type = json.load(f).get("model_type")
            entry.update(load_sampling_defaults(model_path, model_type))
        except Exception as exc:  # noqa: BLE001 - sampling then follows each request
            print(f"Nearloop: no sampling defaults for {model_id}: {exc}", file=sys.stderr)
    if draft:
        entry.update(dflash_enabled=True, mtp_enabled=False, dflash_draft_model=draft,
                     dflash_draft_quant_enabled=True, dflash_draft_quant_weight_bits=4,
                     dflash_draft_quant_group_size=64)
    elif entry.get("dflash_enabled"):
        # The drafter is gone (or unpaired): back to the model's MTP head when it has one.
        entry["dflash_enabled"] = False
        try:
            from omlx.utils.model_loading import _is_mtp_compatible

            with open(os.path.join(model_path, "config.json")) as f:
                config = json.load(f)
            entry["mtp_enabled"] = bool(_is_mtp_compatible(config, config.get("model_type")))
        except Exception:  # noqa: BLE001 - leave MTP as it was
            pass
    else:
        return
    models[model_id] = entry
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)


def main() -> None:
    sys.meta_path.insert(0, _Finder())
    # Report whether the hook went in, once oMLX has imported its scheduler.
    import omlx.scheduler  # noqa: F401  (imported here so the patch result is known)
    from omlx.phone_control import control

    # Checkpoints the stock loaders get wrong (a `visual.*` vision encoder, zero-centred norms) load right (load_fixes.py).
    from omlx.load_fixes import install as _install_load_fixes

    _install_load_fixes()
    try:
        choose_drafter()
    except Exception as exc:  # noqa: BLE001 - the model still loads, drafting as oMLX chooses
        print(f"Nearloop: couldn't set the DFlash drafter: {exc}", file=sys.stderr)

    # uvicorn loads "omlx.server:app" by name, so this module object is the one it serves.
    try:
        import omlx.server

        omlx.server.app.add_middleware(_KapitsaModels)
    except Exception as exc:  # an oMLX without this app: chat still works, agents can't attach
        print(f"Nearloop: agents can't use this server: {exc}", file=sys.stderr)

    control.note("idle" if PATCH["applied"] else "unsupported",
                 "Waiting for a long prompt" if PATCH["applied"] else PATCH["detail"],
                 hook=PATCH)
    control.config()
    sys.argv = ["omlx"] + sys.argv[1:]
    runpy.run_module("omlx.cli", run_name="__main__", alter_sys=True)


if __name__ == "__main__":
    main()
