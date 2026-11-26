# Initialization, session and teardown

## Camera preconditions
* USB mode set to **PC(Tether)** on the camera (Setup ▸ USB ▸ USB Mode). In this
  mode the camera enumerates as PTP 04DA:2382 and accepts remote control.
* Card contents are not browsable in this mode (GetStorageIDs returns IDs with
  no logical storage, see file-transfer.md).

## Minimal verified sequence (our implementation)

```
1. Discovery     enumerate WPD devices, pick PnP ID containing "vid_04da"
                 (ICC: ICDeviceBrowser, filter vendor 0x04DA)
2. Open          IPortableDevice::Open  -> driver performs PTP OpenSession(0x1002)
                 Advise(event callback)  -> interrupt-endpoint events start flowing
3. DeviceInfo    0x1001 (optional; sanity check VendorExtensionID == 0x1C)
4. Vendor sess.  0x9102 p1=0x00010001 -> OK, rparam 0x00010001   (optional, see below)
5. Status        0x940A (capture target), 0x9414(0x0D800011/12) (liveview setting)
...  work ...
6. Teardown      0x9412(0x0D000011) if liveview on
                 0x9103 p1=0x00010001
                 Unadvise; IPortableDevice::Close -> driver CloseSession(0x1003)
```
Verified repeatedly (`connect`, `status`, all `scripts/test_*.py`).

## Is 0x9102 required?
No for everything verified so far: GetProperty, liveview start/frames, and
capture (one SD shot) all succeeded **without** 0x9102. libgphoto2 never sends
it; tethr and (reportedly) LUMIX Tether do. We send it by default to match the
official software. Its purpose should be determined from Tether traffic
(PENDING). Hypothesis (INFERRED): it marks the host as a tether controller (UI
indication / locking some camera menus).

## Background traffic / keepalive
None observed to be required: no test needed a periodic command, and sessions
lasting up to ~25 s with long gaps between transactions stayed usable. A
multi-minute idle test is PENDING. The camera spontaneously emits C107
status events; no host response is needed except C101, which we ack with 0x9401.

## Events that require a host response
| Event | Response | Required? |
|---|---|---|
| C101 (p1=0x01000010) | 0x9401(p1) data-in (~4.9 KB status) | Not strictly (capture works without), done for parity with Tether |

## Persistent state the host can change
| State | Persists across vendor session? | Notes |
|---|---|---|
| Capture target (0x940B) | **Yes** (verified) | Restore to SD when finishing so the camera behaves normally. |
| Image quality, ISO, etc. (0x9403) | Yes (normal camera settings) | Restore after tests. |
| Liveview size (0x9415) | Persists within a session after liveview stop (verified); across sessions INFERRED | |

## Reconnect / recovery
See troubleshooting.md. Strategy: on any `OSError`/`COMError` from WPD or a
`WPD_EVENT_DEVICE_REMOVED`, drop the IPortableDevice, re-enumerate every 1 s,
reopen, re-send 0x9102, re-apply capture target and liveview state. PENDING:
physical unplug/replug test.
