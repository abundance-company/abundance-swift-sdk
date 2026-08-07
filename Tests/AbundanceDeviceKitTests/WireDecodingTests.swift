import XCTest
@testable import AbundanceDeviceKit

/// Wire fixtures lifted verbatim from the device API reference — if these
/// decode, the SDK matches the published contract.
final class WireDecodingTests: XCTestCase {
    override func tearDown() {
        StationURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - DeviceSnapshot

    func testSnapshotWhileRecording() throws {
        let json = """
        {
          "meta": { "boot_id": "c4a7e9d2-5b31-4f88-9a02-6e7d13c8b540", "device_uptime_s": 8123.4, "time_synced": true },
          "camera": { "state": "ready", "device_path": "/dev/video0", "uptime_s": 8042.7 },
          "storage": {
            "record_target": "/mnt/sdcard/recordings",
            "volumes": [
              { "mountpoint": "/mnt/sdcard", "mounted": true, "uptime_s": 8109.2,
                "total_bytes": 127865454592, "free_bytes": 98123456512,
                "used_bytes": 29741998080, "used_pct": 23.3 }
            ]
          },
          "recording": {
            "state": "recording", "available": true, "segment_seconds": 120, "segments_on_disk": 3,
            "current_segment": { "name": "s000042_k3x9qz_00003.ts", "index": 3, "size_bytes": 58720256 },
            "session_id": "s000042_k3x9qz", "uptime_s": 421.3
          },
          "stream": { "state": "idle", "available": true, "port": 8443 }
        }
        """
        let snapshot = try JSONDecoder.abundance.decode(DeviceSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.cameraState, .ready)
        XCTAssertEqual(snapshot.recordingState, .recording)
        XCTAssertEqual(snapshot.streamState, .idle)
        XCTAssertEqual(snapshot.recording?.sessionId, "s000042_k3x9qz")
        XCTAssertEqual(snapshot.recording?.currentSegment?.sizeBytes, 58_720_256)
        XCTAssertEqual(snapshot.storage?.volumes?.first?.freeBytes, 98_123_456_512)
        XCTAssertEqual(snapshot.meta?.timeSynced, true)
        XCTAssertNil(snapshot.publishing)
        XCTAssertNil(snapshot.network)
    }

    func testSnapshotWithAbsentGroupsAndUnknownState() throws {
        let json = """
        {
          "meta": { "boot_id": "b", "device_uptime_s": 84.9, "time_synced": false },
          "camera": { "state": "hyperspace" },
          "recording": { "state": "idle", "available": true, "segment_seconds": 120, "segments_on_disk": 0 }
        }
        """
        let snapshot = try JSONDecoder.abundance.decode(DeviceSnapshot.self, from: Data(json.utf8))
        // Future firmware states decode to .unknown, never fail the parse.
        XCTAssertEqual(snapshot.cameraState, .unknown)
        XCTAssertNil(snapshot.storage)
        XCTAssertNil(snapshot.stream)
    }

    func testPublishingSnapshot() throws {
        let json = """
        { "meta": { "boot_id": "b", "device_uptime_s": 1, "time_synced": true },
          "publishing": { "session_id": "s000042_k3x9qz", "phase": "converting", "percent": 72.5 } }
        """
        let snapshot = try JSONDecoder.abundance.decode(DeviceSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.publishingPhase, .converting)
        XCTAssertEqual(snapshot.publishing?.percent, 72.5)
    }

    // MARK: - Error envelope

    func testErrorEnvelope() throws {
        let json = """
        { "error": { "code": "time_not_synced",
                     "message": "synchronize UTC time immediately before recording",
                     "retryable": true } }
        """
        let error = DeviceConnection.error(status: 412, body: Data(json.utf8))
        guard case .device(let device) = error else {
            return XCTFail("expected .device, got \(error)")
        }
        XCTAssertEqual(device.code, .timeNotSynced)
        XCTAssertTrue(device.retryable)
    }

    func testErrorEnvelopeWithDetails() throws {
        let json = """
        { "error": { "code": "sha_mismatch", "message": "segment hash does not match",
                     "details": { "expected": "aa", "got": "bb" }, "retryable": false } }
        """
        let error = DeviceConnection.error(status: 409, body: Data(json.utf8))
        guard case .device(let device) = error else {
            return XCTFail("expected .device, got \(error)")
        }
        XCTAssertEqual(device.code, .shaMismatch)
        XCTAssertEqual(device.details["expected"], "aa")
        XCTAssertEqual(device.details["got"], "bb")
    }

    func testPlainTextErrorFallsBackToStatus() {
        // Go's mux answers wrong method / unknown path outside the envelope.
        let error = DeviceConnection.error(status: 405, body: Data("Method Not Allowed\n".utf8))
        guard case .unexpectedStatus(405) = error else {
            return XCTFail("expected .unexpectedStatus(405), got \(error)")
        }
    }

    func testUnknownErrorCodeIsPreserved() {
        XCTAssertEqual(ErrorCode("flux_capacitor"), .unknown("flux_capacitor"))
        XCTAssertEqual(ErrorCode("join_failed"), .joinFailed)
        XCTAssertEqual(ErrorCode("station_enabled"), .stationEnabled)
        XCTAssertEqual(ErrorCode("internal"), .internalError)
        XCTAssertEqual(ErrorCode("update_already_attempted"), .updateAlreadyAttempted)
        XCTAssertEqual(ErrorCode.updateAlreadyAttempted.rawValue, "update_already_attempted")
        XCTAssertEqual(ErrorCode.stationEnabled.rawValue, "station_enabled")
        XCTAssertEqual(ErrorCode.internalError.rawValue, "internal")
    }

    // MARK: - Manifest

    func testManifestDecode() throws {
        let json = """
        {
          "version": 1, "state": "published", "session_id": "s000042_k3x9qz",
          "device_id": "7f3c1e2a-9b4d-4c6e-8a15-2d9f0b7c4e21",
          "factory_uuid": "2f2a8be7-2e39-41ce-b5d7-d771b9f1be91",
          "camera_firmware_version": "NORI-CAM-0001",
          "nanopi_firmware_version": "1.0.15",
          "recovered": false, "dropped_segment_indices": [],
          "utc_accuracy_ns": 2213000,
          "absolute_uvc_latency_calibrated": true,
          "imu_time_offset_ns": -5400000,
          "video_bitrate_mbps": 16,
          "segments": [
            { "index": 0,
              "video":  { "name": "s000042_k3x9qz_00000.ts", "size_bytes": 241594368, "sha256": "3b7f" },
              "imu":    { "name": "s000042_k3x9qz_00000.csv", "size_bytes": 3962144, "sha256": "9d4c" },
              "frames": { "name": "s000042_k3x9qz_00000_frames.csv", "size_bytes": 148262, "sha256": "5e2d" } }
          ]
        }
        """
        let manifest = try JSONDecoder.abundance.decode(RecordingManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.state, .published)
        XCTAssertEqual(manifest.sessionID, "s000042_k3x9qz")
        XCTAssertEqual(manifest.utcAccuracyNanoseconds, 2_213_000)
        XCTAssertTrue(manifest.absoluteUVCLatencyCalibrated)
        XCTAssertEqual(manifest.imuTimeOffsetNanoseconds, -5_400_000)
        XCTAssertEqual(manifest.deviceId, "7f3c1e2a-9b4d-4c6e-8a15-2d9f0b7c4e21")
        XCTAssertEqual(manifest.factoryUuid, "2f2a8be7-2e39-41ce-b5d7-d771b9f1be91")
        XCTAssertEqual(manifest.cameraFirmwareVersion, "NORI-CAM-0001")
        XCTAssertEqual(manifest.nanopiFirmwareVersion, "1.0.15")
        XCTAssertEqual(manifest.videoBitrateMbps, 16)
        XCTAssertEqual(manifest.segments.count, 1)
        XCTAssertEqual(manifest.segments[0].video.sizeBytes, 241_594_368)
        XCTAssertEqual(manifest.segments[0].frames.sha256, "5e2d")
    }

    // MARK: - Time anchor (fpga_ns vs monotonic_ns)

    func testTimeAnchorDecodesFinalizedFieldName() throws {
        let json = """
        { "time_synced": true, "boot_id": "b", "utc_unix_ns": 1784873042123456789,
          "fpga_ns": 8123456789012, "uncertainty_ns": 3500000 }
        """
        let anchor = try JSONDecoder.abundance.decode(TimeAnchor.self, from: Data(json.utf8))
        XCTAssertEqual(anchor.fpgaNanoseconds, 8_123_456_789_012)
        XCTAssertEqual(anchor.uncertaintyNanoseconds, 3_500_000)
    }

    func testTimeAnchorDecodesFirmware106FieldName() throws {
        let json = """
        { "time_synced": true, "boot_id": "b", "utc_unix_ns": 1784873042123456789,
          "monotonic_ns": 8123456789012 }
        """
        let anchor = try JSONDecoder.abundance.decode(TimeAnchor.self, from: Data(json.utf8))
        XCTAssertEqual(anchor.fpgaNanoseconds, 8_123_456_789_012)
        // uncertainty defaults when the wire omits it
        XCTAssertEqual(anchor.uncertaintyNanoseconds, 1_000_000_000)
    }

    // MARK: - SSE frames

    func testSSEFrameDecoding() throws {
        let lines = [
            #"{"v":1,"seq":8,"ts":1784873304.201,"data":{"type":"session_published","session":"s000042_k3x9qz","segment_count":2}}"#,
            #"{"v":1,"seq":9,"ts":1784873304.412,"data":{"type":"segment_ready","segment":{"session":"s000042_k3x9qz","index":0,"video":{"name":"a.ts","size_bytes":1,"sha256":"aa"},"imu":{"name":"a.csv","size_bytes":2,"sha256":"bb"},"frames":{"name":"a_frames.csv","size_bytes":3,"sha256":"cc"}}}}"#,
            #"{"v":1,"seq":14,"ts":1784873891.032,"data":{"type":"error","code":"recording_interrupted","message":"gst-launch exited","snapshot":{"meta":{"boot_id":"b","device_uptime_s":1,"time_synced":true},"recording":{"state":"recording","available":true,"segment_seconds":120,"segments_on_disk":7,"session_id":"s000043_mv2rte","gst_restarts":1}}}}"#,
        ]
        let frames = try lines.map {
            try JSONDecoder.abundance.decode(Envelope<LiveFrame>.self, from: Data($0.utf8)).data
        }

        XCTAssertEqual(frames[0].type, "session_published")
        XCTAssertEqual(frames[0].session, "s000042_k3x9qz")
        XCTAssertEqual(frames[0].segmentCount, 2)

        XCTAssertEqual(frames[1].segment?.index, 0)
        XCTAssertEqual(frames[1].segment?.frames.sha256, "cc")

        XCTAssertEqual(EventCode(frames[2].code ?? ""), .recordingInterrupted)
        XCTAssertEqual(frames[2].snapshot?.recording?.gstRestarts, 1)
    }

    // MARK: - Listings

    func testRecordingsListShapes() throws {
        let json = """
        { "recordings": [
            { "id": "s000042_k3x9qz", "segment_count": 2, "total_bytes": 486842032, "state": "ready" },
            { "id": "s000041_ve7wp2", "segment_count": 0, "total_bytes": 241742398,
              "state": "incomplete", "reason": "session has no publishable segments" } ] }
        """
        struct Response: Decodable {
            let recordings: [Wire]
            struct Wire: Decodable {
                let id: String
                let segmentCount: Int
                let totalBytes: Int64
                let state: String
                let reason: String?
            }
        }
        let response = try JSONDecoder.abundance.decode(Response.self, from: Data(json.utf8))
        XCTAssertEqual(SessionState(response.recordings[0].state), .ready)
        XCTAssertEqual(SessionState(response.recordings[1].state), .incomplete)
        XCTAssertEqual(response.recordings[1].reason, "session has no publishable segments")
    }

    func testStorageBreakdown() throws {
        let json = """
        { "mountpoint": "/mnt/sdcard", "total_bytes": 63860375552, "free_bytes": 41203445760,
          "used_bytes": 22656929792, "unaccounted_bytes": 184549376,
          "entries": [ { "name": "recordings", "bytes": 21903261696, "known": true },
                       { "name": "$RECYCLE.BIN", "bytes": 562036736, "known": false } ],
          "scan_seconds": 0.08, "cached_age_s": 0 }
        """
        let breakdown = try JSONDecoder.abundance.decode(StorageBreakdown.self, from: Data(json.utf8))
        XCTAssertEqual(breakdown.entries.count, 2)
        XCTAssertFalse(breakdown.entries[1].known)
        XCTAssertEqual(breakdown.unaccountedBytes, 184_549_376)
        XCTAssertEqual(breakdown.scanSeconds, 0.08)
        XCTAssertEqual(breakdown.cachedAgeS, 0)
    }

    // MARK: - Station models

    func testWifiScanAndStatus() throws {
        let scan = """
        { "networks": [ { "ssid": "HomeNet", "rssi_dbm": -47, "channel": 36, "band": "5",
                          "security": "wpa2", "saved": true } ], "scanned_uptime_s": 8123.4 }
        """
        let decoded = try JSONDecoder.abundance.decode(WifiScan.self, from: Data(scan.utf8))
        XCTAssertEqual(decoded.networks.first?.rssiDbm, -47)
        XCTAssertEqual(decoded.networks.first?.saved, true)
        XCTAssertEqual(decoded.scannedUptimeS, 8_123.4)
        let wifi = """
        { "saved": ["HomeNet"],
          "station": { "ssid": "HomeNet", "state": "connected", "rssi_dbm": -47,
                       "channel": 36, "has_internet": true },
          "ap": { "ssid": "A4-Abundance-1234", "channel": 36, "width_mhz": 20 } }
        """
        let wifiStatus = try JSONDecoder.abundance.decode(WifiStatus.self, from: Data(wifi.utf8))
        XCTAssertEqual(wifiStatus.saved, ["HomeNet"])
        XCTAssertEqual(wifiStatus.station?.state, "connected")
        XCTAssertEqual(wifiStatus.ap.channel, 36)
        XCTAssertEqual(wifiStatus.ap.ssid, "A4-Abundance-1234")
        XCTAssertEqual(wifiStatus.ap.widthMhz, 20)

        // No uplink: the firmware omits ssid/rssi/channel entirely
        // (api.html StationState: those keys are present when connected).
        let disconnected = """
        { "saved": [],
          "station": { "state": "disconnected" },
          "ap": { "ssid": "A4-Abundance-1234", "channel": 6, "width_mhz": 20 } }
        """
        let idle = try JSONDecoder.abundance.decode(WifiStatus.self, from: Data(disconnected.utf8))
        XCTAssertEqual(idle.station?.state, "disconnected")
        XCTAssertNil(idle.station?.ssid)


        let status = """
        { "enabled": true, "base_url": "https://ingest.example.com/abundance", "state": "uploading",
          "pending_sessions": 3, "pending_bytes": 21903261696,
          "current": { "session_id": "s000042_k3x9qz", "artifact": "s000042_k3x9qz_00003.ts", "percent": 42.5 },
          "last_success_uptime_s": 7420.1, "last_error": null }
        """
        let upload = try JSONDecoder.abundance.decode(UploadStatus.self, from: Data(status.utf8))
        XCTAssertEqual(upload.baseURL?.absoluteString, "https://ingest.example.com/abundance")
        XCTAssertEqual(upload.current?.percent, 42.5)
        XCTAssertNil(upload.lastError)
    }

    func testForgetPercentEncodesSlashInSSID() async throws {
        StationURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.absoluteString, "http://device.test/v1/wifi/Floor%2FLab")
            return (200, Data(#"{"forgotten":true}"#.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StationURLProtocol.self]
        let connection = DeviceConnection(
            baseURL: URL(string: "http://device.test")!,
            token: "token",
            session: URLSession(configuration: configuration)
        )

        try await StationControl(connection: connection).forget(ssid: "Floor/Lab")
    }

    func testUploadTargetEncodesSnakeCase() throws {
        let target = UploadTarget(
            enabled: true,
            baseURL: URL(string: "https://ingest.example.com/abundance")!,
            token: "t"
        )
        let data = try JSONEncoder.abundance.encode(target)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["base_url"] as? String, "https://ingest.example.com/abundance")
        XCTAssertEqual(object["enabled"] as? Bool, true)
    }

    // MARK: - Capabilities

    func testCapabilityRoundtrip() throws {
        let wire = ["metrics", "control", "config", "offload", "teleport"]
        let capabilities = Set(wire.map(Capability.init))
        XCTAssertTrue(capabilities.contains(.metrics))
        XCTAssertTrue(capabilities.contains(.unknown("teleport")))

        let encoded = try JSONEncoder().encode(capabilities.sorted { $0.rawValue < $1.rawValue })
        let decoded = try JSONDecoder().decode([Capability].self, from: encoded)
        XCTAssertEqual(Set(decoded), capabilities)
    }

    func testCredentialsRoundtrip() throws {
        let credentials = AbundanceCredentials(
            deviceID: "7f3c1e2a",
            host: "192.168.42.1",
            sessionToken: "tok",
            tokenExpiresAt: Date(timeIntervalSince1970: 1_787_465_042),
            capabilities: [.metrics, .control]
        )
        let decoded = try JSONDecoder().decode(
            AbundanceCredentials.self,
            from: JSONEncoder().encode(credentials)
        )
        XCTAssertEqual(decoded, credentials)
        XCTAssertEqual(decoded.baseURL.absoluteString, "http://192.168.42.1:8443")
    }
}

private final class StationURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            XCTFail("missing HTTP handler")
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
