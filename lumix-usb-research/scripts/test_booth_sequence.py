"""Booth sequence: continuous liveview thread + capture to PC (JPEG only) + download.

Measures liveview frame gaps around each capture and whether liveview survives
capture without restart. Temporarily sets quality FINE and target PC; both are
restored at the end.
"""
import sys, pathlib, time, threading, struct
root = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "src"))
from lumix_usb.transport.wpd import WPDTransport
from lumix_usb.panasonic import Camera, Target, PROPS, tlv_value
from lumix_usb.ptp import rc_name

SHOTS = int(sys.argv[1]) if len(sys.argv) > 1 else 2
t = WPDTransport.open_first()
t.set_jsonl_log(str(root / "captures/direct" / f"test_booth_sequence_{int(time.time())}.jsonl"))
cam = Camera(t)
cam.connect()
out = root / "samples/photos"; out.mkdir(parents=True, exist_ok=True)
orig_q = cam.get_value(PROPS["image_quality"])
frames, busy, stop = [], [0], threading.Event()

def lv_loop():
    while not stop.is_set():
        f = cam.liveview_frame(retries=1)
        if f: frames.append((time.perf_counter(), len(f.jpeg)))
        else: busy[0] += 1; time.sleep(0.01)

try:
    print("orig quality", orig_q, "->", rc_name(cam.set_property(PROPS["image_quality"], 0, 2).code))
    cam.set_capture_target(Target.PC)
    cam.liveview_start(); time.sleep(0.3)
    th = threading.Thread(target=lv_loop, daemon=True); th.start()
    time.sleep(2)
    marks = []
    for i in range(SHOTS):
        t_rel = time.perf_counter()
        res = cam.capture(timeout=15)
        objs = res["objects"]
        line = f"shot {i}: release {rc_name(res['release_rc'])} object after {res.get('t_object', -1):.2f}s"
        for h, info in objs:
            t0 = time.perf_counter(); d = cam.download(h); dl = time.perf_counter() - t0
            (out / f"booth_{i}_{info.filename}").write_bytes(d)
            line += f"; {info.filename} {len(d)/1e6:.1f} MB in {dl:.2f}s"
        marks.append((t_rel, time.perf_counter()))
        print(line)
        time.sleep(1.5)
    stop.set(); th.join(2)
    ts = [f[0] for f in frames]
    print(f"liveview: {len(ts)} frames, busy {busy[0]}, overall {len(ts)/(ts[-1]-ts[0]):.1f} fps")
    for i, (a, b) in enumerate(marks):
        win = [x for x in ts if a - 0.5 <= x <= b + 1.5]
        gaps = [y - x for x, y in zip(win, win[1:])]
        print(f"  shot {i}: max frame gap {max(gaps)*1000:.0f} ms, frames during capture+download"
              f" {len([x for x in ts if a <= x <= b])} over {b-a:.2f}s")
    after = [x for x in ts if x > marks[-1][1]]
    print("  frames after last shot:", len(after))
finally:
    stop.set()
    cam.liveview_stop()
    cam.set_capture_target(Target.SD)
    print("restore quality ->", rc_name(cam.set_property(PROPS["image_quality"], orig_q, 2).code),
          "now", cam.get_value(PROPS["image_quality"]))
    cam.disconnect()
