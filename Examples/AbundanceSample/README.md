# Abundance Sample

A complete iPhone app for the Abundance capture device, built entirely
on the public `AbundanceDeviceKit` SDK. It reproduces the production app's
UI — radar pairing, live viewfinder, one-button recording, automatic offload
into an on-phone library, device forensics — so every screen doubles as a
worked example of the SDK surface behind it.

## Build & run

```
brew install xcodegen
cd sdk/Examples/AbundanceSample
xcodegen
open AbundanceSample.xcodeproj
```

iOS 17+. Simulator builds work for browsing the UI (`-uiPairFound` renders the
radar's found state; `-uiTab recordings|settings` opens on a tab); a real
device needs a physical iPhone joined to its `A4-Abundance-…` Wi-Fi (the
SoftAP name the firmware broadcasts).

## Where each SDK area is showcased

| SDK area | In this app |
|---|---|
| `AbundanceDeviceFinder.probe()` | `PairDeviceView` polls it every 2 s while the radar spins — landing on the SoftAP is all it takes for the camera to appear |
| `AbundanceDevice.pair` / `.connect` / `refreshTokenIfNeeded` | `DeviceStore.pair` (first tap) and `DeviceStore.reconnect` (silent re-attach with stored `AbundanceCredentials` when the radar sees a known device) |
| `device.events.subscribe()` | `DeviceStore.handle(_:)` — one `for await` loop drives connection state, every snapshot, the interruption banner, storage warnings, and offload nudges |
| `device.recording.start()` / `stop()` | The record button. All UTC anchoring (pre-start sync, background anchors, closing anchors) happens inside the SDK calls |
| `device.preview.nalUnits()` + `H264SampleBufferAssembler` + `SampleBufferVideoView` | `PreviewModel` — the raw altitude, used because the viewfinder wants connecting/stalled/error phases. `PreviewVideoView(preview:)` is the one-line alternative |
| `device.recordings.offload(_:to:)` | `OffloadStore` — the whole-session courier (manifest → verified downloads → ordered acks → logs) projected into per-session progress UI |
| `device.recordings.list()` / `discard` | The "On the camera" section in Recordings; incomplete sessions offer Discard, the only way to reclaim their space |
| `device.deviceLog(lines:)` | Settings ▸ Device details — the device's durable event log, newest first |
| `AbundanceError` | `DeviceStore.describe(_:)` — the single place wire errors become user-facing text |

Not shown: Station (`device.station`, firmware ≥ 1.1.0) and the `AbundanceBroker`
server types — they need an uplink network and an ingest service, not a phone
UI. `device.maintenance` is also left out; see the SDK reference for both.

## Notes for production apps

- Credentials are persisted in `UserDefaults` here for brevity. They grant
  control of the camera — store them in the Keychain (`AbundanceCredentials` is
  `Codable` either way).
- The pairing screen sends the user to iOS Settings to join the camera's
  Wi-Fi. With the Hotspot Configuration entitlement (paid team),
  `AbundanceDeviceFinder.joinDeviceNetwork(passphrase:)` does it in-app.
- Playback is app-side by design (the SDK stops at verified files): downloaded
  `.ts` segments play through a hidden HLS playlist served from a loopback
  HTTP server (`LocalMediaServer`), because AVPlayer accepts neither bare
  `.ts` files nor `file://` playlists.
