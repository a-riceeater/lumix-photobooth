"""Minimal Tk live-preview window used to validate continuous liveview.

Keys: f = one-shot AF, space = capture + download, q/Esc = quit.
This is a test harness, not booth UI.
"""
from __future__ import annotations

import io
import pathlib
import threading
import time
import tkinter as tk

from PIL import Image, ImageTk

from .panasonic import Camera


def run_viewer(cam: Camera, args) -> None:
    root = tk.Tk()
    root.title("LUMIX liveview (f=AF, space=capture, q=quit)")
    label = tk.Label(root, bg="black")
    label.pack()
    status = tk.Label(root, text="", anchor="w", font=("Consolas", 10))
    status.pack(fill="x")
    state = {"frames": 0, "t0": time.perf_counter(), "img": None, "busy": False, "msg": ""}
    lock = threading.Lock()
    outdir = pathlib.Path(__file__).resolve().parents[2] / "samples/photos"

    cam.liveview_start()
    time.sleep(0.2)

    def action(fn):
        def run():
            state["busy"] = True
            try:
                state["msg"] = fn()
            except Exception as e:
                state["msg"] = f"error: {e}"
            state["busy"] = False
        threading.Thread(target=run, daemon=True).start()

    def do_af():
        return f"AF rc=0x{cam.autofocus().code:04X}"

    def do_capture():
        res = cam.capture()
        if not res["objects"]:
            return f"release rc=0x{res['release_rc']:04X}, no object"
        h, info = res["objects"][-1]
        t0 = time.perf_counter()
        data = cam.download(h)
        outdir.mkdir(parents=True, exist_ok=True)
        (outdir / info.filename).write_bytes(data)
        return (f"{info.filename} {len(data) / 1e6:.1f} MB, object after "
                f"{res['t_object']:.2f}s, download {time.perf_counter() - t0:.2f}s")

    def tick():
        f = cam.liveview_frame(retries=1)
        if f is not None:
            state["frames"] += 1
            im = Image.open(io.BytesIO(f.jpeg))
            state["img"] = ImageTk.PhotoImage(im)
            label.configure(image=state["img"])
        dt = time.perf_counter() - state["t0"]
        status.configure(text=f"{state['frames'] / dt:5.1f} fps  {'BUSY ' if state['busy'] else ''}{state['msg']}")
        if dt > 5:
            state["frames"], state["t0"] = 0, time.perf_counter()
        root.after(1, tick)

    root.bind("f", lambda e: action(do_af))
    root.bind("<space>", lambda e: action(do_capture))
    root.bind("q", lambda e: root.destroy())
    root.bind("<Escape>", lambda e: root.destroy())
    root.after(1, tick)
    root.mainloop()
