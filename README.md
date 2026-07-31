# AbundanceDeviceKit

Swift client library for the Abundance egocentric capture device: pair
over its Wi-Fi network, control and monitor recording, stream the viewfinder,
and carry finished sessions off the device with verified hashes — or hand the
upload off to the device itself with Station.

- **Swift 6**, strict concurrency, every public type `Sendable`
- **iOS 17+ / macOS 14+**, zero external dependencies
- Device firmware ≥ 1.0.6 (Station endpoints require ≥ 1.1.0)

The full reference (every type and method, with examples) is the companion
page `abundance-swift-sdk-reference.html`; the wire contract it sits on is
`a4-api-reference.html`.

## Install

```swift
dependencies: [
    .package(path: "../abundance-app3/sdk")
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "AbundanceDeviceKit", package: "AbundanceDeviceKit")
    ])
]
```

App targets also need `NSAppTransportSecurity → NSAllowsLocalNetworking`,
`NSLocalNetworkUsageDescription`, and (for `joinDeviceNetwork`) the Hotspot
Configuration entitlement.

## Quick start

```swift
import AbundanceDeviceKit

// First run — join the SoftAP, probe, pair
try await AbundanceDeviceFinder.joinDeviceNetwork(passphrase: devicePassword)
guard let found = await AbundanceDeviceFinder.probe() else { throw Onboarding.notFound }
let device = try await AbundanceDevice.pair(
    host: found.host, clientID: installID, clientName: "Acme Capture"
)
persist(device.credentials)   // Codable — Keychain/UserDefaults, your call

// Every later run
let device = try await AbundanceDevice.connect(credentials: saved)
try await device.refreshTokenIfNeeded()

// Observe
Task {
    for await event in device.events.subscribe() { handle(event) }
}

// Record (start/stop run the prescribed time-anchor exchange themselves)
try await device.recording.start()
try await device.recording.stop()

// Offload when the device announces the session is published
for await event in device.events.subscribe() {
    guard case .sessionPublished(let id, _) = event else { continue }
    for try await progress in device.recordings.offload(id, to: sessionsDir) {
        show(progress)
    }
    break
}
```

## Surface map

| Manager | Capability | What |
|---|---|---|
| `AbundanceDevice` | — | pair / connect, credentials + token refresh, `status()`, `identity()`, `deviceLog()` |
| `device.events` | metrics | multi-observer `AsyncStream<AbundanceEvent>` over one auto-reconnecting SSE connection |
| `device.recording` | control | idempotent `start()` / `stop()` with all clock anchoring built in: pre-start sync, background anchors while recording, closing anchors on stop |
| `device.preview` | control | raw H.264 NAL stream + `H264SampleBufferAssembler` + `PreviewVideoView` (iOS) |
| `device.recordings` | offload | list, manifest, verified streaming downloads with Range resume, ordered acks, discard, session logs, and the whole-session `offload(_:to:)` courier |
| `device.station` | config | Wi-Fi uplink + upload broker settings (firmware ≥ 1.1.0, BETA) |
| `AbundanceBroker` | — | `Codable` types for the broker contract your server implements |
| `device.maintenance` | control | storage breakdown, reboot, shutdown, SD eject |

## Design rules

- One thrown error type, `AbundanceError`; device failures carry the wire envelope's
  stable `code` and `retryable`.
- Closed wire enums decode unknown future values to `.unknown`, never fail.
- Optional snapshot groups stay optional — no fabricated zeros.
- Downloads verify SHA-256 against the manifest before a file reaches its
  destination; acks are fail-closed and ordered; destructive calls are
  explicit.
- Not in this library: CSV/clock-model parsing, credential storage, playback,
  cross-session upload scheduling.

## Tests

```
swift test
```

Wire fixtures come verbatim from the device API reference; the time-sync
algorithm, ABPV parser, error mapping, and broker contract are covered
host-side on macOS.
