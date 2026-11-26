"""Read-only probe: are unadvertised Panasonic opcodes forwarded by WPD, and is 0x9102 needed?"""
import sys, pathlib, time
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "src"))
from lumix_usb.transport.wpd import WPDTransport
from lumix_usb.ptp import rc_name, hexdump

log = pathlib.Path(__file__).resolve().parents[1] / "captures/direct" / f"probe_vendor_session_{int(time.time())}.jsonl"
t = WPDTransport.open_first()
t.set_jsonl_log(str(log))

def show(label, r):
    print(f"{label}: {rc_name(r.code)} params={[hex(p) for p in r.params]} len={len(r.data)}")
    if r.data:
        print(hexdump(r.data, 96))

try:
    for label, fn in [
        ("9402 battery (pre-session)", lambda: t.read(0x9402, 0x16000010)),
        ("9102 OpenSession", lambda: t.command(0x9102, 0x00010001)),
        ("9402 battery", lambda: t.read(0x9402, 0x16000010)),
        ("9402 ISO", lambda: t.read(0x9402, 0x02000020)),
        ("9414 liveview current", lambda: t.read(0x9414, 0x0D800011)),
        ("9414 liveview options", lambda: t.read(0x9414, 0x0D800012)),
        ("940A capture target", lambda: t.read(0x940A, 0x08000090)),
    ]:
        try:
            show(label, fn())
        except Exception as e:
            print(f"{label}: EXC {e!r}")
            t.log_note(kind="exception", label=label, error=repr(e))
    time.sleep(2)
    for ev in t.drain_events():
        print(ev)
finally:
    t.close()
print("log:", log)
