# SPDX-License-Identifier: Apache-2.0
"""Model and phone helper for Nearloop's iPhone offload (Experimental).

Every command prints one JSON object on its last line of stdout.

    tool.py inspect --model DIR
        Whether the Tail Worker can run this model's layers, and the facts the
        phone checks at the handshake. Weights stay on disk (lazy load).
    tool.py export --model DIR --tail-layers N --out FILE
        Write the last N decoder layers as a Tail Worker shard (getFaster format).
    tool.py hello --info JSON [--address auto] [--wait 60]
        Handshake with the Tail Worker the way the server will. Prints its
        `ready` reply (layers it holds, memory, device) or its refusal.
    tool.py link [--address auto] [--mb 32] [--rounds 3]
        Measure the Mac <-> iPhone link with echo round trips.

`hello` and `link` don't import MLX, so they start instantly.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import struct
import subprocess
import sys
import time

PROTOCOL_VERSION = 3
DEFAULT_PORT = 9100
_PREFIX = struct.Struct("<IQ")


def emit(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


# ---------------------------------------------------------------------------
# The phone link (no MLX).
# ---------------------------------------------------------------------------


def usb_address() -> str | None:
    """An iPhone on this Mac's USB network link (anri* interfaces), as [addr%if]:port."""
    try:
        out = subprocess.run(["ndp", "-an"], capture_output=True, text=True, timeout=3).stdout
    except (OSError, subprocess.SubprocessError):
        out = ""
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 3 and "%anri" in parts[0] and parts[1] != "(incomplete)" and "permanent" not in line:
            return f"[{parts[0]}]:{DEFAULT_PORT}"
    # The neighbour cache forgets an idle phone: ask the link who is there.
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


def resolve(address: str) -> str | None:
    return usb_address() if address == "auto" else address


class Link:
    def __init__(self, address: str, timeout: float = 5.0):
        host, _, port = address.rpartition(":")
        host = host.strip("[]")
        # Link-local IPv6 needs its scope (the interface) resolved by getaddrinfo.
        info = socket.getaddrinfo(host, int(port), type=socket.SOCK_STREAM)[0]
        self.sock = socket.socket(info[0], info[1], info[2])
        self.sock.settimeout(timeout)
        self.sock.connect(info[4])
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    def send(self, header: dict, payload: bytes = b"") -> None:
        h = json.dumps(header).encode()
        self.sock.sendall(_PREFIX.pack(len(h), len(payload)) + h + payload)

    def _read(self, n: int) -> bytes:
        buf = bytearray(n)
        view, got = memoryview(buf), 0
        while got < n:
            k = self.sock.recv_into(view[got:])
            if k == 0:
                raise ConnectionError("the phone closed the connection")
            got += k
        return bytes(buf)

    def recv(self):
        header_len, payload_len = _PREFIX.unpack(self._read(_PREFIX.size))
        if not 0 < header_len <= 1_048_576 or payload_len > 2_147_483_648:
            raise ConnectionError("invalid frame from the phone")
        header = json.loads(self._read(header_len))
        return header, self._read(payload_len)

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass


def connect(address: str, wait: float) -> tuple[Link, str]:
    """Connect, retrying until `wait` seconds pass (the worker may still be loading)."""
    deadline = time.monotonic() + wait
    last = "no iPhone on the USB network link"
    while True:
        resolved = resolve(address)
        if resolved:
            try:
                return Link(resolved), resolved
            except OSError as exc:
                last = f"{resolved}: {exc.strerror or exc}"
        if time.monotonic() >= deadline:
            raise ConnectionError(last)
        time.sleep(1)


def cmd_hello(args) -> None:
    info = json.loads(args.info)
    try:
        link, resolved = connect(args.address, args.wait)
    except ConnectionError as exc:
        emit({"ok": False, "reachable": False, "error": str(exc)})
        return
    try:
        link.sock.settimeout(max(10.0, args.wait))
        link.send({"type": "hello", "version": PROTOCOL_VERSION, **info})
        header, _ = link.recv()
    except (OSError, ValueError, ConnectionError) as exc:
        emit({"ok": False, "reachable": True, "address": resolved, "error": str(exc)})
        return
    finally:
        link.close()
    if header.get("type") == "ready":
        emit({"ok": True, "reachable": True, "address": resolved, "ready": header})
    else:
        emit({"ok": False, "reachable": True, "address": resolved,
              "error": header.get("message", json.dumps(header))})


def cmd_link(args) -> None:
    try:
        link, resolved = connect(args.address, args.wait)
    except ConnectionError as exc:
        emit({"ok": False, "error": str(exc)})
        return
    try:
        link.sock.settimeout(30)
        start = time.perf_counter()
        link.send({"type": "echo"})
        link.recv()
        rtt = time.perf_counter() - start
        payload = os.urandom(args.mb * 1_000_000)
        best = None
        for _ in range(args.rounds):
            start = time.perf_counter()
            link.send({"type": "echo"}, payload)
            _, back = link.recv()
            elapsed = time.perf_counter() - start
            if back != payload:
                raise ConnectionError("the echo came back corrupted")
            best = elapsed if best is None else min(best, elapsed)
        emit({"ok": True, "address": resolved, "round_trip_ms": rtt * 1e3,
              "mb_per_second": 2 * args.mb / best})
    except (OSError, ValueError, ConnectionError) as exc:
        emit({"ok": False, "address": resolved, "error": str(exc)})
    finally:
        link.close()


# ---------------------------------------------------------------------------
# The model (MLX).
# ---------------------------------------------------------------------------


def _load(path: str):
    from mlx_lm import load

    model, _ = load(path, lazy=True)
    return model


def problems(model) -> list[str]:
    """Why the Tail Worker can't run this model's layers (empty when it can)."""
    import export_tail
    import splitmodel
    from mlx.utils import tree_flatten

    try:
        splitmodel.check_supported(model)
    except SystemExit as exc:
        return [str(exc)]
    found = []
    layers = model.layers
    for i in range(1, len(layers)):
        kind = export_tail.layer_kind(layers[i])
        allowed = export_tail._ALLOWED["attention" if kind["mixer"] != "linear" else "linear"] \
            | export_tail._ALLOWED[kind["mlp"]] | export_tail._ALLOWED["norms"]
        unknown = set(dict(tree_flatten(layers[i].parameters()))) - allowed
        if unknown:
            found.append(f"layer {i} has parameters the iPhone worker can't run: {', '.join(sorted(unknown)[:4])}")
            break
    attention = next((l.self_attn for l in layers if not splitmodel.is_linear(l)), None)
    if attention is not None:
        try:
            export_tail.rope_spec(attention.rope)
        except SystemExit as exc:
            found.append(str(exc))
    return found


def cmd_inspect(args) -> None:
    import splitmodel
    from mlx.utils import tree_flatten

    try:
        model = _load(args.model)
    except Exception as exc:  # noqa: BLE001 - any loader failure means "can't use"
        emit({"ok": False, "supported": False, "reasons": [f"mlx-lm can't load this model: {exc}"]})
        return
    reasons = problems(model)
    layers = model.layers
    layer_bytes = [sum(a.nbytes for _, a in tree_flatten(l.parameters())) for l in layers]
    out = {
        "ok": True,
        "supported": not reasons,
        "reasons": reasons,
        "num_layers": len(layers),
        "layer_bytes": layer_bytes,
        "linear_layers": [i for i, l in enumerate(layers) if splitmodel.is_linear(l)],
        "supported_types": sorted(splitmodel.SUPPORTED_MODEL_TYPES),
    }
    if not reasons:
        out["info"] = splitmodel.model_info(model)
        out["phone_costs"] = phone_costs(model, layer_bytes)
    emit(out)


# The Tail Worker's own memory rules (getFaster ios/Sources/TailCore: TailModel, TailServer), so the Mac
# can size a shard for any model from the phone's budget alone. A phone reports `shard` + `available`
# bytes; their sum is what it has for weights, one 32K-token prompt in 512-token chunks, and its reserve.
PHONE_TOKENS, PHONE_CHUNK, PHONE_RESERVE = 32768, 512, 600 * 1024 * 1024


def phone_costs(model, layer_bytes: list) -> dict:
    import export_tail

    layers = model.layers
    _, spec = export_tail.export(model, 1)  # lazy: describes layers 1..L-1 without reading weights
    kinds = [export_tail.layer_kind(layers[0])] + spec["layers"]
    hidden = spec["hidden_size"]
    attention, linear, moe = spec.get("attention"), spec.get("linear"), spec.get("moe")
    kv_layer = PHONE_TOKENS * 2 * attention["num_kv_heads"] * attention["head_dim"] * 2 if attention else 0
    conv_dim = state_layer = state_pass = 0
    if linear:
        conv_dim = 2 * linear["num_k_heads"] * linear["head_k_dim"] + linear["num_v_heads"] * linear["head_v_dim"]
        recurrent = linear["num_v_heads"] * linear["head_v_dim"] * linear["head_k_dim"] * 4
        state_layer = recurrent + (linear["conv_kernel"] - 1) * conv_dim * 2
        state_pass = recurrent * 2
    widest = max(hidden * 4, conv_dim)
    routed = (moe["top_k"] if moe else 0) * hidden * 16
    activation = PHONE_CHUNK * ((hidden * 16 + widest * 8) * 2 + routed) + state_pass
    per_layer = [int(b) + (state_layer if kind["mixer"] == "linear" else kv_layer)
                 for b, kind in zip(layer_bytes, kinds)]
    # Activations are counted twice by the phone (once in the prompt, once kept aside), plus its
    # reserve and the brief second copy of one layer's K/V while it grows.
    return {"per_layer": per_layer, "fixed": 2 * activation + PHONE_RESERVE + kv_layer}


def cmd_export(args) -> None:
    import export_tail
    import mlx.core as mx

    model = _load(args.model)
    reasons = problems(model)
    if reasons:
        emit({"ok": False, "error": "; ".join(reasons)})
        return
    tail_start = len(model.layers) - args.tail_layers
    if not 0 < tail_start < len(model.layers):
        emit({"ok": False, "error": f"layers on the iPhone must be between 1 and {len(model.layers) - 1}"})
        return
    try:
        arrays, spec = export_tail.export(model, tail_start)
    except SystemExit as exc:
        emit({"ok": False, "error": str(exc)})
        return
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    # MLX adds ".safetensors" to a name that lacks it, so the temporary name keeps that ending.
    stem = args.out[: -len(".safetensors")] if args.out.endswith(".safetensors") else args.out
    partial = stem + ".partial.safetensors"
    mx.save_safetensors(partial, arrays, metadata={"getfaster": json.dumps(spec)})
    os.replace(partial, args.out)
    emit({"ok": True, "path": args.out, "tail_start": tail_start, "num_layers": len(model.layers),
          "bytes": os.path.getsize(args.out), "fingerprint": spec["fingerprint"]})


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("inspect")
    p.add_argument("--model", required=True)
    p = sub.add_parser("export")
    p.add_argument("--model", required=True)
    p.add_argument("--tail-layers", type=int, required=True)
    p.add_argument("--out", required=True)
    p = sub.add_parser("hello")
    p.add_argument("--info", required=True)
    p.add_argument("--address", default="auto")
    p.add_argument("--wait", type=float, default=30)
    p = sub.add_parser("link")
    p.add_argument("--address", default="auto")
    p.add_argument("--wait", type=float, default=5)
    p.add_argument("--mb", type=int, default=32)
    p.add_argument("--rounds", type=int, default=3)
    args = parser.parse_args()
    {"inspect": cmd_inspect, "export": cmd_export, "hello": cmd_hello, "link": cmd_link}[args.command](args)


if __name__ == "__main__":
    main()
