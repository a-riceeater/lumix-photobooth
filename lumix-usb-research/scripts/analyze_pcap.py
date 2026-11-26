"""Decode PTP transactions from a USBPcap capture (pcap/pcapng).

    python scripts/analyze_pcap.py captures/tether/03_liveview.pcapng [--device N] [--jsonl out.jsonl]

Uses tshark (Wireshark 4.x) with the usb-ptp dissector disabled to get raw
bulk/interrupt payloads, reassembles PTP containers per endpoint, and prints one
line per transaction (command -> data -> response) plus events. Device address
is auto-detected from the first bulk container with type 1 (command) if omitted.
"""
from __future__ import annotations

import argparse
import json
import struct
import subprocess
import sys
from collections import defaultdict

TSHARK = r"C:\Program Files\Wireshark\tshark.exe"
TYPES = {1: "CMD", 2: "DATA", 3: "RESP", 4: "EVENT"}
TRUNCATED = [0]   # bytes missing from the capture because of snaplen (zero-padded)


def packets(path: str):
    cmd = [TSHARK, "-r", path, "--disable-protocol", "usb-ptp", "-T", "fields",
           "-E", "separator=\t", "-e", "frame.number", "-e", "frame.time_relative",
           "-e", "usb.device_address", "-e", "usb.endpoint_address", "-e", "usb.capdata",
           "-e", "frame.len", "-e", "frame.cap_len", "usb.capdata"]
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        f = line.split("\t")
        if len(f) < 5 or not f[4]:
            continue
        ep = int(f[3], 0) if f[3].startswith("0x") else int(f[3])
        data = bytes.fromhex(f[4].replace(":", ""))
        missing = int(f[5]) - int(f[6]) if len(f) >= 7 and f[5] and f[6] else 0
        if missing > 0:   # truncated URB: pad so container framing stays in sync
            TRUNCATED[0] += missing
            data += bytes(missing)
        yield int(f[0]), float(f[1]), int(f[2]), ep, data


def containers(stream):
    """stream: iterable of (frame, t, bytes) for one endpoint -> PTP containers."""
    buf, start = b"", None
    for frame, t, data in stream:
        if not buf:
            start = (frame, t)
        buf += data
        while len(buf) >= 12:
            length, ctype, code, tid = struct.unpack_from("<IHHI", buf)
            if length < 12 or ctype not in TYPES:
                buf = b""          # lost sync; drop
                break
            if len(buf) < length:
                break
            body = buf[12:length]
            yield {"frame": start[0], "t": start[1], "type": TYPES[ctype], "code": code,
                   "tid": tid, "body": body}
            buf = buf[length:]
            start = (frame, t)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pcap")
    ap.add_argument("--device", type=int)
    ap.add_argument("--jsonl")
    ap.add_argument("--hexlen", type=int, default=32)
    a = ap.parse_args()

    per_ep = defaultdict(list)
    for frame, t, dev, ep, data in packets(a.pcap):
        per_ep[(dev, ep)].append((frame, t, data))
    if a.device is None:
        cands = [d for (d, ep), s in per_ep.items() if ep == 0x01 and s and len(s[0][2]) >= 12
                 and struct.unpack_from("<H", s[0][2], 4)[0] == 1]
        if not cands:
            sys.exit("no PTP command stream found; pass --device")
        a.device = cands[0]
    dev = a.device

    items = []
    for ep in (0x01, 0x81, 0x82):
        for c in containers(per_ep.get((dev, ep), [])):
            c["ep"] = ep
            items.append(c)
    items.sort(key=lambda c: (c["frame"], c["ep"]))

    txs, events = {}, []
    for c in items:
        if c["type"] == "EVENT":
            events.append(c)
            continue
        tx = txs.setdefault(c["tid"], {"tid": c["tid"]})
        if c["type"] == "CMD":
            tx.update(t=c["t"], op=c["code"], params=list(struct.unpack(f"<{len(c['body']) // 4}I", c["body"])))
        elif c["type"] == "DATA":
            tx["dir"] = "out" if c["ep"] == 0x01 else "in"
            tx["data"] = c["body"]
        elif c["type"] == "RESP":
            tx.update(t_end=c["t"], rc=c["code"],
                      rparams=list(struct.unpack(f"<{len(c['body']) // 4}I", c["body"])))

    out = open(a.jsonl, "w") if a.jsonl else None
    merged = sorted([("tx", tx.get("t", 0), tx) for tx in txs.values()] +
                    [("ev", e["t"], e) for e in events], key=lambda x: x[1])
    for kind, t, x in merged:
        if kind == "ev":
            ps = list(struct.unpack(f"<{len(x['body']) // 4}I", x["body"]))
            line = f"{t:9.4f}  EVENT 0x{x['code']:04X} " + " ".join(f"0x{p:08X}" for p in ps)
            rec = {"t": t, "event": f"0x{x['code']:04X}", "params": [f"0x{p:08X}" for p in ps]}
        else:
            d = x.get("data", b"")
            line = (f"{t:9.4f}  tid {x['tid']:>5} op 0x{x.get('op', 0):04X} "
                    f"[{' '.join(f'0x{p:08X}' for p in x.get('params', []))}]"
                    f" {x.get('dir', '-'):>3} {len(d):>8}B {d[:a.hexlen].hex()}"
                    f" -> 0x{x.get('rc', 0):04X} {' '.join(f'0x{p:08X}' for p in x.get('rparams', []))}"
                    f" ({(x.get('t_end', t) - t) * 1000:.1f} ms)")
            rec = {"t": t, "tid": x["tid"], "op": f"0x{x.get('op', 0):04X}",
                   "params": [f"0x{p:08X}" for p in x.get("params", [])], "dir": x.get("dir"),
                   "len": len(d), "data_head": d[:256].hex(), "rc": f"0x{x.get('rc', 0):04X}",
                   "rparams": [f"0x{p:08X}" for p in x.get("rparams", [])]}
        print(line)
        if out:
            out.write(json.dumps(rec) + "\n")

    ops = defaultdict(int)
    for tx in txs.values():
        ops[(tx.get("op", 0), tuple(tx.get("params", [])[:1]))] += 1
    print(f"\n# device {dev}: {len(txs)} transactions, {len(events)} events"
          + (f"; WARNING {TRUNCATED[0]} bytes truncated by snaplen (zero-padded)" if TRUNCATED[0] else ""))
    for (op, p1), n in sorted(ops.items()):
        print(f"#   0x{op:04X} {('0x%08X' % p1[0]) if p1 else '':<10} x{n}")


if __name__ == "__main__":
    main()
