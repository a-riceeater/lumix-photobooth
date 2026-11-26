"""Physical recovery test: liveview runs for N seconds; unplug and replug the USB
cable (or power-cycle the camera) while it runs. Prints fps each second and every
transport error, then a summary. Usage: python scripts/test_reconnect.py [seconds]
"""
import sys, pathlib, time
root = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "src"))
from lumix_usb.transport.wpd import WPDTransport
from lumix_usb.recovery import ResilientCamera

SECONDS = float(sys.argv[1]) if len(sys.argv) > 1 else 90
log = root / "captures/direct" / f"test_reconnect_{int(time.time())}.jsonl"

def opener():
    t = WPDTransport.open_first()
    t.set_jsonl_log(str(log))
    return t

events = []
rc = ResilientCamera(opener, log=lambda m: (events.append((time.time(), m)), print(time.strftime("%H:%M:%S"), m)))
rc.want_liveview = True
end = time.monotonic() + SECONDS
frames, last = 0, time.monotonic()
outage_start, outages = None, []
print(f"running {SECONDS:.0f}s — unplug/replug the camera USB cable now")
try:
    while time.monotonic() < end:
        try:
            f = rc.call(lambda c: c.liveview_frame(retries=1), retries=1)
            if f:
                frames += 1
                if outage_start:
                    outages.append(time.monotonic() - outage_start); outage_start = None
        except Exception as e:
            outage_start = outage_start or time.monotonic()
            print(time.strftime("%H:%M:%S"), "unrecovered:", repr(e)); rc.drop(); time.sleep(1)
        if time.monotonic() - last >= 1:
            print(f"{time.strftime('%H:%M:%S')} {frames} fps  reconnects={rc.reconnects}")
            frames, last = 0, time.monotonic()
finally:
    rc.close()
print("reconnects:", rc.reconnects, "outages (s):", [round(o, 1) for o in outages])
print("log:", log)
