// The Station reference broker: the three-endpoint upload service the device
// talks to, as documented in api.html and mirrored by AbundanceBroker.swift.
// Standalone module so customers can `go run ./cmd/abundance-broker-ref` or
// import the broker package into their own service.
module github.com/abundance-company/abundance-swift-sdk/reference-broker

go 1.25
