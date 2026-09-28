import Combine
import Foundation

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
}

private struct HapticCommand: Decodable {
    let command_id: String
    let kind: String
    let role: DeviceRole
    let expires_in_ms: Double
}

private struct PollResponse: Decodable {
    let command: HapticCommand?
    let direction: DirectionState
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

    private let defaults: UserDefaults
    private weak var network: NetworkManager?
    private weak var audio: AudioCaptureManager?
    private weak var haptics: HapticManager?
    private var generation: UUID?
    private var pollTask: Task<Void, Never>?
    private var rmsTask: Task<Void, Never>?
    private var testTask: Task<Void, Never>?
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
        rmsStatus = "Stopped"
        testingDirection = false
        testResult = nil
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
                }
                let query = [URLQueryItem(name: "device_id", value: deviceID),
                             URLQueryItem(name: "role", value: role.rawValue)]
                let sent = clock.now
                let data = try await network.coordinationRequest(path: "/device/command", query: query)
                guard current(id) else { return }
                let response = try JSONDecoder().decode(PollResponse.self, from: data)
                direction = response.direction
                networkError = nil
                if let command = response.command {
                    let elapsed = sent.duration(to: clock.now).components
                    let elapsedMS = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
                    if command.kind == "direction_haptic", command.role == role,
                       UUID(uuidString: command.command_id) != nil,
                       command.expires_in_ms.isFinite, command.expires_in_ms > elapsedMS,
                       !handledCommands.contains(command.command_id) {
                        // Mark before playing: failures/retries must not replay an old command.
                        handledCommands.append(command.command_id)
                        handledCommands = Array(handledCommands.suffix(32))
                        defaults.set(handledCommands, forKey: "meit.handledCommands")
                        haptics?.play()
                    }
                }
            } catch {
                guard current(id) else { return }
                isRegistered = false
                registration = "Failed / Conflict"
                direction = nil
                networkError = error.localizedDescription
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
                    let body = try JSONEncoder().encode(DeviceMessage(device_id: deviceID, role: role, rms_dbfs: rms))
                    let data = try await network.coordinationRequest(path: "/device/rms", body: body)
                    guard current(id) else { return }
                    struct Ack: Decodable { let status: String }
                    guard try JSONDecoder().decode(Ack.self, from: data).status == "ok" else {
                        throw URLError(.cannotParseResponse)
                    }
                    rmsStatus = "Reporting (~10 Hz)"
                } catch {
                    guard current(id) else { return }
                    rmsStatus = "Report failed: \(error.localizedDescription)"
                }
            } else {
                rmsStatus = isRegistered ? "Capture stopped" : "Waiting for registration"
            }
            // One awaited request at a time; slow sends coalesce subsequent readings.
            do { try await Task.sleep(until: began.advanced(by: .milliseconds(100)), clock: clock) }
            catch { return }
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
