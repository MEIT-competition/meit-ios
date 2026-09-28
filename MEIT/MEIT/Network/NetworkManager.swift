import Combine
import Foundation

struct AIInferenceResult: Decodable {
    let label: String
    let confidence: Double
    let inferenceMilliseconds: Double
    let direction: String?
    let directionMarginDB: Double?

    enum CodingKeys: String, CodingKey {
        case label, confidence
        case inferenceMilliseconds = "inference_ms"
        case direction
        case directionMarginDB = "direction_margin_db"
    }
}

private struct BridgeErrorResponse: Decodable {
    struct Detail: Decodable { let code: String; let message: String }
    let error: Detail
}

struct NetworkFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// A redirect must never move a microphone snapshot to a different endpoint.
private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class NetworkManager: ObservableObject {
    @Published var serverAddress = "" {
        didSet {
            if serverAddress != oldValue {
                cancel()
                connectionStatus = "Not Tested"
                errorMessage = nil
            }
        }
    }
    @Published private(set) var connectionStatus = "Not Tested"
    @Published private(set) var isBusy = false
    @Published private(set) var isSending = false
    @Published private(set) var result: AIInferenceResult?
    @Published private(set) var errorMessage: String?

    private var operation: Task<Void, Never>?
    private var operationID: UUID?
    private let session = NetworkManager.makeSession(resourceTimeout: 60)
    private let coordinationSession = NetworkManager.makeSession(resourceTimeout: 1)

    nonisolated private static func makeSession(resourceTimeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = resourceTimeout > 1
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = resourceTimeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        return URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
    }

    // Separate from the manual operation: RMS/polls must keep running during inference.
    func coordinationRequest(path: String, body: Data? = nil,
                             query: [URLQueryItem] = []) async throws -> Data {
        try await request(path: path, body: body, query: query, coordination: true)
    }

    // Caller owns one cancellable auto task; manual UI state remains independent.
    func sendAutomaticSnapshot(_ snapshot: AIInputSnapshot, eventID: String,
                               deviceID: String, role: DeviceRole) async throws {
        guard snapshot.sampleRate == 16_000, snapshot.channels == 1,
              snapshot.sampleCount == 40_000, snapshot.byteCount == 80_000,
              snapshot.duration == 2.5 else {
            throw NetworkFailure(message: "Snapshot must be 16000 Hz / mono / PCM16LE / 2.500 s.")
        }
        _ = try await request(path: "/event/audio", body: snapshot.pcm16LittleEndian,
                              headers: ["X-Event-ID": eventID, "X-Device-ID": deviceID,
                                        "X-Device-Role": role.rawValue])
        // The central result is published to every phone through command polling.
    }

    func testConnection() {
        run(sending: false) { [self] in
            let data = try await request(path: "/health")
            try Task.checkCancellation()
            struct Health: Decodable { let status: String }
            guard let health = try? JSONDecoder().decode(Health.self, from: data),
                  health.status == "ok" else {
                throw NetworkFailure(message: "Malformed /health response.")
            }
            connectionStatus = "Connected"
        }
    }

    func sendSnapshot(from audio: AudioCaptureManager) {
        run(sending: true) { [self] in
            guard audio.isCapturing, audio.aiBufferStatus.isReady,
                  let snapshot = await audio.makeAIInputSnapshot() else {
                throw NetworkFailure(message: "AI Buffer is not ready. Wait for a full snapshot.")
            }
            try Task.checkCancellation()
            guard snapshot.sampleRate == 16_000, snapshot.channels == 1,
                  snapshot.sampleCount == 40_000, snapshot.byteCount == 80_000,
                  snapshot.duration == 2.5 else {
                throw NetworkFailure(message: "Snapshot must be 16000 Hz / mono / PCM16LE / 2.500 s.")
            }
            let data = try await request(path: "/infer", body: snapshot.pcm16LittleEndian)
            try Task.checkCancellation()
            guard let response = try? JSONDecoder().decode(AIInferenceResult.self, from: data),
                  ["horn", "siren", "crash", "normal"].contains(response.label),
                  response.confidence.isFinite, (0...1).contains(response.confidence),
                  response.inferenceMilliseconds.isFinite, response.inferenceMilliseconds >= 0 else {
                throw NetworkFailure(message: "Malformed inference response.")
            }
            result = response
            connectionStatus = "Connected"
        }
    }

    func cancel() {
        operationID = nil
        operation?.cancel()
        operation = nil
        isBusy = false
        isSending = false
        result = nil
    }

    private func run(sending: Bool, action: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        let id = UUID()
        operationID = id
        isBusy = true
        isSending = sending
        errorMessage = nil
        if sending { result = nil }
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try await action()
            } catch {
                guard operationID == id, !Task.isCancelled else { return }
                connectionStatus = "Failed"
                if let urlError = error as? URLError {
                    switch urlError.code {
                    case .timedOut:
                        errorMessage = "Request timed out. Check bridge, Wi-Fi and local-network permission."
                    case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                        errorMessage = "Cannot reach bridge. Check Windows IPv4, port 8765, Wi-Fi and firewall."
                    default:
                        errorMessage = urlError.localizedDescription
                    }
                } else {
                    errorMessage = error.localizedDescription
                }
            }
            guard operationID == id else { return }
            operationID = nil
            operation = nil
            isBusy = false
            isSending = false
        }
    }

    private func endpoint(path: String, query: [URLQueryItem]) throws -> URL {
        let parts = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { UInt8($0) }
        guard parts.count == 4, octets.count == 4,
              octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168) else {
            throw NetworkFailure(message: "Enter the Windows private IPv4 address only (no http:// or port).")
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = octets.map { String($0) }.joined(separator: ".")
        components.port = 8765
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw NetworkFailure(message: "Invalid server address.")
        }
        return url
    }

    private func request(path: String, body: Data? = nil, query: [URLQueryItem] = [],
                         coordination: Bool = false, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: try endpoint(path: path, query: query))
        request.timeoutInterval = coordination ? 1 : (body == nil ? 10 : 60)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue(coordination ? "application/json" : "application/octet-stream", forHTTPHeaderField: "Content-Type")
            if !coordination {
                request.setValue("16000", forHTTPHeaderField: "X-Audio-Sample-Rate")
                request.setValue("1", forHTTPHeaderField: "X-Audio-Channels")
                request.setValue("pcm16le", forHTTPHeaderField: "X-Audio-Format")
                request.setValue("40000", forHTTPHeaderField: "X-Audio-Samples")
            }
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let transport = coordination ? coordinationSession : session
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, data.count <= 16_384,
              http.mimeType == "application/json" else {
            throw NetworkFailure(message: "Expected a small JSON response from the MEIT bridge.")
        }
        guard http.statusCode == 200 else {
            if let failure = try? JSONDecoder().decode(BridgeErrorResponse.self, from: data) {
                throw NetworkFailure(message: "HTTP \(http.statusCode) [\(failure.error.code)]: \(failure.error.message)")
            }
            throw NetworkFailure(message: "Bridge returned HTTP \(http.statusCode).")
        }
        return data
    }
}
