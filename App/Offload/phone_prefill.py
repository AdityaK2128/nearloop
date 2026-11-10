# SPDX-License-Identifier: Apache-2.0
"""Split prefill with an iPhone: the phone runs the model's last decoder layers.

From the getFaster project, adapted for Nearloop: it is loaded into an installed
oMLX by Nearloop's launcher (serve.py), which calls `run_from_locals` from the
start of oMLX's prefill loop, and it honours every snapshot stop oMLX plans.

For a long, cold prompt the Mac runs layers [0, S) chunk by chunk and streams
each chunk's hidden states to a Tail Worker app on an iPhone (see the getFaster
project), which runs layers [S, L) and streams back their KV. The two overlap:
the Mac computes chunk i+1 while the phone works on chunk i. Linear-attention
(Gated DeltaNet) state comes back when a chunk ends on a cache-block boundary,
so boundary snapshots for the paged SSD cache keep working, and once more at
the end. With an MTP head the phone also returns its final hidden states, which
are folded into the head exactly as the inner-model capture wrap does. After
prefill the Mac holds the complete cache; decode never touches the phone.

Anything unusual falls back to the ordinary path with the caches rolled back:
no phone, a refusal, a timeout, media prompts, a DFlash drafter, TurboQuant KV.

Configuration (environment):
    OMLX_PHONE_WORKER       host:port, [fe80::…%anri0]:9100, or "auto" to use an
                            iPhone on this Mac's USB network link. Unset: off.
    OMLX_PHONE_MIN_TOKENS   shortest uncached prompt worth splitting (2048)
    OMLX_PHONE_CHUNK        tokens per pipelined chunk (default: oMLX's prefill
                            step size, so the Mac keeps its large-chunk kernels;
                            the last stretch drops to 512 to shorten the drain)
    OMLX_PHONE_MAX_SEED_MB  largest cached prefix to hand the phone (2000)
"""

from __future__ import annotations

import copy
import hashlib
import importlib
import json
import logging
import math
import queue
import re
import socket
import struct
import subprocess
import threading
import time
import uuid
from types import SimpleNamespace
from typing import Any, Optional

import mlx.core as mx
import numpy as np
from mlx.utils import tree_flatten

from .phone_control import control

logger = logging.getLogger(__name__)

PROTOCOL_VERSION = 3
DEFAULT_PORT = 9100
SUPPORTED_MODEL_TYPES = {"qwen3", "qwen2", "llama", "mistral", "qwen3_5", "qwen3_5_moe"}

# ---------------------------------------------------------------------------
# Wire format: u32 header_len | u64 payload_len | JSON header | raw payload.
# ---------------------------------------------------------------------------

_PREFIX = struct.Struct("<IQ")
# numpy has no bfloat16, so bfloat16 crosses the numpy boundary as uint16 bits.
_CARRIERS = {
    "bfloat16": (mx.bfloat16, mx.uint16, np.uint16),
    "float16": (mx.float16, mx.float16, np.float16),
    "float32": (mx.float32, mx.float32, np.float32),
}


def _dtype_name(dtype) -> str:
    for name, (mx_dtype, _, _) in _CARRIERS.items():
        if dtype == mx_dtype:
            return name
    raise ValueError(f"unsupported wire dtype {dtype}")


def _tensor_bytes(a: mx.array) -> bytes:
    _, carrier, _ = _CARRIERS[_dtype_name(a.dtype)]
    a = mx.contiguous(a)
    if carrier != a.dtype:
        a = a.view(carrier)
    return np.asarray(a).tobytes()


def _tensor_from(buf, dtype: str, shape) -> mx.array:
    mx_dtype, carrier, np_dtype = _CARRIERS[dtype]
    a = mx.array(np.frombuffer(buf, dtype=np_dtype).reshape(shape))
    return a.view(mx_dtype) if carrier != mx_dtype else a


def _entry(a: mx.array) -> dict:
    return {"shape": list(a.shape), "dtype": _dtype_name(a.dtype)}


def _unpack(entries, payload, start=0):
    arrays, offset = [], start
    for entry in entries:
        try:
            shape, dtype = entry["shape"], entry["dtype"]
            if not isinstance(shape, list) or any(type(d) is not int or d < 0 for d in shape):
                raise ValueError("invalid tensor shape")
            size = math.prod(shape) * np.dtype(_CARRIERS[dtype][2]).itemsize
            if offset + size > len(payload):
                raise ValueError("truncated tensor payload")
            arrays.append(_tensor_from(payload[offset : offset + size], dtype, shape))
        except (KeyError, TypeError, ValueError, OverflowError) as exc:
            raise _PhoneError(f"invalid phone tensor: {exc}") from exc
        offset += size
    return arrays, offset


class _Link:
    """A framed TCP connection with a sender and a receiver thread.

    Only bytes cross threads; every MLX op stays on the scheduler thread.
    """

    def __init__(self, address: str, timeout: float = 5.0):
        host, _, port = address.rpartition(":")
        sock = socket.create_connection((host.strip("[]") or "127.0.0.1", int(port)), timeout=timeout)
        sock.settimeout(None)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.sock = sock
        self._outbox: queue.Queue = queue.Queue()
        self._inbox: queue.Queue = queue.Queue()
        self.error: Optional[BaseException] = None
        self._closed = threading.Event()
        self._sender = threading.Thread(target=self._send_loop, daemon=True, name="phone-send")
        self._receiver = threading.Thread(target=self._recv_loop, daemon=True, name="phone-recv")
        self._sender.start()
        self._receiver.start()

    def send(self, header: dict, payload: bytes = b"") -> None:
        if self.error is not None:
            raise _PhoneError(f"link failed: {self.error}")
        self._outbox.put((header, payload))

    def recv(self, timeout: Optional[float]):
        try:
            item = self._inbox.get(timeout=timeout)
        except queue.Empty:
            return None
        if item is None:
            raise _PhoneError(f"link failed: {self.error}")
        return item

    def close(self) -> None:
        if self._closed.is_set():
            return
        self._closed.set()
        # close() alone needn't wake a recv blocked on another thread.
        self._outbox.put(None)
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass
        self._inbox.put(None)

    def _read(self, n: int) -> bytearray:
        buf = bytearray(n)
        view, got = memoryview(buf), 0
        while got < n:
            k = self.sock.recv_into(view[got:])
            if k == 0:
                raise ConnectionError("phone closed the connection")
            got += k
        return buf

    def _send_loop(self) -> None:
        try:
            while True:
                item = self._outbox.get()
                if item is None or self._closed.is_set():
                    return
                header, payload = item
                h = json.dumps(header).encode()
                self.sock.sendall(_PREFIX.pack(len(h), len(payload)) + h)
                if payload:
                    self.sock.sendall(payload)
        except Exception as e:  # surfaced on the next send/recv
            self._fail(e)

    def _recv_loop(self) -> None:
        try:
            while True:
                header_len, payload_len = _PREFIX.unpack(self._read(_PREFIX.size))
                if not 0 < header_len <= 1_048_576 or payload_len > 2_147_483_648:
                    raise _PhoneError("invalid or oversized phone frame")
                header = json.loads(self._read(header_len))
                if not isinstance(header, dict):
                    raise _PhoneError("phone header must be an object")
                self._inbox.put((header, self._read(payload_len)))
        except Exception as e:
            self._fail(e)

    def _fail(self, e: BaseException) -> None:
        if self.error is None:
            self.error = e
        self.close()


class _PhoneError(Exception):
    """The phone can't take (or finish) this prompt; the Mac prefills it."""


# ---------------------------------------------------------------------------
# The model as seen from here: which layers, how to run the head.
# ---------------------------------------------------------------------------


def _is_linear(layer) -> bool:
    return bool(getattr(layer, "is_linear", False))


class _ModelView:
    """Wraps the scheduler's model: an mlx-vlm VLMModelAdapter or an mlx-lm model."""

    def __init__(self, model: Any):
        language_model = getattr(model, "_language_model", None)
        if language_model is not None:
            self.inner = language_model.model
            args = language_model.args
            module = importlib.import_module(type(self.inner).__module__)
            if not hasattr(module, "_create_qwen3_5_attention_mask"):
                module = importlib.import_module("mlx_vlm.models.qwen3_5.language")
            self._attention_mask = module._create_qwen3_5_attention_mask
            self._linear_mask = module._create_qwen3_5_ssm_mask
            self._vlm = True
            vlm = getattr(model, "_vlm_model", None)
            model_type = getattr(getattr(vlm, "config", None), "model_type", None) or args.model_type
        else:
            from mlx_lm.models.base import create_attention_mask, create_ssm_mask

            self.inner = model.model
            args = getattr(model, "language_model", model).args
            self._attention_mask = create_attention_mask
            self._linear_mask = create_ssm_mask
            self._vlm = False
            model_type = model.args.model_type
        self.model_type = re.sub(r"_text$", "", str(model_type))
        self.layers = self.inner.layers
        self.args = args
        host_ref = getattr(self.inner, "_omlx_mtp_prime_host", None)
        self.mtp_host = host_ref() if callable(host_ref) else None
        self._info: Optional[dict] = None

    def info(self) -> dict:
        """The facts the phone checks at the handshake (same as getFaster's splitmodel)."""
        if self._info is None:
            digest = hashlib.sha256()
            for _, w in sorted(tree_flatten(self.layers[-1].parameters()))[:4]:
                if w.dtype == mx.bfloat16:
                    w = w.view(mx.uint16)
                digest.update(np.asarray(w).tobytes())
            args = self.args
            self._info = {
                "model_type": self.model_type,
                "num_layers": len(self.layers),
                "hidden_size": args.hidden_size,
                "num_kv_heads": args.num_key_value_heads,
                "head_dim": getattr(args, "head_dim", None) or args.hidden_size // args.num_attention_heads,
                "fingerprint": digest.hexdigest()[:16],
            }
        return self._info

    def run_head(self, ids: mx.array, caches: list, end: int) -> mx.array:
        """Hidden states after layers [0, end), filling those layers' caches."""
        h = self.inner.embed_tokens(ids)
        layers = self.layers[:end]
        attention = next((c for l, c in zip(layers, caches) if not _is_linear(l)), None)
        linear = next((c for l, c in zip(layers, caches) if _is_linear(l)), None)
        attention_mask = self._attention_mask(h, attention)
        linear_mask = self._linear_mask(h, linear) if linear is not None else None
        for layer, cache in zip(layers, caches):
            mask = linear_mask if _is_linear(layer) else attention_mask
            h = layer(h, mask=mask, cache=cache) if self._vlm else layer(h, mask, cache)
        return h


# ---------------------------------------------------------------------------
# The phone: connection, handshake, health.
# ---------------------------------------------------------------------------


def _discover_usb_address() -> Optional[str]:
    """An iPhone on this Mac's USB network link (Apple's anri interfaces).

    The neighbour cache forgets the phone when the link is idle, so when it
    has no entry the all-nodes address is pinged and the phone's reply used.
    """
    try:
        out = subprocess.run(["ndp", "-an"], capture_output=True, text=True, timeout=3).stdout
    except (OSError, subprocess.SubprocessError):
        out = ""
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 3 and "%anri" in parts[0] and parts[1] != "(incomplete)" and "permanent" not in line:
            return f"[{parts[0]}]:{DEFAULT_PORT}"
    for interface in _anri_interfaces():
        for address in _ping_neighbours(interface):
            return f"[{address}]:{DEFAULT_PORT}"
    return None


def _anri_interfaces() -> list:
    try:
        out = subprocess.run(["ifconfig", "-l"], capture_output=True, text=True, timeout=3).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    return [name for name in out.split() if name.startswith("anri")]


def _ping_neighbours(interface: str) -> list:
    """Addresses that answer the all-nodes ping on `interface`, ours excluded."""
    try:
        out = subprocess.run(["ping6", "-c", "2", "-i", "0.2", f"ff02::1%{interface}"],
                             capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    source = re.search(r"\) (\S+) -->", out)
    own = source.group(1) if source else None
    found = []
    for match in re.finditer(r"bytes from (\S+?),", out):
        address = match.group(1)
        if address != own and address not in found:
            found.append(address)
    return found


class _Phone:
    """One shared connection to the Tail Worker, reconnected after failures."""

    RETRY_AFTER = 15.0

    def __init__(self):
        self.lock = threading.Lock()
        self.link: Optional[_Link] = None
        self.ready: Optional[dict] = None
        self.fingerprint: Optional[str] = None
        self.retry_at = 0.0
        self.last_state = None
        self.address = None

    def _note(self, state: str, detail: str = "") -> None:
        control.note(state, detail)
        if state != self.last_state:
            (logger.info if state == "ready" else logger.warning)("phone prefill: %s %s", state, detail)
            self.last_state = state

    def session(self, view: _ModelView, address: str) -> Optional[tuple[_Link, dict]]:
        """A link to a phone that holds the tail of this model, or None."""
        info = view.info()
        with self.lock:
            if (self.link is not None and self.link.error is None
                    and self.fingerprint == info["fingerprint"] and self.address == address):
                return self.link, self.ready
            if self.address == address and time.monotonic() < self.retry_at:
                return None
            self.close()
            self.address = address
            resolved = _discover_usb_address() if address == "auto" else address
            if resolved is None:
                self.retry_at = time.monotonic() + self.RETRY_AFTER
                self._note("unavailable", "(no iPhone on the USB network link)")
                return None
            link = None
            try:
                link = _Link(resolved)
                link.send({"type": "hello", "version": PROTOCOL_VERSION, **info})
                reply = link.recv(timeout=10)
                if reply is None:
                    raise _PhoneError("no reply to hello")
                header, _ = reply
                if header.get("type") != "ready":
                    raise _PhoneError(header.get("message", str(header)))
                if header["tail_end"] != info["num_layers"] or not 0 < header["tail_start"] < info["num_layers"]:
                    raise _PhoneError(f"phone holds layers {header['tail_start']}..{header['tail_end'] - 1}")
            except (OSError, _PhoneError, ValueError, KeyError, TypeError) as e:
                if link is not None:
                    link.close()
                self.retry_at = time.monotonic() + self.RETRY_AFTER
                self._note("unavailable", f"({resolved}: {e})")
                return None
            self.link, self.ready, self.fingerprint = link, header, info["fingerprint"]
            control.note("ready", device=header.get("device"), address=resolved,
                         tail_start=header["tail_start"], tail_end=header["tail_end"],
                         memory=header.get("memory"))
            memory = header.get("memory") or {}
            self._note(
                "ready",
                f"({header.get('device', 'iPhone')} at {resolved}, layers {header['tail_start']}..{header['tail_end'] - 1}"
                + (f", {memory['available'] / 1e9:.1f} GB free" if memory else "") + ")",
            )
            return link, header

    def reset(self) -> None:
        """Drop the connection without backing off (the next prompt reconnects)."""
        with self.lock:
            self.close()

    def failed(self, reason: str) -> None:
        with self.lock:
            self.close()
            self.retry_at = time.monotonic() + self.RETRY_AFTER
            self._note("unavailable", f"({reason})")

    def close(self) -> None:
        if self.link is not None:
            self.link.close()
        self.link, self.ready, self.fingerprint = None, None, None


_phone = _Phone()
# The worker is batch-1 even when several model schedulers are running.
_request_lock = threading.Lock()

# Chunk size for the last stretch of a prompt (see _split).
_DRAIN_CHUNK = 512

# ---------------------------------------------------------------------------
# The split.
# ---------------------------------------------------------------------------


def _config() -> Optional[dict]:
    config = control.config()
    if not config["enabled"]:
        return None
    return {**config, "max_seed": config["max_seed_mb"] * 1_000_000}


def _kv_parts(cache, upto: int):
    return cache.keys[0, :, :upto, :], cache.values[0, :, :upto, :]


def _checkpoint(caches: list) -> list:
    """Enough to put every cache back exactly as it was."""
    saved = []
    for c in caches:
        if hasattr(c, "keys"):
            saved.append(("kv", c.keys, c.values, c.offset))
        else:
            saved.append(("arrays", list(c.cache)))
    return saved


def _restore(caches: list, saved: list) -> None:
    for c, s in zip(caches, saved):
        if s[0] == "kv":
            c.keys, c.values, c.offset = s[1], s[2], s[3]
        else:
            c.cache = list(s[1])


def _frozen_arrays(cache, state=None):
    """A copy of an ArraysCache holding `state` (or its current state) for a snapshot."""
    snapshot = copy.copy(cache)
    snapshot.cache = list(state if state is not None else cache.cache)
    return snapshot


def run_from_locals(sched: Any, scope: dict) -> int:
    """Called from inside Scheduler._do_external_prefill with its local variables.

    Reading them by name keeps one hook working across oMLX versions: a stop
    an older version doesn't plan is simply absent.
    """
    try:
        request = scope["request"]
        prefill_tokens = scope["prefill_tokens"]
        prompt_cache = scope["prompt_cache"]
    except KeyError as exc:
        control.skip(f"This oMLX version's prefill is missing {exc}")
        return 0
    stops = sorted({s for s in (scope.get("system_at"), scope.get("tail_at")) if isinstance(s, int)})
    return run(
        sched, request, prefill_tokens, prompt_cache,
        base_size=int(scope.get("base_size") or 0),
        boundary_enabled=bool(scope.get("boundary_enabled")),
        block_size=int(scope.get("block_size") or 0),
        stops=stops,
        uid=scope.get("uid"),
        total_length=int(scope.get("total_length") or len(prefill_tokens) + 1),
        emitted_boundaries=scope.get("emitted_boundaries", {}),
        eligible=scope.get("embeds_array") is None and scope.get("vlm_embeds") is None
        and not scope.get("minimum_prefix"),
    )


def run(*args, **kwargs) -> int:
    """Never interleave two schedulers' prompts on the batch-1 worker."""
    if not _request_lock.acquire(blocking=False):
        control.skip("Phone is serving another request")
        return 0
    try:
        return _run(*args, **kwargs)
    finally:
        _request_lock.release()


def _run(
    sched: Any,
    request: Any,
    prefill_tokens: list,
    prompt_cache: list,
    *,
    base_size: int,
    boundary_enabled: bool,
    block_size: int,
    stops: list,
    uid: Optional[int],
    total_length: int,
    emitted_boundaries: dict,
    eligible: bool,
) -> int:
    """Prefill `prefill_tokens` with the phone's help. Returns how many tokens
    it prefilled; 0 means it wasn't used (or fell back with caches rolled back).
    """
    config = _config()
    if config is None:
        return 0
    if len(prefill_tokens) < config["min_tokens"]:
        return 0  # the usual case for chat turns; not worth reporting
    if not eligible:
        control.skip("The prompt has images or needs a fixed prefix")
        return 0
    reason = _ineligible(sched, request, prompt_cache)
    if reason:
        control.skip(reason)
        logger.info("phone prefill skipped for %s: %s", request.request_id, reason)
        return 0
    view = getattr(sched, "_phone_view", None)
    if view is None or view.inner is not getattr(getattr(sched.model, "_language_model", sched.model), "model", None):
        view = sched._phone_view = _ModelView(sched.model)
    if view.model_type not in SUPPORTED_MODEL_TYPES:
        control.skip(f"Unsupported model type: {view.model_type}")
        return 0
    session = _phone.session(view, config["address"])
    if session is None:
        return 0
    link, ready = session

    tail_start = ready["tail_start"]
    tail_layers = view.layers[tail_start:]
    tail_kv = [c for l, c in zip(tail_layers, prompt_cache[tail_start:]) if not _is_linear(l)]
    if base_size:
        seed_bytes = sum(base_size * c.keys.shape[1] * c.keys.shape[3] * c.keys.itemsize
                         + base_size * c.values.shape[1] * c.values.shape[3] * c.values.itemsize
                         for c in tail_kv)
        seed_bytes += sum(a.nbytes for l, c in zip(tail_layers, prompt_cache[tail_start:])
                          if _is_linear(l) for a in (c[0], c[1]) if a is not None)
        if seed_bytes > config["max_seed"]:
            control.skip("Cached prefix exceeds the transfer limit")
            logger.info("phone prefill skipped: cached prefix of %d tokens is too big to hand over", base_size)
            return 0

    saved = _checkpoint(prompt_cache)
    previous_boundary = emitted_boundaries.get(request.request_id)
    try:
        return _split(sched, request, prefill_tokens, prompt_cache, view, link, ready, config,
                      base_size=base_size, boundary_enabled=boundary_enabled, block_size=block_size,
                      stops=stops, uid=uid, total_length=total_length,
                      emitted_boundaries=emitted_boundaries)
    except _PhoneError as e:
        _restore(prompt_cache, saved)
        if previous_boundary is None:
            emitted_boundaries.pop(request.request_id, None)
        else:
            emitted_boundaries[request.request_id] = previous_boundary
        control.fallback(str(e))
        _phone.failed(str(e))
        logger.warning("phone prefill fell back to the Mac for %s: %s", request.request_id, e)
        return 0
    except BaseException:
        # Aborts and memory errors keep their usual handling; the phone state is
        # unknown afterwards, so start the next prompt on a fresh connection.
        _phone.reset()
        control.note("idle", "Request stopped; reconnecting on the next prompt", active=None)
        raise


def _ineligible(sched: Any, request: Any, prompt_cache: list) -> Optional[str]:
    if getattr(sched, "_turboquant_kv_bits", None) is not None:
        return "TurboQuant KV"
    if getattr(request, "vlm_extra_keys_for_cache", None):
        return "media in the conversation"
    if float(getattr(request, "rope_deltas", 0.0) or 0.0) != 0.0:
        return "shifted mRoPE positions"
    try:
        from .patches.mlx_lm_mtp.batch_generator import _drafter_for

        if _drafter_for(sched.model) is not None:
            return "a block drafter is attached"
    except ImportError:
        pass
    for c in prompt_cache:
        name = type(c).__name__
        if name not in ("KVCache", "ArraysCache"):
            return f"cache type {name}"
        if not isinstance(getattr(c, "offset", 0), int):
            return "batched cache"
    return None


def _guarded_size(sched, request, size: int, *, kv_len: int) -> int:
    from .scheduler import Scheduler

    sizing = getattr(Scheduler, "_adaptive_chunk_size", None)
    if sizing is None:
        return size
    # probe=True prices and shrinks the chunk without oMLX's pause-to-evict signal, which only its
    # own loop can act on. A chunk that still doesn't fit is caught by the memory check after it.
    try:
        allowed = sizing(sched, size, request_id=request.request_id, loop_label="external",
                         kv_len=kv_len, probe=True)
    except TypeError:
        try:
            allowed = sizing(sched, size, request_id=request.request_id, loop_label="external", kv_len=kv_len)
        except TypeError:
            return size  # a version with another signature: keep the requested size
        except Exception as exc:
            raise _PhoneError(f"oMLX's memory guard stopped the split: {type(exc).__name__}") from exc
    except Exception as exc:
        raise _PhoneError(f"oMLX's memory guard stopped the split: {type(exc).__name__}") from exc
    return max(1, min(size, int(allowed)))


def _split(
    sched, request, tokens, prompt_cache, view: _ModelView, link: _Link, ready: dict, config: dict,
    *, base_size, boundary_enabled, block_size, stops, uid, total_length, emitted_boundaries,
) -> int:
    from .prefill_boundaries import clamp_prefill_chunk_to_boundary, should_emit_prefill_boundary
    from .scheduler import Scheduler, _PrefillAbortedError

    started = time.perf_counter()
    S = ready["tail_start"]
    layers = view.layers
    head_caches, tail_caches = prompt_cache[:S], prompt_cache[S:]
    tail_kv = [c for l, c in zip(layers[S:], tail_caches) if not _is_linear(l)]
    tail_linear = [(i, c) for i, (l, c) in enumerate(zip(layers[S:], tail_caches), S) if _is_linear(l)]
    head_linear = [(i, c) for i, (l, c) in enumerate(zip(layers[:S], head_caches)) if _is_linear(l)]
    want_hidden = view.mtp_host is not None
    req = uuid.uuid4().hex[:12]
    n = len(tokens)
    control.note("running", "Prefilling with the iPhone", active={"tokens": n, "processed": 0})
    stats = {"head_s": 0.0, "phone_ms": 0.0, "out": 0, "back": 0}

    chunk_hint = config["chunk"] or int(getattr(sched.config, "prefill_step_size", 0) or 2048)
    link.send({"type": "begin", "req": req, "total_tokens": n, "prefix_tokens": base_size,
               "chunk": chunk_hint})
    if base_size:
        # The prompt's start was restored from cache: give the phone its tail part.
        if any(c.offset != base_size for c in tail_kv):
            raise _PhoneError("restored cache offsets don't match the cached prefix")
        with mx.stream(sched._stream):
            parts = []
            kv = None
            if tail_kv:
                kv = mx.stack([mx.stack(_kv_parts(c, base_size)) for c in tail_kv])
                parts.append(kv)
            state = [a for _, c in tail_linear for a in (c[0], c[1])]
            mx.eval(parts, state)
        header = {"type": "seed", "req": req, "offset": base_size,
                  "state": [_entry(a) for a in state]}
        if kv is not None:
            header["kv"] = _entry(kv)
        payload = b"".join(_tensor_bytes(a) for a in parts + state)
        link.send(header, payload)
        stats["out"] += len(payload)

    # Wait for the phone to accept before computing anything: a refusal (not
    # enough memory, too hot, app in the background) then costs one round trip.
    deadline = time.monotonic() + 10
    while True:
        if time.monotonic() >= deadline:
            raise _PhoneError("the phone didn't accept the prompt within 10 s")
        item = link.recv(max(0.01, deadline - time.monotonic()))
        if item is None:
            raise _PhoneError("the phone didn't accept the prompt within 10 s")
        header, _ = item
        if header.get("type") == "error":
            raise _PhoneError(header.get("message", "phone error"))
        if header.get("type") == "begun" and header.get("req") == req:
            break

    pending: list[dict] = []
    absorbed = 0

    def absorb(timeout: Optional[float], *, final: bool = False) -> bool:
        nonlocal absorbed
        deadline = time.monotonic() + timeout if timeout else None
        while True:
            if deadline is not None and time.monotonic() >= deadline:
                raise _PhoneError(f"no current reply from the phone for {timeout:.0f} s")
            item = link.recv(max(0.001, deadline - time.monotonic()) if deadline else timeout)
            if item is None:
                if timeout:
                    raise _PhoneError(f"no reply from the phone for {timeout:.0f} s")
                return False
            header, payload = item
            if header.get("type") == "error":
                raise _PhoneError(header.get("message", "phone error"))
            if header.get("req") != req:
                continue  # left over from an earlier, abandoned prompt
            if header.get("type") == "state":
                if not final:
                    raise _PhoneError("phone ended the prompt before all chunks completed")
                pending.append({"state_reply": (header, payload)})
                return True
            break
        if final:
            raise _PhoneError("phone did not return the final state")
        chunk = pending[absorbed]
        if header.get("type") != "kv" or header.get("idx") != chunk["idx"]:
            raise _PhoneError(f"reply for chunk {header.get('idx')} arrived out of order")
        shape = header.get("shape")
        if (not isinstance(shape, list) or len(shape) != 5 or shape[0] != len(tail_kv)
                or shape[1] != 2 or shape[3] != chunk["size"] or "dtype" not in header):
            raise _PhoneError("phone sent an unexpected KV layout")
        with mx.stream(sched._stream):
            kv, used = _unpack([{"shape": header["shape"], "dtype": header["dtype"]}], payload)
            state, used = _unpack(header.get("state_tensors", []), payload, used)
            hidden, used = _unpack([header["hidden"]] if "hidden" in header else [], payload, used)
            if used != len(payload) or len(state) != (2 * len(tail_linear) if chunk["snapshot"] else 0):
                raise _PhoneError("phone sent an unexpected tensor payload")
            if bool(hidden) != want_hidden:
                raise _PhoneError("phone did not return the requested hidden states")
            for cache, layer_kv in zip(tail_kv, kv[0]):
                cache.update_and_fetch(layer_kv[0][None], layer_kv[1][None])
            mx.eval([c.keys for c in tail_kv], [c.values for c in tail_kv])
            if hidden and view.mtp_host is not None:
                from .patches.mlx_lm_mtp import prompt_priming

                normed = view.inner.norm(hidden[0][None])
                prompt_priming.maybe_capture(
                    view.mtp_host, chunk["ids"], normed, [SimpleNamespace(offset=chunk["end"])])
        if chunk["snapshot"]:
            # Deferred boundary snapshot: the Mac's layers as they were at this
            # boundary, the phone's linear-attention state from its reply.
            snapshot = [None] * len(prompt_cache)
            for i, frozen in chunk["head_state"]:
                snapshot[i] = frozen
            for k, (i, c) in enumerate(tail_linear):
                snapshot[i] = _frozen_arrays(c, state[2 * k : 2 * k + 2])
            total = chunk["end"]
            if chunk["snapshot"] == "boundary":
                sched._emit_prefill_boundary_snapshot(request, snapshot, total)
                emitted_boundaries[request.request_id] = total
            else:
                sched._emit_prefill_tail_snapshot(request, snapshot, total)
        stats["phone_ms"] += header.get("compute_ms", 0.0)
        stats["back"] += len(payload)
        absorbed += 1
        chunk["ids"] = None
        chunk["head_state"] = []  # Release snapshots as soon as they are emitted.
        control.note("running", "Prefilling with the iPhone",
                     active={"tokens": n, "processed": chunk["end"] - base_size})
        if uid is not None:
            sched._on_prompt_progress([(uid, chunk["end"] - base_size, total_length)])
        return True

    Scheduler._clear_cache(sched)
    reserve_tokens = base_size + n + 1
    # Large chunks keep oMLX's fast prefill kernels engaged on the Mac (some
    # only engage at 2048+ tokens). Once a single chunk is left, smaller ones
    # let the phone finish soon after the Mac rather than a whole chunk later.
    chunk = config["chunk"] or int(getattr(sched.config, "prefill_step_size", 0) or 2048)
    position = 0
    while position < n:
        # Bound hidden tensors and frozen state when the phone/link is slower.
        # Two in flight preserves compute overlap without an unbounded backlog.
        while len(pending) - absorbed >= config["max_inflight"]:
            absorb(timeout=60)
        remaining = n - position
        size = chunk if remaining > chunk else min(_DRAIN_CHUNK, remaining)
        # oMLX's memory guard sizes every chunk from measured use; the split obeys it too, so a chunk
        # never pushes the Mac past the ceiling the normal path keeps.
        size = _guarded_size(sched, request, size, kv_len=base_size + position)
        if boundary_enabled and block_size > 0:
            size = clamp_prefill_chunk_to_boundary(size, cache_tokens=base_size + position, block_size=block_size)
        # Stop once more at each planned snapshot (shared system prompt, tail).
        for stop_at in stops:
            if base_size + position < stop_at:
                size = min(size, stop_at - base_size - position)
        end = base_size + position + size
        snapshot = None
        if boundary_enabled:
            if should_emit_prefill_boundary(
                total_tokens=end, block_size=block_size,
                last_emitted_tokens=emitted_boundaries.get(request.request_id, -1),
            ):
                snapshot = "boundary"
            elif end in stops:
                snapshot = "tail"

        Scheduler._reserve_prefill_capacity(sched, prompt_cache, reserve_tokens, request.request_id)
        t = time.perf_counter()
        with Scheduler._chunk_backpressure(sched), mx.stream(sched._stream):
            ids = mx.array(tokens[position : position + size])[None]
            h = view.run_head(ids, head_caches, S)
            mx.eval(h, [c.state for c in head_caches])
            payload = _tensor_bytes(h[0])
        stats["head_s"] += time.perf_counter() - t
        pending.append({
            "idx": len(pending), "end": end, "size": size, "snapshot": snapshot,
            "ids": ids if want_hidden else None,
            "head_state": [(i, _frozen_arrays(c)) for i, c in head_linear] if snapshot else [],
        })
        link.send({"type": "chunk", "req": req, "idx": len(pending) - 1, "offset": base_size + position,
                   "shape": [size, h.shape[-1]], "dtype": _dtype_name(h.dtype),
                   "want_state": snapshot is not None, "want_hidden": want_hidden}, payload)
        stats["out"] += len(payload)
        position += size

        while absorbed < len(pending) and absorb(timeout=0):
            pass
        Scheduler._check_post_prefill_memory(
            sched, request_id=request.request_id, chunk_tokens=size,
            processed_tokens=position, total_tokens=total_length, loop_label="external",
        )
        abort_uids = sched._check_pending_aborts_for_uids([uid] if uid is not None else [])
        if abort_uids:
            Scheduler._clear_cache(sched)
            raise _PrefillAbortedError(abort_uids, position)
        if sched._consume_pressure_clear():
            Scheduler._clear_cache(sched)

    while absorbed < len(pending):
        absorb(timeout=60)
    link.send({"type": "end", "req": req})
    absorb(timeout=60, final=True)
    header, payload = pending.pop()["state_reply"]
    with mx.stream(sched._stream):
        state, used = _unpack(header.get("tensors", []), payload)
        if used != len(payload) or len(state) != 2 * len(tail_linear):
            raise _PhoneError(f"phone sent {len(state)} state tensors for {len(tail_linear)} linear layers")
        for k, (_, cache) in enumerate(tail_linear):
            cache[0], cache[1] = state[2 * k], state[2 * k + 1]
        mx.eval(state)
    stats["back"] += len(payload)
    Scheduler._clear_cache(sched)

    elapsed = time.perf_counter() - started
    device = header.get("device") or {}
    control.complete({
        "tokens": n, "seconds": elapsed, "tokens_per_second": n / elapsed,
        "tail_start": S, "num_layers": len(layers),
        "mac_seconds": stats["head_s"], "phone_seconds": stats["phone_ms"] / 1e3,
        "sent_bytes": stats["out"], "received_bytes": stats["back"],
        "device": device, "finished_at": time.time(),
    })
    logger.info(
        "phone prefill: %d tokens in %.2f s (%.0f tok/s), layers %d..%d on the phone; "
        "Mac %.2f s, phone %.2f s compute; %.0f MB out, %.0f MB back%s",
        n, elapsed, n / elapsed, S, len(layers) - 1, stats["head_s"], stats["phone_ms"] / 1e3,
        stats["out"] / 1e6, stats["back"] / 1e6,
        f"; phone {device.get('thermal')}, {device.get('available', 0) / 1e9:.1f} GB free" if device else "",
    )
    return n
