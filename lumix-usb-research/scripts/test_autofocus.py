"""AF test (lever on AFS): AF one-shot with liveview, event timeline, then AF + capture."""
import sys, pathlib, time
root = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "src"))
from lumix_usb.transport.wpd import WPDTransport
from lumix_usb.panasonic import Camera, PROPS, AF_LOCK_CLEAR
from lumix_usb.ptp import rc_name

t = WPDTransport.open_first()
t.set_jsonl_log(str(root / "captures/direct" / f"test_autofocus_{int(time.time())}.jsonl"))
cam = Camera(t)
cam.connect()
try:
    print("af_mode", cam.get_value(PROPS["af_mode"]), "af_area", cam.get_property(PROPS["af_area"]).keys())
    cam.liveview_start(); time.sleep(0.5); cam.drain_events()
    for i in range(3):
        t0 = time.perf_counter()
        r = cam.autofocus()
        print(f"AF #{i}: {rc_name(r.code)} in {(time.perf_counter()-t0)*1000:.0f} ms")
        end = time.monotonic() + 2.5
        while time.monotonic() < end:
            cam.liveview_frame(retries=1)   # keep liveview flowing like a booth would
            for ev in cam.drain_events():
                print(f"   +{time.perf_counter()-t0:.3f}s {ev}")
        r = cam.af_control(AF_LOCK_CLEAR); print("   lock clear:", rc_name(r.code))
        time.sleep(0.5)
        for ev in cam.drain_events(): print("   after clear", ev)
    print("--- AF then capture (SD target, unchanged)")
    cam.drain_events()
    t0 = time.perf_counter(); r = cam.autofocus(); print("AF", rc_name(r.code))
    time.sleep(1.0)
    res = cam.capture(timeout=15)
    print(f"release {rc_name(res['release_rc'])} after AF; objects "
          f"{[(i.filename, i.format_name) for h, i in res['objects']]} first at {res.get('t_object')}")
    print("--- capture without explicit AF (camera AFS half-press via release)")
    res = cam.capture(timeout=15)
    print(f"release {rc_name(res['release_rc'])}; objects {[(i.filename) for h, i in res['objects']]} at {res.get('t_object')}")
    time.sleep(1)
    for ev in cam.drain_events(): print("  late", ev)
finally:
    cam.disconnect()
