import XCTest
@testable import AbundanceDeviceKit

/// The Station broker contract types, against the reference's example
/// payloads — these must hold on both sides of the exchange.
final class BrokerContractTests: XCTestCase {

    func testSessionAnnouncementDecode() throws {
        let json = """
        {
          "session_id": "s000042_k3x9qz",
          "device_id": "261ed43d-c3b9-4664-94b0-b238534b9020",
          "firmware_version": "1.1.0",
          "utc_accuracy_ns": 2213000,
          "absolute_uvc_latency_calibrated": true,
          "imu_time_offset_ns": -5400000,
          "video_bitrate_mbps": 16,
          "recovered": false,
          "dropped_segment_indices": [],
          "segments": [
            { "index": 0,
              "video":  { "name": "s000042_k3x9qz_00000.ts", "bytes": 241594368, "sha256": "3b7f" },
              "imu":    { "name": "s000042_k3x9qz_00000.csv", "bytes": 3962144, "sha256": "9d4c" },
              "frames": { "name": "s000042_k3x9qz_00000_frames.csv", "bytes": 148262, "sha256": "5e2d" } }
          ],
          "logs": [ { "name": "clock-model.json", "bytes": 1147, "sha256": "a1b2" } ]
        }
        """
        let announce = try AbundanceBroker.jsonDecoder.decode(
            AbundanceBroker.SessionAnnouncement.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(announce.sessionID, "s000042_k3x9qz")
        XCTAssertEqual(announce.firmwareVersion, "1.1.0")
        XCTAssertEqual(announce.videoBitrateMbps, 16)
        XCTAssertEqual(announce.utcAccuracyNanoseconds, 2_213_000)
        // Announce artifacts use `bytes`, not the manifest's `size_bytes`.
        XCTAssertEqual(announce.segments[0].video.bytes, 241_594_368)
        XCTAssertEqual(announce.logs[0].name, "clock-model.json")
        XCTAssertEqual(announce.segments[0].video.contentType, "video/mp2t")
        XCTAssertEqual(announce.segments[0].imu.contentType, "text/csv")
        XCTAssertEqual(announce.logs[0].contentType, "application/json")
    }

    func testUploadPlanEncodesWireKeys() throws {
        let plan = AbundanceBroker.UploadPlan(
            uploads: [
                AbundanceBroker.ArtifactDestination(
                    name: "s000042_k3x9qz_00000.ts",
                    url: URL(string: "https://bucket.s3.amazonaws.com/x?sig=1")!,
                    headers: ["Content-Type": "video/mp2t"]
                )
            ],
            completeURL: URL(string: "https://ingest.example.com/abundance/sessions/s000042_k3x9qz/complete")!,
            expiresAt: Date(timeIntervalSince1970: 1_784_880_000)
        )
        let data = try AbundanceBroker.jsonEncoder.encode(plan)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["complete_url"])
        XCTAssertEqual(object["expires_at"] as? Double, 1_784_880_000)
        let uploads = try XCTUnwrap(object["uploads"] as? [[String: Any]])
        XCTAssertEqual(uploads[0]["method"] as? String, "PUT")
    }

    func testCompletionRoundtrip() throws {
        let json = """
        { "session_id": "s000042_k3x9qz",
          "uploaded": [ { "name": "s000042_k3x9qz_00000.ts", "sha256": "3b7f" } ] }
        """
        let report = try AbundanceBroker.jsonDecoder.decode(
            AbundanceBroker.CompletionReport.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(report.sessionID, "s000042_k3x9qz")
        XCTAssertEqual(report.uploaded[0].sha256, "3b7f")

        let response = try AbundanceBroker.jsonEncoder.encode(AbundanceBroker.CompletionResponse(confirmed: true))
        XCTAssertEqual(String(data: response, encoding: .utf8), #"{"confirmed":true}"#)
    }
}
