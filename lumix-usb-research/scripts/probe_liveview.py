"""Probe: liveview start (0x9412), frame fetch (0x9706), stop. Saves raw frames to samples/."""
import sys, pathlib, time
root = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "src"))
from lumix_usb.transport.wpd import WPDTransport
from lumix_usb.ptp import rc_name, hexdump

log = root / "captures/direct" / f"probe_liveview_{int(time.time())}.jsonl"
t = WPDTransport.open_first()
t.set_jsonl_log(str(log))
try:
    r = t.read(0x9402, 0x02000020); print("ISO pre-9102:", rc_name(r.code), len(r.data))
    print("9102:", rc_name(t.command(0x9102, 0x00010001).code))
    r = t.read(0x9706); print("9706 before start:", rc_name(r.code), len(r.data))
    print("9412 start:", rc_name(t.command(0x9412, 0x0D000010).code))
    time.sleep(0.2)
    n_ok, n_busy, t0 = 0, 0, time.perf_counter()
    first = None
    while time.perf_counter() - t0 < 5:
        r = t.read(0x9706)
        if r.ok and r.data:
            n_ok += 1
            if n_ok <= 3:
                (root / f"samples/liveview_raw_{n_ok}.bin").write_bytes(r.data)
            first = first or r.data
        else:
            n_busy += 1
    dt = time.perf_counter() - t0
    print(f"frames ok={n_ok} other={n_busy} in {dt:.2f}s -> {n_ok/dt:.1f} fps")
    print(hexdump(first, 256))
    print("SOI at", first.find(b"\xff\xd8\xff"), "len", len(first))
    print("9412 stop:", rc_name(t.command(0x9412, 0x0D000011).code))
    r = t.read(0x9706); print("9706 after stop:", rc_name(r.code), len(r.data))
    time.sleep(0.5)
    for ev in t.drain_events(): print(ev)
finally:
    t.command(0x9103, 0x00010001)
    t.close()
print("log:", log)
