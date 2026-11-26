"""AF-S: autofocus_wait() then capture to PC (JPEG FINE) with liveview on.
Measures AF time and AF->JPEG time. Restores quality and capture target.
Usage: python scripts/test_af_capture.py [shots]"""
import sys, pathlib, time
root = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "src"))
from lumix_usb.transport.wpd import WPDTransport
from lumix_usb.panasonic import Camera, Target, PROPS, AF_LOCK_CLEAR
from lumix_usb.ptp import rc_name

N = int(sys.argv[1]) if len(sys.argv) > 1 else 3
t = WPDTransport.open_first()
t.set_jsonl_log(str(root / "captures/direct" / f"test_af_capture_{int(time.time())}.jsonl"))
cam = Camera(t); cam.connect()
orig_q = cam.get_value(PROPS["image_quality"])
try:
    print("af_mode", cam.get_value(PROPS["af_mode"]), "drive", cam.get_value(PROPS["drive_mode"]))
    cam.set_property(PROPS["image_quality"], 0, 2)
    cam.set_capture_target(Target.PC)
    cam.liveview_start(); time.sleep(0.5)
    for i in range(N):
        r, st, dt = cam.autofocus_wait(timeout=6)
        state = {0xFFFF: "finished", 0x0000: "focusing", 0xFFFE: "idle"}.get(st, st)
        print(f"shot {i}: AF {rc_name(r.code)} -> {state} after {dt:.2f}s")
        res = cam.capture(timeout=15)
        h_info = res["objects"][-1] if res["objects"] else None
        if h_info:
            t0 = time.perf_counter(); d = cam.download(h_info[0]); dl = time.perf_counter() - t0
            print(f"   release {rc_name(res['release_rc'])}, JPEG event after {res['t_object']:.2f}s,"
                  f" {len(d)/1e6:.1f} MB in {dl:.2f}s; total AF+shot+download {dt + res['t_object'] + dl:.2f}s")
        else:
            print(f"   release {rc_name(res['release_rc'])}, NO object")
        cam.af_control(AF_LOCK_CLEAR)
        time.sleep(1)
finally:
    cam.liveview_stop()
    cam.set_capture_target(Target.SD)
    cam.set_property(PROPS["image_quality"], orig_q, 2)
    print("restored: target", cam.get_capture_target(), "quality", cam.get_value(PROPS["image_quality"]))
    cam.disconnect()
