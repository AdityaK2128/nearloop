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
import os
import runpy
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
EXTRA = {
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


def main() -> None:
    sys.meta_path.insert(0, _Finder())
    # Report whether the hook went in, once oMLX has imported its scheduler.
    import omlx.scheduler  # noqa: F401  (imported here so the patch result is known)
    from omlx.phone_control import control

    control.note("idle" if PATCH["applied"] else "unsupported",
                 "Waiting for a long prompt" if PATCH["applied"] else PATCH["detail"],
                 hook=PATCH)
    control.config()
    sys.argv = ["omlx"] + sys.argv[1:]
    runpy.run_module("omlx.cli", run_name="__main__", alter_sys=True)


if __name__ == "__main__":
    main()
