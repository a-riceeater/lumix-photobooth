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

## Session 2 — 2026-11-26 (after battery pull and re-arming remote mode)

Holder v2: same pairing, plus a **hard stop** — the first timeout or `err_busy` anywhere
(keepalive included) halts all traffic. Sequence taken from pylumix (`abichinger/pylumix`,
`core.py`), which other projects (libgphoto2 #409, LumixSecurity, lumix-remote) agree with.

| # | Request | Result |
|---|---|---|
| 1 | pair (prompt accepted on camera) | session ✅ |
| 2 | `getstate` | `cammode=play`, `play=stop`, `current_sd=sd2` |
| 3 | `camcmd playmode` | `ok`, 88 ms ✅ |
| 4 | `get_content_info` | `ok`: `total_content_number=9`, `current_position=8` (16 ms) ✅ — the earlier `err_busy` was caused by skipping step 3 |
| 5 | CDS `Browse` ObjectID `0`, `StartingIndex=8`, `RequestedCount=1`, `<pana:X_FromCP xmlns:pana="urn:schemas-panasonic-com:pana">LumixLink2.0</pana:X_FromCP>`, `User-Agent: Panasonic Android/1 DM-CP`, `X-SESSION_ID` | 200 in 114 ms ✅. One `imageItem` with `res` URLs on **:50001**: `DO<id>.JPG` original (`PANASONIC.COM_PN=CAM_RAW_JPG`, `OriginalFileName='P1542444.JPG'`, `size` bytes), `DO<id>.RW2`, `DT<id>.JPG` thumb (~5 KB), `DL<id>.JPG` large preview (~100 KB) |
| 6 | `GET :50001/DO11542444.JPG` | 11.6 MB, 6000×4000, Panasonic DC-S5M2, **3.8 s** ✅ |
| 7 | `camcmd recmode` (camera idle, play) | `ok` 503 ms; `getstate` after 6 s: `cammode=rec`, `rec=off` ✅ |
| 8 | `camcmd capture` | `ok` in **19 ms**; `getstate` polled every 0.3 s: `sd2_access` on at 1.3 s, off at **2.3 s** ✅ (stayed `cammode=rec`) |
| 9 | `playmode` → wait 1 s → `get_content_info` → Browse last item → download | total 9→**10**, newest `P1542445.JPG`, 11.0 MB 6000×4000 in 7.3 s; whole step 10.2 s ✅ |
| 10 | `recmode` → `getstate` | `cammode=rec` ✅ |
| 11 | bind UDP 49199, `startstream&value=49199` | `ok` 23 ms; **29.9 fps**, datagrams 6.9–23 KB (~0.65 MB/s), first after 0.44 s ✅ |
| 12 | datagram layout | **one complete JPEG per datagram** (640×480), JPEG starts at **32 + u16 big-endian at offset 30** (= 262 on every sample), ends at the datagram end ✅ |
| 13 | (listener closed while the stream kept running) second `startstream&value=49199` | **`err_busy`** → holder halted everything → session lapsed, camera showed "connection lost"; body fine, no lock |

### Working recipe (verified)

```
pair → getstate → (cammode=play, rec=off) recmode → poll getstate until cammode=rec
bind UDP port → startstream&value=<port>           (preview; keeps rec mode)
per photo:   camcmd capture → poll getstate until sd_access/sd2_access on→off
per session: stopstream → playmode → wait 1 s → get_content_info (total N)
             → Browse StartingIndex=N-k RequestedCount=k (X_FromCP) → GET each DO*.JPG
             → recmode → poll cammode=rec → startstream (fresh)
```

### New rules
* Never send `startstream` while a stream is already running; keep the UDP listener open
  for as long as the camera may be streaming; `stopstream` before switching to playback.
* Browse only `StartingIndex=N-k` with a small count — never list from 0.

## Session 3 — 2026-11-26: the app's own Swift code against the camera

The iOS camera files (`LumixWiFiProtocol`, `LumixWiFiClient`, `WiFiLiveViewReceiver`,
`LumixWiFiCameraService`) compiled unchanged into a macOS command-line harness and driven
like a booth session (connect → 3 captures → `collectPhotos(3)` → hold the session).

| Run | Outcome | Lesson |
|---|---|---|
| 1 | READY in 2.6 s, but shot 1: no card write | keepalive's mode restore ran concurrently with the capture → **camera operations must be serialized** |
| 2 | Shot 1: no card write | the **first getstate after pairing reported `rec` but the camera was in `play`**; in play both `startstream` and `capture` are silently ignored (0 fps, no write) → **check the mode fresh before every capture** and again 1.5 s after the stream starts |
| 3 | `recmode` → `err_critical` (5.2 s), no `rec` in 20 s; re-pair → `recmode` → `err_busy` → **halted** | the camera was showing **"not connected to app"** after the previous short-lived run released its session; a dialog on the body blocks mode changes. Body fine. The booth app holds one session for its lifetime, so this is a test-harness artefact |
| 4 | ✅ **full success** | see below |

Run 4 (after the message on the camera was dismissed):

```
pair (silent, remembered client) → device_name ok → startstream ok
→ 1.5 s later: play → stopstream ok (516 ms) → recmode ok (513 ms) → startstream ok
READY 4.09 s, live view 30.5 fps (640×432)
capture ×3: ok (36–124 ms), card write finished after 2.04–2.09 s each
collect: stopstream → playmode ok (1235 ms) → get_content_info (17 ms)
         → Browse 10+1, 11+1, 12+1 (57–69 ms each) → P1542446/47/48.JPG
         → GET DO…JPG ×3: 8.6–8.7 MB, 3.4–3.6 s each (24.9 MB in 13.7 s)
         → recmode ok (525 ms) → startstream ok → rec, 30.5 fps
```

All three files: 6000×4000, Model DC-S5M2. `stopstream` and `setsetting device_name`
(with the session header) are verified too.
