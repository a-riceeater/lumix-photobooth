# Troubleshooting & recovery

| Symptom | Cause | Fix |
|---|---|---|
| `no Panasonic (VID 04DA) WPD device found` | camera off, USB mode not PC(Tether), cable | Check camera shows tether/USB screen; Device Manager should list `DC-S5M2` under Portable Devices. |
| Release OK but no image event | AF-S could not focus (tethr), or SDRAM queue blocked by a pending object | Use MF/AF-C or AF first; drain `0x12345678` until InvalidParameter. |
| Setter returns InvalidParameter | issued within ~50 ms after liveview stop / while lens moves | retry after 300 ms (built in). |
| SetProperty OK but value unchanged/odd | camera accepts out-of-list values | validate with 0x9108, read back with 0x9402. |
| `ParameterNotSupported` / `InvalidStorageID` listing files | PC(Tether) hides the card | expected; use event handles. |
| Camera left in PC capture target | test aborted | `python -m lumix_usb capture --target sd` or run `connect` + set target 0. |
| WPD `OSError`/`COMError` or WPD_EVENT_DEVICE_REMOVED (exact HRESULTs PENDING unplug test) | cable unplugged, camera slept/powered off | close transport, re-enumerate, reopen (see `Camera.reconnect`). |
| Two programs controlling the camera | LUMIX Tether running | close Tether first. |

## Recovery strategy (implemented in `lumix_usb.recovery`)
1. Any transport exception or WPD `DEVICE_REMOVED` → mark disconnected.
2. Close/forget the IPortableDevice (ignore errors).
3. Poll enumeration every 1 s until VID 04DA reappears.
4. Reopen, re-send 0x9102, re-apply capture target, liveview size, restart liveview
   if it was on.
5. Objects announced before the drop: in PC target try `GetObjectInfo(0x12345678)`
   to see if an image is still queued.
