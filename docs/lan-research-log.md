# S5II over Wi-Fi — still-photo research log

Goal: still capture + full-resolution JPEG download + preview over LAN, for the booth's
"camera over network" option. Builds on `LUMIX_S5II_LAN_RECORD_CONTROL.md` (video record
control, verified) and `~/Developer/S5II-Bridge` (pairing/keepalive implementation).

## Session 1 — 2026-11-26, DC-S5M2 fw 3.61 at 10.0.0.177, mode dial M

Session owner: a single long-lived holder built on S5II-Bridge `tools/lumix.py`
(`Lumix.pair()` + 3 s `getstate` keepalive + `err_busy` circuit breaker).

| # | Request | Result |
|---|---|---|
| 1 | `/24` sweep on :60606 | found in 0.76 s ✅ |
| 2 | `GET :60606/Lumix/Server0/ddd` (full) | `deviceType` **MediaServer:1**, DLNA `M-DMS-1.50`, `X_AdditionalFunction CPRemoteView`, **`X_PTPPortNo 15740`**, services ContentDirectory (`/Server0/CDS_control`) and ConnectionManager |
| 3 | TCP 15740 | **closed** (PTP/IP not available over Wi-Fi, matches the protocol doc) |
| 4 | CDS `GetSystemUpdateID`, **no session** | HTTP **403** |
| 5 | CDS `Browse 0 BrowseDirectChildren`, no session | HTTP 403 |
| 6 | Pair as "S5II Bridge" (utf-16-le) | `ok_under_research` → operator accepted on camera → `ok,…,<SESSION_ID>` ✅. After pairing: `cammode=play`, `current_sd=sd2` |
| 7 | CDS `GetSystemUpdateID` **with `X-SESSION_ID`** | 200, `Id=1` ✅ |
| 8 | CDS `Browse 0 BrowseDirectChildren` with session | 500 UPnP **701 No such object** |
| 9 | `cam.cgi?mode=get_content_info` | **`err_busy`** (circuit breaker latched) |
| 10 | (operator checked body: normal screen, dial M; latch cleared) | |
| 11 | CDS `Browse 0 BrowseMetadata` | 200: root container `id=0`, title `root` ✅ |
| 12 | CDS `Browse 0 BrowseDirectChildren` (2nd try) | **no reply within 10 s** |
| 13 | CDS `GetSearchCapabilities` | no reply (10 s) |
| 14 | `getstate` / CDS `GetSystemUpdateID` | no reply; keepalive `getstate` then returned **`err_busy`** |
| 15 | All traffic stopped (holder killed) | **camera locked — recovered by battery pull** |

## Conclusions

* The DLNA ContentDirectory is reachable **only with a paired session** and is the most
  plausible route for JPEG download, but **`BrowseDirectChildren` on the root hung the
  camera's servers** in `cammode=play`, and further traffic during the hang (requests 13–14
  plus the 3 s keepalive) ended in a hard lock. Do not repeat request 12.
* `mode=get_content_info` returns `err_busy` in `cammode=play` on this firmware.
* Still capture (`camcmd capture`) and the preview stream were **not reached**.

## Rules added for future probing

1. **A timeout is a stop sign**, same as `err_busy`: stop every request, including the
   keepalive, and have a person check the body before anything else is sent.
2. Never send a request the camera has not been seen to answer quickly in this exact
   mode (play vs rec) without first capturing what the official app sends.
3. Prefer **observing LUMIX Sync** over guessing: mirror the iPhone's traffic with
   `rvictl -s <iPhone UDID>` on the Mac and record with Wireshark/tcpdump while Sync
   browses, imports one photo, and remote-shoots a still. Implement only that sequence,
   in that order, with those modes — the approach that worked for USB (`tether-traffic.md`).
