# SPDX-License-Identifier: Apache-2.0
"""Settings and live status for the iPhone prefill worker, as Nearloop runs it.

Based on getFaster's phone_control. Nearloop owns two small JSON files:

    NEARLOOP_PHONE_CONFIG   settings it writes; re-read whenever the file changes,
                            so switching the phone on and off needs no restart
    NEARLOOP_PHONE_STATUS   live status this module writes; the app reads it

Scheduler threads take one configuration snapshot per request; changing
settings never interrupts GPU work. Nothing here touches MLX.
"""

from __future__ import annotations

import copy
import json
import logging
import os
import tempfile
import threading
import time
from pathlib import Path

logger = logging.getLogger(__name__)

DEFAULTS = {"enabled": False, "address": "auto", "min_tokens": 2048, "chunk": 0,
            "max_seed_mb": 2000, "max_inflight": 2}


def validate(config: dict) -> dict:
    merged = {**DEFAULTS, **{k: v for k, v in config.items() if k in DEFAULTS}}
    if type(merged["enabled"]) is not bool:
        raise ValueError("enabled must be true or false")
    address = merged["address"]
    if not isinstance(address, str):
        raise ValueError("Worker address must be text")
    address = address.strip()
    if address != "auto":
        host, sep, port = address.rpartition(":")
        if (not sep or not host or not port.isascii() or not port.isdigit()
                or not 1 <= int(port) <= 65535 or any(c.isspace() for c in address)
                or (":" in host and not (host.startswith("[") and host.endswith("]")))
                or any(c in address for c in "/?#@")):
            raise ValueError("Use auto, host:port, or [IPv6%interface]:port")
    for key, low, high in (("min_tokens", 1, 1_000_000), ("chunk", 0, 32768),
                           ("max_seed_mb", 0, 16384), ("max_inflight", 1, 4)):
        if type(merged[key]) is not int or not low <= merged[key] <= high:
            raise ValueError(f"{key} must be an integer from {low} to {high}")
    return {**merged, "address": address}


def _write_atomic(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix=".status-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as out:
            json.dump(data, out)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


class PhoneControl:
    def __init__(self):
        self._lock = threading.RLock()
        self._config_path = Path(p) if (p := os.environ.get("NEARLOOP_PHONE_CONFIG")) else None
        self._status_path = Path(p) if (p := os.environ.get("NEARLOOP_PHONE_STATUS")) else None
        self._stamp = None
        self._saved = dict(DEFAULTS)
        self._config_error = None
        self._runtime = {
            "state": "idle", "detail": "Waiting for a long prompt",
            "completed": 0, "fallbacks": 0, "skipped": 0, "tokens": 0,
            "active": None, "last_run": None, "last_skip": None, "last_fallback": None,
            "runs": [],
        }
        self._published = 0.0

    def config(self) -> dict:
        with self._lock:
            path = self._config_path
            if path is None:
                return dict(self._saved)
            try:
                stat = path.stat()
                stamp = (stat.st_mtime_ns, stat.st_size)
            except OSError:
                stamp = None
            if stamp != self._stamp:
                self._stamp = stamp
                try:
                    self._saved = validate(json.loads(path.read_text())) if stamp else dict(DEFAULTS)
                    self._config_error = None
                except (OSError, ValueError, TypeError) as exc:
                    self._config_error = f"Cannot load phone settings: {exc}"
                    self._saved = dict(DEFAULTS)
                    logger.warning(self._config_error)
                self._publish(force=True)
            return dict(self._saved)

    def note(self, state: str, detail: str = "", **values) -> None:
        with self._lock:
            changed = self._runtime.get("state") != state
            self._runtime.update(state=state, detail=detail, updated_at=time.time(), **values)
            # Progress notes arrive once per chunk; the app polls about once a second, so only a
            # change of state is written at once.
            self._publish(force=changed or state != "running")

    def skip(self, reason: str) -> None:
        with self._lock:
            self._runtime["skipped"] += 1
            self._runtime["last_skip"] = {"reason": reason, "at": time.time()}
            self._publish(force=True)

    def fallback(self, reason: str) -> None:
        with self._lock:
            self._runtime["fallbacks"] += 1
            self._runtime["last_fallback"] = {"reason": reason, "at": time.time()}
            self.note("unavailable", reason, active=None)

    def complete(self, run: dict) -> None:
        with self._lock:
            self._runtime["completed"] += 1
            self._runtime["tokens"] += run["tokens"]
            self._runtime["runs"] = (self._runtime["runs"] + [run])[-20:]
            self.note("ready", "Ready for the next long prompt", active=None, last_run=run)

    def snapshot(self) -> dict:
        with self._lock:
            config = dict(self._saved)
            runtime = copy.deepcopy(self._runtime)
            if not config["enabled"] and runtime["active"] is None:
                runtime.update(state="disabled", detail="iPhone assistance is off")
            return {"config": config, "config_error": self._config_error, "pid": os.getpid(), **runtime}

    def _publish(self, force: bool = False) -> None:
        if self._status_path is None:
            return
        now = time.monotonic()
        if not force and now - self._published < 0.5:
            return
        self._published = now
        try:
            _write_atomic(self._status_path, self.snapshot())
        except OSError as exc:
            logger.debug("phone status not written: %s", exc)


control = PhoneControl()
