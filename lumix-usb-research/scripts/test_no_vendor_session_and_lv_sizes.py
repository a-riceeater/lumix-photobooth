"""(1) Liveview without Panasonic 0x9102. (2) fps/frame size for each liveview setting (restored after)."""
import sys, pathlib, time, io
root = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "src"))
from PIL import Image
from lumix_usb.transport.wpd import WPDTransport
from lumix_usb.panasonic import Camera
from lumix_usb.ptp import rc_name

t = WPDTransport.open_first()
t.set_jsonl_log(str(root / "captures/direct" / f"test_lv_sizes_{int(time.time())}.jsonl"))
cam = Camera(t)
try:
    r = t.command(0x9412, 0x0D000010); print("9412 start WITHOUT 9102:", rc_name(r.code))
    time.sleep(0.2)
    r = t.read(0x9706); print("9706 WITHOUT 9102:", rc_name(r.code), len(r.data))
    t.command(0x9412, 0x0D000011)
    cam.connect()
    cur, opts = cam.liveview_settings()
    cur = opts[0]  # previous probe left 1280x960 set; restore to the 640x480 default
    print("current", cur)
    for s in opts:
        print("set", s, "->", rc_name(cam.set_liveview_setting(s).code))
        cam.liveview_start(); time.sleep(0.3)
        n, sz, t0 = 0, 0, time.perf_counter()
        while time.perf_counter() - t0 < 3:
            f = cam.liveview_frame(retries=1)
            if f: n += 1; sz += len(f.jpeg); last = f
        dt = time.perf_counter() - t0
        im = Image.open(io.BytesIO(last.jpeg))
        (root / f"samples/liveview_{im.size[0]}x{im.size[1]}.jpg").write_bytes(last.jpeg)
        print(f"   {n/dt:.1f} fps, avg jpeg {sz/n/1024:.0f} KiB, decoded {im.size}, {sz/dt/1e6:.1f} MB/s")
        cam.liveview_stop(); time.sleep(0.3)
    print("restore", cur, "->", rc_name(cam.set_liveview_setting(cur).code))
finally:
    cam.disconnect()
