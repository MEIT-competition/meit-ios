import Combine
import Foundation
import UIKit

enum DeviceRole: String, Codable, CaseIterable {
    case front, right, back, left
}

struct DirectionState: Decodable {
    let direction: String
    let reason: String
    let marginDB: Double?
    let missingRoles: [String]
    let staleRoles: [String]
    let conflictRoles: [String]

    enum CodingKeys: String, CodingKey {
        case direction, reason
        case marginDB = "margin_db"
        case missingRoles = "missing_roles"
        case staleRoles = "stale_roles"
        case conflictRoles = "conflict_roles"
    }

    var detail: String {
        if !conflictRoles.isEmpty { return "Role conflict: " + conflictRoles.joined(separator: ", ") }
        if !missingRoles.isEmpty { return "Waiting for " + missingRoles.joined(separator: ", ").uppercased() }
        if !staleRoles.isEmpty { return "Stale RMS: " + staleRoles.joined(separator: ", ").uppercased() }
        return reason.replacingOccurrences(of: "_", with: " ")
    }
}

private struct DeviceMessage: Encodable {
    let device_id: String
    let role: DeviceRole
    var rms_dbfs: Double? = nil
    var ai_buffer_ready: Bool? = nil
}

private struct DeviceCommand: Decodable {
    let command_id: String
    let kind: String
    let role: DeviceRole
    let expires_in_ms: Double
    let event_id: String?
}

private struct PollResponse: Decodable {
    let command: DeviceCommand?
    let auto: AutoDetectionStatus?
    let direction: DirectionState
}

struct AutoDetectionStatus: Decodable {
    struct Latency: Decodable {
        let trigger_to_command_ms: Double?
        let command_to_audio_ms: Double?
        let audio_to_inference_start_ms: Double?
        let inference_ms: Double?
        let total_event_ms: Double?
    }
    struct Event: Decodable {
        let event_id: String
        let source_role: String
        let outcome: String
        let direction: String
        let result: AIInferenceResult?
        let trigger_rms_dbfs: Double?
        let trigger_threshold_dbfs: Double?
        let trigger_reason: String?
        let timestamps_ms: [String: Double]?
        let latency: Latency?
    }
    let trigger_dbfs: Double?
    let release_dbfs: Double?
    let rearm_quiet_ms: Double?
    let quiet_elapsed_ms: Double?
    let cooldown_remaining_ms: Double?
    let waiting_for_quiet: Bool?
    let enabled: Bool
    let state: String
    let armed: Bool
    let active_event: Event?
    let last_event: Event?
}

private struct DirectionTestResponse: Decodable {
    struct Haptic: Decodable {
        let queued: Bool
        let reason: String?
    }
    let direction: DirectionState
    let haptic: Haptic
}

@MainActor
final class DeviceCoordinator: ObservableObject {
    let deviceID: String
    @Published var role: DeviceRole {
        didSet {
            defaults.set(role.rawValue, forKey: "meit.deviceRole")
            if role != oldValue, let network, let audio, let haptics {
                connect(network: network, audio: audio, haptics: haptics)
            }
        }
    }
    @Published private(set) var registration = "Disconnected"
    @Published private(set) var isRegistered = false
    @Published private(set) var direction: DirectionState?
    @Published private(set) var networkError: String?
    @Published private(set) var rmsStatus = "Stopped"
    @Published private(set) var testingDirection = false
    @Published private(set) var testResult: String?
    @Published private(set) var autoStatus: AutoDetectionStatus?
    @Published private(set) var changingAuto = false
    @Published private(set) var sendingAuto = false
    @Published private(set) var autoMessage: String?
    @Published private(set) var pollingStatus = "Stopped"
    @Published private(set) var lastSuccessfulContactUptime: TimeInterval?
    @Published private(set) var lastNetworkError: String?

    private let defaults: UserDefaults
    private weak var network: NetworkManager?
    private weak var audio: AudioCaptureManager?
    private weak var haptics: HapticManager?
    private var generation: UUID?
    private var pollTask: Task<Void, Never>?
    private var rmsTask: Task<Void, Never>?
    private var testTask: Task<Void, Never>?
    private var autoControlTask: Task<Void, Never>?
    private var autoSnapshotTask: Task<Void, Never>?
    private var autoSnapshotID: UUID?
    private var handledCommands: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.string(forKey: "meit.deviceID"), let uuid = UUID(uuidString: stored) {
            deviceID = uuid.uuidString.lowercased()
        } else {
            deviceID = UUID().uuidString.lowercased()
        }
        role = DeviceRole(rawValue: defaults.string(forKey: "meit.deviceRole") ?? "") ?? .front
        handledCommands = Array((defaults.stringArray(forKey: "meit.handledCommands") ?? []).suffix(32))
        defaults.set(deviceID, forKey: "meit.deviceID")
    }

    func connect(network: NetworkManager, audio: AudioCaptureManager, haptics: HapticManager) {
        disconnect()
        self.network = network
        self.audio = audio
        self.haptics = haptics
        let id = UUID()
        generation = id
        registration = "Registering..."
        pollingStatus = "Connecting..."
        pollTask = Task { [weak self] in
            guard let self else { return }
            await pollLoop(id: id)
        }
        rmsTask = Task { [weak self] in
            guard let self else { return }
            await rmsLoop(id: id)
        }
    }

    func disconnect() {
        generation = nil
        cancelAutomaticSnapshot()
        autoControlTask?.cancel()
        autoControlTask = nil
        changingAuto = false
        autoStatus = nil
        autoMessage = nil
        pollTask?.cancel()
        rmsTask?.cancel()
        testTask?.cancel()
        pollTask = nil
        rmsTask = nil
        testTask = nil
        network = nil
        audio = nil
        haptics = nil
        isRegistered = false
        registration = "Disconnected"
        direction = nil
        networkError = nil
        pollingStatus = "Stopped"
        lastSuccessfulContactUptime = nil
        lastNetworkError = nil
        rmsStatus = "Stopped"
        testingDirection = false
        testResult = nil
    }

    private func recordContact() {
        lastSuccessfulContactUptime = ProcessInfo.processInfo.systemUptime
    }

    private func current(_ id: UUID) -> Bool { generation == id && !Task.isCancelled }

    private func pollLoop(id: UUID) async {
        let clock = ContinuousClock()
        while current(id) {
            let began = clock.now
            var delay: Duration = .milliseconds(200)
            do {
                guard let network else { return }
                if !isRegistered {
                    let body = try JSONEncoder().encode(DeviceMessage(device_id: deviceID, role: role))
                    let data = try await network.coordinationRequest(path: "/device/register", body: body)
                    guard current(id) else { return }
                    struct Registration: Decodable { let status: String; let device_id: String; let role: DeviceRole }
                    let ack = try JSONDecoder().decode(Registration.self, from: data)
                    guard ack.status == "registered", ack.device_id == deviceID, ack.role == role else {
                        throw URLError(.cannotParseResponse)
                    }
                    isRegistered = true
                    registration = "Connected"
                    recordContact()
                }
                let query = [URLQueryItem(name: "device_id", value: deviceID),
                             URLQueryItem(name: "role", value: role.rawValue)]
                let sent = clock.now
                let data = try await network.coordinationRequest(path: "/device/command", query: query)
                guard current(id) else { return }
                let response = try JSONDecoder().decode(PollResponse.self, from: data)
                direction = response.direction
                pollingStatus = "Active"
                recordContact()
                autoStatus = response.auto
                if response.auto?.enabled != true { cancelAutomaticSnapshot() }
                networkError = nil
                if let command = response.command {
                    let elapsed = sent.duration(to: clock.now).components
                    let elapsedMS = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
                    if ["direction_haptic", "infer_snapshot"].contains(command.kind), command.role == role,
                       UUID(uuidString: command.command_id) != nil,
                       command.expires_in_ms.isFinite, command.expires_in_ms > elapsedMS,
                       !handledCommands.contains(command.command_id) {
                        // Mark before playing: failures/retries must not replay an old command.
                        handledCommands.append(command.command_id)
                        handledCommands = Array(handledCommands.suffix(32))
                        defaults.set(handledCommands, forKey: "meit.handledCommands")
                        if command.kind == "direction_haptic" {
                            // Manual Phase 4 commands have no event ID and remain independent.
                            if command.event_id == nil || response.auto?.enabled == true { haptics?.play() }
                        } else if response.auto?.enabled == true,
                                  response.auto?.active_event?.event_id == command.event_id {
                            requestAutomaticSnapshot(command, remainingMS: command.expires_in_ms - elapsedMS, generation: id)
                        }
                    }
                }
            } catch {
                guard current(id) else { return }
                isRegistered = false
                registration = "Failed / Conflict"
                cancelAutomaticSnapshot()
                autoStatus = nil
                direction = nil
                networkError = error.localizedDescription
                lastNetworkError = error.localizedDescription
                pollingStatus = "Retrying"
                delay = .seconds(1)
            }
            do { try await Task.sleep(until: began.advanced(by: delay), clock: clock) }
            catch { return }
        }
    }

    private func rmsLoop(id: UUID) async {
        let clock = ContinuousClock()
        while current(id) {
            let began = clock.now
            if isRegistered, let audio, audio.isCapturing, let network {
                do {
                    let rms = audio.rmsDBFS
                    guard rms.isFinite, (-100...0).contains(rms) else {
                        throw NetworkFailure(message: "RMS must be finite and within -100...0 dBFS.")
                    }
                    let body = try JSONEncoder().encode(DeviceMessage(device_id: deviceID, role: role, rms_dbfs: rms,
                        ai_buffer_ready: audio.aiBufferStatus.isReady && !network.isBusy && !sendingAuto))
                    let data = try await network.coordinationRequest(path: "/device/rms", body: body)
                    guard current(id) else { return }
                    struct Ack: Decodable { let status: String }
                    guard try JSONDecoder().decode(Ack.self, from: data).status == "ok" else {
                        throw URLError(.cannotParseResponse)
                    }
                    recordContact()
                    rmsStatus = "Reporting (~10 Hz)"
                } catch {
                    guard current(id) else { return }
                    rmsStatus = "Report failed: \(error.localizedDescription)"
                    lastNetworkError = error.localizedDescription
                }
            } else {
                rmsStatus = isRegistered ? "Capture stopped" : "Waiting for registration"
            }
            // One awaited request at a time; slow sends coalesce subsequent readings.
            do { try await Task.sleep(until: began.advanced(by: .milliseconds(100)), clock: clock) }
            catch { return }
        }
    }

    func cancelAutomaticSnapshot() {
        autoSnapshotID = nil
        autoSnapshotTask?.cancel()
        autoSnapshotTask = nil
        sendingAuto = false
    }

    func setAutomaticDetection(_ enabled: Bool) {
        guard !changingAuto, isRegistered, let network, let id = generation else { return }
        changingAuto = true
        autoMessage = nil
        if !enabled { cancelAutomaticSnapshot() }
        autoControlTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await network.coordinationRequest(
                    path: enabled ? "/auto/start" : "/auto/stop", body: Data("{}".utf8))
                guard current(id) else { return }
                autoStatus = try JSONDecoder().decode(AutoDetectionStatus.self, from: data)
                recordContact()
            } catch {
                guard current(id) else { return }
                autoMessage = error.localizedDescription
                lastNetworkError = error.localizedDescription
            }
            guard current(id) else { return }
            changingAuto = false
            autoControlTask = nil
        }
    }

    private func requestAutomaticSnapshot(_ command: DeviceCommand, remainingMS: Double, generation id: UUID) {
        guard !sendingAuto, let eventID = command.event_id, UUID(uuidString: eventID) != nil,
              UIApplication.shared.applicationState == .active,
              let audio, audio.isCapturing, audio.aiBufferStatus.isReady,
              let network, !network.isBusy else {
            autoMessage = "Auto snapshot unavailable; server will expire the event."
            return
        }
        let operationID = UUID()
        let sourceRole = role
        let clock = ContinuousClock()
        // Bound an untrusted timeout before converting Double to a clock duration.
        let deadline = clock.now.advanced(by: .milliseconds(Int64(min(remainingMS, 60_000))))
        autoSnapshotID = operationID
        sendingAuto = true
        autoMessage = "Sending automatic snapshot..."
        autoSnapshotTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let snapshot = await audio.makeAIInputSnapshot() else {
                    throw NetworkFailure(message: "AI Buffer snapshot unavailable.")
                }
                try Task.checkCancellation()
                guard current(id), autoSnapshotID == operationID, audio.isCapturing,
                      UIApplication.shared.applicationState == .active, clock.now < deadline else {
                    throw CancellationError()
                }
                try await network.sendAutomaticSnapshot(snapshot, eventID: eventID, deviceID: deviceID, role: sourceRole)
                guard current(id), autoSnapshotID == operationID else { return }
                recordContact()
                autoMessage = "Automatic snapshot processed."
            } catch {
                guard current(id), autoSnapshotID == operationID else { return }
                autoMessage = "Auto snapshot: \(error.localizedDescription)"
                if !(error is CancellationError) { lastNetworkError = error.localizedDescription }
            }
            guard current(id), autoSnapshotID == operationID else { return }
            autoSnapshotID = nil
            autoSnapshotTask = nil
            sendingAuto = false
        }
    }

    func testDirectionHaptic() {
        guard !testingDirection, isRegistered, let network, let id = generation else { return }
        testingDirection = true
        testResult = nil
        testTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await network.coordinationRequest(path: "/direction/test-haptic", body: Data("{}".utf8))
                guard current(id) else { return }
                let response = try JSONDecoder().decode(DirectionTestResponse.self, from: data)
                direction = response.direction
                testResult = response.haptic.queued ? "Haptic queued" : (response.haptic.reason ?? "Not queued")
            } catch {
                guard current(id) else { return }
                testResult = error.localizedDescription
            }
            guard current(id) else { return }
            testingDirection = false
            testTask = nil
        }
    }
}
