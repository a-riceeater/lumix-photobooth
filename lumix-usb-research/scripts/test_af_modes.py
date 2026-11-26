"""AF behaviour for the current focus-lever position (AFS/AFC/MF).

1. Logs every change of the C101 status-dump AF field (0x01000011) for 3 AF
   commands (+ lock clear), with liveview running.
2. Captures to PC (JPEG FINE): N shots after autofocus_wait, N shots release-only.
Restores quality and capture target. Usage: python scripts/test_af_modes.py [N]
"""
import sys, pathlib, time
root = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "src"))
from lumix_usb.transport.wpd import WPDTransport
from lumix_usb.panasonic import Camera, Target, PROPS, AF_LOCK_CLEAR
from lumix_usb.ptp import rc_name

N = int(sys.argv[1]) if len(sys.argv) > 1 else 3
AFMODE = {3: "MF", 4: "AFS", 5: "AFC", 6: "AFF"}
STATE = {0xFFFF: "finished", 0x0000: "focusing", 0xFFFE: "idle", None: "?"}
t = WPDTransport.open_first()
t.set_jsonl_log(str(root / "captures/direct" / f"test_af_modes_{int(time.time())}.jsonl"))
cam = Camera(t); cam.connect()
orig_q = cam.get_value(PROPS["image_quality"])

def watch(seconds, t0):
    last = object()
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        cam.liveview_frame(retries=1)
        st = cam.af_state()
        if st != last:
            b4 = cam.status.get(0x01000012, b"\0" * 5)[4:5].hex()
            print(f"   +{time.perf_counter() - t0:5.2f}s af_state={STATE.get(st, hex(st or 0))} (01000012[4]={b4})")
            last = st

try:
    mode = cam.get_value(PROPS["af_mode"])
    print("af_mode", mode, AFMODE.get(mode), "drive", cam.get_value(PROPS["drive_mode"]))
    cam.liveview_start(); time.sleep(0.5)
    print("idle 2 s (no AF command):"); watch(2, time.perf_counter())
    for i in range(3):
        t0 = time.perf_counter()
        print(f"AF #{i}: {rc_name(cam.autofocus().code)}"); watch(3, t0)
        print(f"   lock clear: {rc_name(cam.af_control(AF_LOCK_CLEAR).code)}"); watch(1, t0)
    cam.set_property(PROPS["image_quality"], 0, 2)
    cam.set_capture_target(Target.PC)
    for label, use_af in (("autofocus_wait + release", True), ("release only", False)):
        print(f"--- {label}")
        for i in range(N):
            af_dt = 0.0
            if use_af:
                r, st, af_dt = cam.autofocus_wait(timeout=4)
                print(f"   AF {rc_name(r.code)} -> {STATE.get(st, st)} in {af_dt:.2f}s")
            res = cam.capture(timeout=15)
            if res["objects"]:
                h, info = res["objects"][-1]
                t1 = time.perf_counter(); d = cam.download(h); dl = time.perf_counter() - t1
                print(f"   shot {i}: release {rc_name(res['release_rc'])}, JPEG after {res['t_object']:.2f}s,"
                      f" dl {dl:.2f}s, total {af_dt + res['t_object'] + dl:.2f}s")
            else:
                print(f"   shot {i}: release {rc_name(res['release_rc'])}, NO object")
            cam.af_control(AF_LOCK_CLEAR)
            time.sleep(1)
finally:
    cam.liveview_stop()
    cam.set_capture_target(Target.SD)
    cam.set_property(PROPS["image_quality"], orig_q, 2)
    print("restored: target", cam.get_capture_target(), "quality", cam.get_value(PROPS["image_quality"]))
    cam.disconnect()
