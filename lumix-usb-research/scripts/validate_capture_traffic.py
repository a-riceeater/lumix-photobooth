"""Known traffic for validating the USBPcap pipeline: waits for the pcap file to
appear (capture started elevated), then runs a short fixed sequence."""
import sys, pathlib, time
root = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "src"))
pcap = root / "captures/tether" / sys.argv[1]
for _ in range(180):
    if pcap.exists():
        break
    time.sleep(0.5)
else:
    sys.exit("pcap never appeared (UAC not approved?)")
time.sleep(2)
from lumix_usb.transport.wpd import WPDTransport
from lumix_usb.panasonic import Camera, Target, PROPS, AF
from lumix_usb.ptp import rc_name
t = WPDTransport.open_first()
t.set_jsonl_log(str(root / "captures/direct" / f"validate_{pcap.stem}_{int(time.time())}.jsonl"))
cam = Camera(t); cam.connect()
q = cam.get_value(PROPS["image_quality"])
try:
    print("battery", cam.battery_percent(), "target", cam.get_capture_target())
    cam.liveview_start(); time.sleep(0.3)
    n = sum(1 for _ in range(30) if cam.liveview_frame(retries=1))
    print("frames", n)
    r, st, dt = cam.autofocus_wait(4); print("AF", AF.NAMES.get(st, st), f"{dt:.2f}s")
    cam.set_property(PROPS["image_quality"], 0, 2); cam.set_capture_target(Target.PC)
    res = cam.capture(timeout=10)
    if res["objects"]:
        d = cam.download(res["objects"][-1][0]); print("jpeg", len(d))
finally:
    cam.liveview_stop(); cam.set_capture_target(Target.SD)
    cam.set_property(PROPS["image_quality"], q, 2)
    cam.disconnect()
print("traffic done")
