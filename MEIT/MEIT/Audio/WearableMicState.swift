import AVFoundation
import Foundation

struct NativeStereoReading: Sendable {
    let channels: Int
    let channel1RMS: Double?
    let channel2RMS: Double?
    let channel1Peak: Double?
    let channel2Peak: Double?
}

// Adapt the estimator's legacy logical names to channel dominance, never physical direction.
enum StereoChannelDominance: String, Sendable {
    case channel1Dominant, channel2Dominant, balanced, unavailable

    init(estimate: WearableDirection) {
        switch estimate {
        case .left: self = .channel1Dominant
        case .right: self = .channel2Dominant
        case .center: self = .balanced
        case .unavailable: self = .unavailable
        }
    }

    var localizationKey: String { "wearable.dominance.\(rawValue)" }
}

// Value-only snapshots of every built-in source under the wearable session mode.
struct BuiltInMicDataSource: Identifiable, Sendable {
    let id: Int
    let name: String
    let location: String
    let orientation: String
    let supportedPatterns: String
    let supportsStereo: Bool

    @MainActor
    init(_ source: AVAudioSessionDataSourceDescription) {
        id = source.dataSourceID.intValue
        name = source.dataSourceName
        location = source.location?.rawValue ?? "—"
        orientation = source.orientation?.rawValue ?? "—"
        supportedPatterns = source.supportedPolarPatterns?.map(\.rawValue).joined(separator: ", ") ?? "—"
        supportsStereo = source.supportedPolarPatterns?.contains(.stereo) == true
    }
}

// Immutable snapshots are published by the existing audio owner; metadata for a future laptop transport; no transport or motor command.
struct WearableMicState: Sendable {
    var availableDataSources: [BuiltInMicDataSource] = []
    var activeMultichannelMode = "—"
    var capturePCM: CapturePCMDescription?
    var sessionCategory = "—"
    var sessionMode = "—"
    var preferredChannels = 0
    var inputPort = "—"
    var dataSource = "—"
    var maximumChannels = 0
    var sessionChannels = 0
    var nodeChannels = 0
    var bufferChannels = 0
    var supportedPatterns = "—"
    var selectedPattern = "—"
    var preferredOrientation = "—"
    var actualOrientation = "—"
    var configuredStereo = false
    var stereoUsable = false
    var channel1RMS: Double?
    var channel2RMS: Double?
    var channel1Peak: Double?
    var channel2Peak: Double?
    var channelDominance: StereoChannelDominance = .unavailable
    // No measured channel-to-physical-direction mapping exists yet. Fail closed for UI/future laptop metadata.
    var direction: WearableDirection { .unavailable }
    var audioReady = false
    var configurationNote: String?
    // Physical mapping must be measured on-device. Never emit verified motor directions here.
    let physicalMappingVerified = false

    @MainActor
    static func inspect(_ session: AVAudioSession, nodeChannels: Int) -> Self {
        let port = session.currentRoute.inputs.first
        let source = port?.selectedDataSource
        var state = Self()
        state.availableDataSources = (session.availableInputs?.first(where: { $0.portType == .builtInMic })?.dataSources ?? [])
            .map { BuiltInMicDataSource($0) }
        state.sessionCategory = session.category.rawValue
        state.sessionMode = session.mode.rawValue
        state.preferredChannels = session.preferredInputNumberOfChannels
        // Port type rather than a potentially identifying headset/device name.
        state.inputPort = port?.portType.rawValue ?? "—"
        state.dataSource = source?.dataSourceName ?? "—"
        state.maximumChannels = session.maximumInputNumberOfChannels
        state.sessionChannels = session.inputNumberOfChannels
        state.nodeChannels = nodeChannels
        state.supportedPatterns = source?.supportedPolarPatterns?.map(\.rawValue).joined(separator: ", ") ?? "—"
        state.selectedPattern = source?.selectedPolarPattern?.rawValue ?? "—"
        state.preferredOrientation = orientationName(session.preferredInputOrientation)
        state.actualOrientation = orientationName(session.inputOrientation)
        // Orientation is diagnostic/mapping metadata, not a stereo availability condition.
        state.configuredStereo = port?.portType == .builtInMic
            && source?.supportedPolarPatterns?.contains(.stereo) == true
            && source?.selectedPolarPattern == .stereo
        return state
    }

    private static func orientationName(_ value: AVAudioSession.StereoOrientation) -> String {
        switch value {
        case .none: return "none"
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portrait upside down"
        case .landscapeLeft: return "landscape left"
        case .landscapeRight: return "landscape right"
        @unknown default: return "unknown"
        }
    }
}

// Snapshot the shared session before AVFoundation's automatic recording configuration.
// MainActor only; restore ONLY after the AVCapture backend's stop/drain barrier completes.
@MainActor
final class WearableAudioPreferences {
    private let category: AVAudioSession.Category
    private let mode: AVAudioSession.Mode
    private let options: AVAudioSession.CategoryOptions
    private let previousInput: AVAudioSessionPortDescription?
    private let port: AVAudioSessionPortDescription
    private let dataSource: AVAudioSessionDataSourceDescription?
    private let patterns: [(AVAudioSessionDataSourceDescription, AVAudioSession.PolarPattern?)]
    private let orientation: AVAudioSession.StereoOrientation
    private let channels: Int

    init?(session: AVAudioSession) {
        guard let port = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else { return nil }
        self.port = port
        category = session.category
        mode = session.mode
        options = session.categoryOptions
        previousInput = session.preferredInput
        dataSource = port.preferredDataSource
        patterns = (port.dataSources ?? []).filter { !($0.supportedPolarPatterns ?? []).isEmpty }
            .map { ($0, $0.preferredPolarPattern) }
        orientation = session.preferredInputOrientation
        // Zero means unspecified; the setter rejects 0, so preserve the effective baseline count.
        channels = session.preferredInputNumberOfChannels > 0
            ? session.preferredInputNumberOfChannels : max(1, session.inputNumberOfChannels)
    }

    func prepareForCapture(_ session: AVAudioSession) throws {
        try session.setCategory(.record, mode: .default, options: [])
        try session.setActive(true)
        try session.setPreferredInput(port)
        // No polar-pattern stereo/channel request: AVCapture's multichannel API owns that path.
    }

    func restore(_ session: AVAudioSession) throws {
        var failures: [String] = []
        // The session may have been reconfigured automatically, including category options.
        do { try session.setCategory(.record, mode: .default, options: []) }
        catch { failures.append("restore preparation: \(error.localizedDescription)") }
        let currentPort = session.availableInputs?.first(where: { $0.portType == .builtInMic }) ?? port
        for (original, pattern) in patterns {
            let source = currentPort.dataSources?.first(where: { $0.dataSourceID == original.dataSourceID }) ?? original
            do { try source.setPreferredPolarPattern(pattern) }
            catch { failures.append("polar pattern: \(error.localizedDescription)") }
        }
        do { try currentPort.setPreferredDataSource(dataSource) }
        catch { failures.append("data source: \(error.localizedDescription)") }
        do { try session.setPreferredInputOrientation(orientation) }
        catch { failures.append("orientation: \(error.localizedDescription)") }
        do { try session.setPreferredInput(previousInput) }
        catch { failures.append("input: \(error.localizedDescription)") }
        do { try session.setCategory(category, mode: mode, options: options) }
        catch { failures.append("category/mode: \(error.localizedDescription)") }
        do { try session.setPreferredInputNumberOfChannels(min(channels, max(1, session.maximumInputNumberOfChannels))) }
        catch { failures.append("channel count: \(error.localizedDescription)") }
        // Keep this entire snapshot for retry if even one restoration failed; never start over it.
        if !failures.isEmpty { throw CapturePCMError("Unable to restore microphone preferences: \(failures.joined(separator: "; "))") }
    }
}
