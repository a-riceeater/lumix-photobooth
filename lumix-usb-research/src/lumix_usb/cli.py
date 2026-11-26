"""CLI test harness: python -m lumix_usb <command> (see --help)."""
from __future__ import annotations

import argparse
import pathlib
import struct
import sys
import time

from .panasonic import PROPS, Camera, Target, parse_tlv, tlv_value
from .ptp import OFC_NAMES, hexdump, rc_name

ROOT = pathlib.Path(__file__).resolve().parents[2]


def open_camera(args, vendor_session: bool = True) -> Camera:
    from .transport.wpd import WPDTransport
    t = WPDTransport.open_first()
    log = ROOT / "captures/direct" / f"{args.cmd}_{int(time.time())}.jsonl"
    log.parent.mkdir(parents=True, exist_ok=True)
    t.set_jsonl_log(str(log))
    print(f"[log] {log.relative_to(ROOT)}", file=sys.stderr)
    cam = Camera(t)
    if vendor_session:
        cam.connect()
    return cam


def cmd_detect(args):
    from .transport.wpd import list_devices
    for d in list_devices():
        mark = "*" if "vid_04da" in d["pnp_id"].lower() else " "
        print(f"{mark} {d['manufacturer']} {d['name']}  {d['pnp_id']}")


def cmd_device_info(args):
    cam = open_camera(args, vendor_session=False)
    try:
        di = cam.device_info()
        print(f"{di.manufacturer} {di.model} fw {di.device_version} sn {di.serial_number}")
        print(f"VendorExtensionID 0x{di.vendor_extension_id:X} v{di.vendor_extension_version}")
        print("ops   ", " ".join(f"{x:04X}" for x in di.operations))
        print("events", " ".join(f"{x:04X}" for x in di.events))
        print("props ", " ".join(f"{x:04X}" for x in di.device_props))
        print("formats", ", ".join(OFC_NAMES.get(x, hex(x)) for x in di.image_formats))
    finally:
        cam.disconnect()


def cmd_connect(args):
    """Open + close a vendor session and print status; proves the handshake."""
    cam = open_camera(args)
    try:
        print("vendor session open (0x9102 OK)")
        print("capture target:", {0: "SD", 1: "PC/SDRAM", 2: "both"}.get(cam.get_capture_target()))
        cur, opts = cam.liveview_settings()
        print("liveview:", cur, "options:", ", ".join(map(str, opts)))
        time.sleep(args.hold)
        for ev in cam.drain_events():
            print(ev)
    finally:
        cam.disconnect()
        print("vendor session closed (0x9103)")


def cmd_liveview_frame(args):
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    cam = open_camera(args)
    try:
        cam.liveview_start()
        time.sleep(0.2)
        t0, n = time.perf_counter(), 0
        for i in range(args.count):
            f = cam.liveview_frame()
            if f is None:
                print("no frame (busy)")
                continue
            n += 1
            if i < args.save:
                (out / f"lv_{i:04d}.jpg").write_bytes(f.jpeg)
        dt = time.perf_counter() - t0
        print(f"{n} frames in {dt:.2f}s = {n / dt:.1f} fps; last jpeg {len(f.jpeg)} B,"
              f" roll={f.roll} pitch={f.pitch}")
    finally:
        cam.disconnect()


def cmd_liveview_view(args):
    from .viewer import run_viewer
    cam = open_camera(args)
    try:
        run_viewer(cam, args)
    finally:
        cam.disconnect()


def cmd_autofocus(args):
    cam = open_camera(args)
    try:
        if args.liveview:
            cam.liveview_start()
        t0 = time.perf_counter()
        r = cam.autofocus()
        print(f"0x9405 AF one-shot -> {rc_name(r.code)} in {(time.perf_counter() - t0) * 1000:.0f} ms")
        time.sleep(args.wait)
        for ev in cam.drain_events():
            print(ev)
    finally:
        cam.disconnect()


def _save_capture(cam: Camera, res: dict, outdir: pathlib.Path):
    outdir.mkdir(parents=True, exist_ok=True)
    for h, info in res["objects"]:
        t0 = time.perf_counter()
        data = cam.download(h)
        dt = time.perf_counter() - t0
        name = info.filename or f"obj_{h:08X}"
        (outdir / name).write_bytes(data)
        print(f"  saved {name}: {len(data) / 1e6:.2f} MB in {dt:.2f}s"
              f" = {len(data) / 1e6 / dt:.1f} MB/s")


def cmd_capture(args):
    cam = open_camera(args)
    try:
        if args.target:
            tgt = {"sd": Target.SD, "pc": Target.PC, "both": Target.BOTH}[args.target]
            cam.set_capture_target(tgt)
        print("capture target:", cam.get_capture_target())
        if args.liveview:
            cam.liveview_start()
        if args.af:
            print("AF:", rc_name(cam.autofocus().code))
            time.sleep(args.af_wait)
        res = cam.capture(timeout=args.timeout)
        print(f"0x9404 release -> {rc_name(res['release_rc'])} ({res['t_release'] * 1000:.0f} ms)")
        for ev in res["events"]:
            print(" ", ev)
        for h, info in res["objects"]:
            print(f"  object 0x{h:08X} {info.filename} {info.format_name} "
                  f"{info.compressed_size} B {info.width}x{info.height}")
        if "t_object" in res:
            print(f"  first object after {res['t_object']:.2f}s")
        if args.liveview:
            f = cam.liveview_frame()
            print("liveview after capture:", "ok" if f else "no frame")
        if args.download and res["objects"]:
            _save_capture(cam, res, pathlib.Path(args.download))
        time.sleep(0.5)
        for ev in cam.drain_events():
            print("  late", ev)
    finally:
        if args.target and args.restore_target is not None:
            cam.set_capture_target(args.restore_target)
        cam.disconnect()


def cmd_list_objects(args):
    cam = open_camera(args, vendor_session=not args.no_session)
    try:
        for sid in cam.storage_ids():
            try:
                si = cam.storage_info(sid)
                print(f"storage 0x{sid:08X} '{si.description}' free {si.free_bytes / 1e9:.1f} GB"
                      f" / {si.max_capacity / 1e9:.1f} GB, {si.free_images} images free")
            except Exception as e:
                print(f"storage 0x{sid:08X}: {e}")
            try:
                hs = cam.object_handles(sid)
            except Exception as e:
                print(f"  GetObjectHandles: {e}")
                continue
            print(f"  {len(hs)} objects")
            for h in hs[-args.last:]:
                i = cam.object_info(h)
                print(f"  0x{h:08X} {i.format_name:<20} {i.compressed_size:>10} {i.filename} {i.capture_date}")
    finally:
        cam.disconnect()


def cmd_download(args):
    cam = open_camera(args)
    try:
        h = int(args.handle, 0)
        info = cam.object_info(h)
        t0 = time.perf_counter()
        data = cam.download(h)
        dt = time.perf_counter() - t0
        out = pathlib.Path(args.out) / (info.filename or f"obj_{h:08X}")
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(data)
        print(f"{out}: {len(data)} B in {dt:.2f}s = {len(data) / 1e6 / dt:.1f} MB/s")
    finally:
        cam.disconnect()


def cmd_get_settings(args):
    cam = open_camera(args)
    try:
        names = args.names or list(PROPS)
        for name in names:
            code = PROPS.get(name) or int(name, 0)
            r = cam.t.read(0x9402, code)
            if not r.ok:
                print(f"{name:<20} 0x{code:08X}: {rc_name(r.code)}")
                continue
            items = ", ".join(f"{k:08X}={tlv_value(v) if len(v) in (1, 2, 4) else v.hex()}"
                              for k, v in parse_tlv(r.data).items())
            print(f"{name:<20} 0x{code:08X}: {items}")
            if args.raw:
                print(hexdump(r.data))
    finally:
        cam.disconnect()


def cmd_get_desc(args):
    cam = open_camera(args)
    try:
        code = PROPS.get(args.name) or int(args.name, 0)
        cur, vals, raw = cam.get_property_desc(code, args.size)
        print(f"current 0x{cur:X} ({cur}); {len(vals)} allowed:")
        print(" ".join(f"0x{v:X}" for v in vals))
        if args.raw:
            print(hexdump(raw, 1024))
    finally:
        cam.disconnect()


def cmd_set_setting(args):
    cam = open_camera(args)
    try:
        code = PROPS.get(args.name) or int(args.name, 0)
        val = int(args.value, 0)
        r = cam.set_property(code, val, args.size)
        print(f"0x9403 set 0x{code:08X}={val:#x} ({args.size} B) -> {rc_name(r.code)}")
    finally:
        cam.disconnect()


def cmd_events(args):
    cam = open_camera(args)
    try:
        if args.liveview:
            cam.liveview_start()
        print(f"listening {args.seconds}s ... operate the camera now")
        end = time.monotonic() + args.seconds
        while time.monotonic() < end:
            ev = cam.wait_event(set(range(0x10000)), end - time.monotonic())
            if ev:
                print(f"{time.strftime('%H:%M:%S')} {ev}")
    finally:
        cam.disconnect()


def main(argv=None):
    p = argparse.ArgumentParser(prog="lumix_usb")
    sp = p.add_subparsers(dest="cmd", required=True)
    sp.add_parser("detect").set_defaults(fn=cmd_detect)
    sp.add_parser("device-info").set_defaults(fn=cmd_device_info)
    c = sp.add_parser("connect"); c.add_argument("--hold", type=float, default=1.0)
    c.set_defaults(fn=cmd_connect)
    c = sp.add_parser("liveview-frame"); c.add_argument("--count", type=int, default=30)
    c.add_argument("--save", type=int, default=1); c.add_argument("--out", default=str(ROOT / "samples/lv"))
    c.set_defaults(fn=cmd_liveview_frame)
    c = sp.add_parser("liveview-view"); c.add_argument("--size", default=None)
    c.set_defaults(fn=cmd_liveview_view)
    c = sp.add_parser("autofocus"); c.add_argument("--liveview", action="store_true")
    c.add_argument("--wait", type=float, default=1.5); c.set_defaults(fn=cmd_autofocus)
    c = sp.add_parser("capture")
    c.add_argument("--target", choices=["sd", "pc", "both"])
    c.add_argument("--restore-target", type=int, default=None)
    c.add_argument("--liveview", action="store_true"); c.add_argument("--af", action="store_true")
    c.add_argument("--af-wait", type=float, default=1.0)
    c.add_argument("--timeout", type=float, default=15.0)
    c.add_argument("--download", nargs="?", const=str(ROOT / "samples/photos"))
    c.set_defaults(fn=cmd_capture)
    c = sp.add_parser("list-objects"); c.add_argument("--last", type=int, default=5)
    c.add_argument("--no-session", action="store_true"); c.set_defaults(fn=cmd_list_objects)
    c = sp.add_parser("download"); c.add_argument("handle")
    c.add_argument("--out", default=str(ROOT / "samples/photos")); c.set_defaults(fn=cmd_download)
    c = sp.add_parser("get-settings"); c.add_argument("names", nargs="*")
    c.add_argument("--raw", action="store_true"); c.set_defaults(fn=cmd_get_settings)
    c = sp.add_parser("get-desc"); c.add_argument("name"); c.add_argument("--size", type=int, default=2)
    c.add_argument("--raw", action="store_true"); c.set_defaults(fn=cmd_get_desc)
    c = sp.add_parser("set-setting"); c.add_argument("name"); c.add_argument("value")
    c.add_argument("--size", type=int, default=2); c.set_defaults(fn=cmd_set_setting)
    c = sp.add_parser("events"); c.add_argument("--seconds", type=float, default=20)
    c.add_argument("--liveview", action="store_true"); c.set_defaults(fn=cmd_events)
    args = p.parse_args(argv)
    args.fn(args)


if __name__ == "__main__":
    main()
