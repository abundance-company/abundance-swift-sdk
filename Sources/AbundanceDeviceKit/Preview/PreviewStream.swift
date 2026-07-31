import Foundation

/// The live viewfinder (`GET /v1/preview`): one long response of raw H.264
/// NAL units, decoded and drawn as they arrive. Requires `control`.
///
/// Opening the stream while idle starts a preview-only pipeline that writes
/// nothing to the card; closing the last stream stops it. It survives a
/// recording starting or stopping underneath, with a 1–2 s stall before
/// frames resume at the next SPS/PPS+IDR.
public struct PreviewStream: Sendable {
    private let connection: DeviceConnection

    init(connection: DeviceConnection) {
        self.connection = connection
    }

    /// Raw NAL unit payloads, wire framing removed. One HTTP connection per
    /// call; the consumer owns reconnect. Finishes cleanly when the device
    /// ends the stream; throws `AbundanceError` — `.previewProtocolViolation` is the
    /// one not to retry.
    public func nalUnits() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let connection = connection
            let task = Task {
                do {
                    let config = URLSessionConfiguration.ephemeral
                    // Idle-data timeout (resets on every byte): must outlive
                    // the 1–2 s pipeline-restart stall around recording
                    // start/stop.
                    config.timeoutIntervalForRequest = 15
                    config.requestCachePolicy = .reloadIgnoringLocalCacheData
                    config.urlCache = nil
                    config.networkServiceType = .video
                    config.waitsForConnectivity = false
                    let session = URLSession(configuration: config)
                    defer { session.invalidateAndCancel() }

                    var request = URLRequest(url: connection.url(for: "/v1/preview"))
                    request.setValue(
                        "application/vnd.abundance.h264-preview.v1",
                        forHTTPHeaderField: "Accept"
                    )
                    if let token = await connection.bearerToken() {
                        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                    }

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw AbundanceError.transport("non-HTTP response")
                    }
                    guard http.statusCode == 200 else {
                        // Device error envelope (bounded read), e.g. 412
                        // camera_absent.
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count >= 4096 { break }
                        }
                        throw DeviceConnection.error(status: http.statusCode, body: body)
                    }

                    var reader = NALUnitReader(bytes)
                    try await reader.readHeader()
                    while !Task.isCancelled, let nal = try await reader.nextNALUnit() {
                        continuation.yield(nal)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: PreviewStream.mapped(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func mapped(_ error: Error) -> AbundanceError {
        switch error {
        case let mapped as AbundanceError:
            return mapped
        case let wire as PreviewStreamError:
            return wire.isProtocolViolation
                ? .previewProtocolViolation(wire)
                : .transport(String(describing: wire))
        default:
            return .transport(error.localizedDescription)
        }
    }
}
