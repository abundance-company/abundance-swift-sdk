![Thumbnail](./thumbnail.png)
# Abundance Swift SDK

Swift client library for the Abundance device: pairing, recording control,
preview streaming, and session offload.

SDK reference: https://abundance.company/swift-sdk
Device API: https://abundance.company/api

## What's here

- `Sources/AbundanceDeviceKit` — the Swift library.
- `Examples/AbundanceSample` — a complete iPhone app built on the SDK.
- `reference-broker/` — a small Go implementation of the Station upload
  broker contract (announce, artifact PUT, complete). Run it as-is to receive
  device uploads on your own machine or an S3-compatible store, or read it as
  the reference for implementing the three endpoints in your backend. See
  `reference-broker/deploy/README.md` for local, Fly.io, and S3 setups.
