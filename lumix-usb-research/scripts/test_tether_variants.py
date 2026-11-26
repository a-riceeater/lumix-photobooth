"""Re-test Tether-observed variants with our implementation:
AF via 0x9404(0x03000018), 0x9110 object info, parameterless 0x9103.
Also restores the capture target to SD (Tether leaves it at 2 = both)."""
import sys, pathlib, time, struct
root = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "src"))
from lumix_usb.transport.wpd import WPDTransport
from lumix_usb.panasonic import Camera, Target, PROPS, AF, AF_LOCK_CLEAR
from lumix_usb.ptp import rc_name, ObjectInfo

t = WPDTransport.open_first()
t.set_jsonl_log(str(root / "captures/direct" / f"test_tether_variants_{int(time.time())}.jsonl"))
cam = Camera(t); cam.connect()
q = cam.get_value(PROPS["image_quality"])
try:
    print("capture target found:", cam.get_capture_target(), "af_mode", cam.get_value(PROPS["af_mode"]))
    cam.liveview_start(); time.sleep(0.5)
    for i in range(2):
        with cam.status_cond:
            seq0 = cam.status_seq
        t0 = time.monotonic()
        r = t.command(0x9404, 0x03000018)
        st = None
        with cam.status_cond:
            while time.monotonic() - t0 < 4:
                if cam.status_seq > seq0 and cam.af_state() in (AF.IN_FOCUS, AF.FAILED):
                    st = cam.af_state(); break
                cam.status_cond.wait(0.2)
        print(f"0x9404(0x03000018) {rc_name(r.code)} -> AF {AF.NAMES.get(st, st)} in {time.monotonic()-t0:.2f}s")
        cam.af_control(AF_LOCK_CLEAR); time.sleep(1.5)
    cam.set_property(PROPS["image_quality"], 0, 2)
    cam.set_capture_target(Target.PC)
    res = cam.capture(timeout=10)
    if res["objects"]:
        h = res["objects"][-1][0]
        r10 = t.read(0x9110, h); r08 = t.read(0x1008, h)
        print(f"0x9110 {rc_name(r10.code)} {len(r10.data)}B prefix {r10.data[:4].hex()}; 0x1008 {len(r08.data)}B")
        print("  0x9110[4:] == 0x1008 ?", r10.data[4:] == r08.data,
              "| filename via 9110[4:]:", ObjectInfo.parse(r10.data[4:]).filename)
        cam.download(h)
finally:
    cam.liveview_stop()
    cam.set_capture_target(Target.SD)
    cam.set_property(PROPS["image_quality"], q, 2)
    print("restored target", cam.get_capture_target(), "quality", cam.get_value(PROPS["image_quality"]))
    r = t.command(0x9103)
    print("0x9103 without parameter:", rc_name(r.code))
    cam.vendor_session = False
    cam.disconnect()
