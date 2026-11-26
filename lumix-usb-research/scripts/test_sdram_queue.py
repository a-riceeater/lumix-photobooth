"""SDRAM (capture target PC) behaviour: fixed handle, RAW+JPEG queueing, back-to-back shots.

Shot A downloads only the JPEG and leaves the RAW pending; shot B fires right
after. Then the queue is drained (downloading whatever 0x12345678 now holds).
Capture target is restored to SD at the end.
"""
import sys, pathlib, time
root = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "src"))
from lumix_usb.transport.wpd import WPDTransport
from lumix_usb.panasonic import Camera, Target, PEC
from lumix_usb.ptp import rc_name

t = WPDTransport.open_first()
t.set_jsonl_log(str(root / "captures/direct" / f"test_sdram_queue_{int(time.time())}.jsonl"))
cam = Camera(t)
cam.connect()
out = root / "samples/photos"; out.mkdir(parents=True, exist_ok=True)
try:
    cam.set_capture_target(Target.PC)
    for shot in "AB":
        res = cam.capture(timeout=20)
        print(f"shot {shot}: release {rc_name(res['release_rc'])}, events {[str(e) for e in res['events']]}")
        for h, info in res["objects"]:
            print(f"   {info.filename} fmt 0x{info.format:04X} {info.compressed_size} B after {res.get('t_object', 0):.2f}s")
            t0 = time.perf_counter(); d = cam.download(h)
            print(f"   downloaded {len(d)} B in {time.perf_counter()-t0:.2f}s")
            (out / f"sdram_{shot}_{info.filename}").write_bytes(d)
    print("draining: what does 0x12345678 hold now?")
    for i in range(4):
        try:
            info = cam.object_info(0x12345678)
        except Exception as e:
            print("  ObjectInfo:", e); break
        print(f"  {info.filename} fmt 0x{info.format:04X} {info.compressed_size} B")
        t0 = time.perf_counter(); d = cam.download(0x12345678)
        print(f"  downloaded {len(d)} B in {time.perf_counter()-t0:.2f}s = {len(d)/1e6/(time.perf_counter()-t0):.1f} MB/s")
        (out / f"sdram_drain{i}_{info.filename}").write_bytes(d)
        time.sleep(0.5)
    time.sleep(1)
    for ev in cam.drain_events(): print("  late", ev)
finally:
    cam.set_capture_target(Target.SD)
    cam.disconnect()
