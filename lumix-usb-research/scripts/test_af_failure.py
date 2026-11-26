"""AF failure probe (lens covered / no contrast). Traces raw 0x01000011 and every
changed field of the C101 status dump during AF, then tests whether the shutter
fires after a failed AF and with release only. PC target, JPEG FINE, restored after."""
import sys, pathlib, time
root = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "src"))
from lumix_usb.transport.wpd import WPDTransport
from lumix_usb.panasonic import Camera, Target, PROPS, AF_LOCK_CLEAR
from lumix_usb.ptp import rc_name

t = WPDTransport.open_first()
t.set_jsonl_log(str(root / "captures/direct" / f"test_af_failure_{int(time.time())}.jsonl"))
cam = Camera(t); cam.connect()
orig_q = cam.get_value(PROPS["image_quality"])
out = root / "samples/photos"; out.mkdir(parents=True, exist_ok=True)

def trace(seconds, t0, prev):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        cam.liveview_frame(retries=1)
        cur = dict(cam.status)
        if cur and cur != prev:
            diffs = []
            for k in sorted(cur):
                if prev.get(k) != cur[k]:
                    a, b = prev.get(k, b""), cur[k]
                    idx = [i for i in range(min(len(a), len(b))) if a[i] != b[i]] or [0]
                    j = idx[0]
                    diffs.append(f"{k:08X}@{j}:{a[j:j+4].hex()}->{b[j:j+4].hex()}" if a else f"{k:08X}={b[:8].hex()}")
            print(f"   +{time.perf_counter()-t0:5.2f}s " + ("; ".join(diffs) if prev else f"first 01000011={cur.get(0x01000011, b'').hex()}"))
            prev = cur
    return prev

try:
    print("af_mode", cam.get_value(PROPS["af_mode"]), "drive", cam.get_value(PROPS["drive_mode"]))
    cam.set_property(PROPS["image_quality"], 0, 2)
    cam.set_capture_target(Target.PC)
    cam.liveview_start(); time.sleep(0.5)
    prev = {}
    for i in range(2):
        t0 = time.perf_counter()
        print(f"AF #{i}: {rc_name(cam.autofocus().code)}")
        prev = trace(4, t0, prev)
        print(f"   lock clear: {rc_name(cam.af_control(AF_LOCK_CLEAR).code)}")
        prev = trace(1, t0, prev)
    for label, use_af in (("AF (fails) + release", True), ("release only", False)):
        print(f"--- {label}")
        for i in range(2):
            if use_af:
                r, st, dt = cam.autofocus_wait(timeout=4)
                print(f"   AF {rc_name(r.code)} -> state {st if st is None else hex(st)} after {dt:.2f}s")
            res = cam.capture(timeout=10)
            evs = [str(e) for e in res["events"]]
            if res["objects"]:
                h, info = res["objects"][-1]
                d = cam.download(h)
                name = f"afc_covered_{'af' if use_af else 'rel'}_{i}.jpg"
                (out / name).write_bytes(d)
                print(f"   release {rc_name(res['release_rc'])}: JPEG after {res['t_object']:.2f}s -> {name}")
            else:
                print(f"   release {rc_name(res['release_rc'])}: NO object within 10 s; events {evs}")
            cam.af_control(AF_LOCK_CLEAR); time.sleep(1)
            for e in cam.drain_events():
                print("     late", e)
finally:
    cam.liveview_stop()
    cam.set_capture_target(Target.SD)
    cam.set_property(PROPS["image_quality"], orig_q, 2)
    print("restored: target", cam.get_capture_target(), "quality", cam.get_value(PROPS["image_quality"]))
    cam.disconnect()
