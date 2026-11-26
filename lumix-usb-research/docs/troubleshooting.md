# Troubleshooting & recovery

| Symptom | Cause | Fix |
|---|---|---|
| `no Panasonic (VID 04DA) WPD device found` | camera off, USB mode not PC(Tether), cable | Check camera shows tether/USB screen; Device Manager should list `DC-S5M2` under Portable Devices. |
| Release OK but no image event | camera could not focus (silent refusal: VERIFIED in AF-C; AF-S per tethr, not yet tested here) or SDRAM queue blocked by a pending object | Run `autofocus_wait` first and check for 0x0004; drain `0x12345678` until InvalidParameter; use MF with fixed distance as fallback. |
| Setter returns InvalidParameter | issued within ~50 ms after liveview stop / while lens moves | retry after 300 ms (built in). |
| SetProperty OK but value unchanged/odd | camera accepts out-of-list values | validate with 0x9108, read back with 0x9402. |
| `ParameterNotSupported` / `InvalidStorageID` listing files | PC(Tether) hides the card | expected; use event handles. |
| Camera left in PC capture target | test aborted | `python -m lumix_usb capture --target sd` or run `connect` + set target 0. |
| WPD `OSError` HRESULT **0x8007001F** (ERROR_GEN_FAILURE) on the in-flight transaction, then **0x800701B1** (ERROR_DEVICE_NOT_CONNECTED) on reopen, then device absent from enumeration (VERIFIED) | cable unplugged, camera powered off | close transport, re-enumerate, reopen (see `Camera.reconnect`). |
| Two programs controlling the camera | LUMIX Tether running | close Tether first. |

## Physical disconnect test (VERIFIED, `test_reconnect_1795666463`)

120 s of liveview; the user unplugged the cable ~10 s, ~30 s, and once more
(cable or power cycle). Results:

| # | Failure detected | Liveview back | Gap | Reconnect actions |
|---|---|---|---|---|
| 1 | 20:14:38.96 | 20:14:53.26 | 14.3 s | reopen, 0x9102 OK, 0x9412 start OK |
| 2 | 20:15:03.47 | 20:15:36.77 | 33.3 s | same |
| 3 | 20:15:44.28 | 20:15:58.59 | 14.3 s | same |

* Liveview ran at 30 fps between outages and immediately after each reconnect
  (first second partial). 3/3 recoveries without restarting the process.
* Detection is by the failing transaction (next liveview read, ≤33 ms after the
  unplug); **no WPD_EVENT_DEVICE_REMOVED** reached the event sink first.
* The gap is dominated by the time the cable was out; from re-enumeration to
  liveview took ≤1 s poll interval + ~30 ms (reopen, 0x9102, 0x9412). The poll
  interval is now 0.5 s.
* Camera state needed after reconnect: only liveview restart (and capture target
  / liveview size if the app changed them — `ResilientCamera` re-applies them).
* An object announced but not downloaded before the drop is not re-announced
  (INFERRED; in PC target check `GetObjectInfo(0x12345678)` after reconnect).

## Recovery strategy (implemented in `lumix_usb.recovery`)
1. Any transport exception or WPD `DEVICE_REMOVED` → mark disconnected.
2. Close/forget the IPortableDevice (ignore errors).
3. Poll enumeration every 0.5 s until VID 04DA reappears.
4. Reopen, re-send 0x9102, re-apply capture target, liveview size, restart liveview
   if it was on.
5. Objects announced before the drop: in PC target try `GetObjectInfo(0x12345678)`
   to see if an image is still queued.
