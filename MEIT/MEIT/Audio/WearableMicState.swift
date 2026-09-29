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

// Immutable snapshots are published by the existing audio owner; metadata for a future laptop transport; no transport or motor command.
struct WearableMicState: Sendable {
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

// Only touches preferences while the session is active and the engine/tap are not running.
// Retain failed restoration work so a later start cannot silently inherit wearable capture settings.
@MainActor
final class WearableAudioPreferences {
    private let previousInput: AVAudioSessionPortDescription?
    private let port: AVAudioSessionPortDescription
    private let previousDataSource: AVAudioSessionDataSourceDescription?
    private let source: AVAudioSessionDataSourceDescription?
    private let previousPattern: AVAudioSession.PolarPattern?
    private let previousOrientation: AVAudioSession.StereoOrientation
    private let previousChannels: Int
    private var inputChanged = false
    private var sourceChanged = false
    private var patternChanged = false
    private var orientationChanged = false
    private var channelsChanged = false

    init?(session: AVAudioSession) {
        guard let port = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else { return nil }
        self.port = port
        previousInput = session.preferredInput
        previousDataSource = port.preferredDataSource
        let candidates = port.dataSources?.filter { $0.supportedPolarPatterns?.contains(.stereo) == true } ?? []
        // A deterministic logical orientation; physical L/R still needs the user's clap tests.
        let selectedSource = candidates.first(where: { $0.orientation == .front }) ?? candidates.first
        source = selectedSource
        previousPattern = selectedSource?.preferredPolarPattern ?? selectedSource?.selectedPolarPattern
        previousOrientation = session.preferredInputOrientation
        // The API rejects 0. Preserve the effective baseline if no positive preference was set.
        previousChannels = session.preferredInputNumberOfChannels > 0
            ? session.preferredInputNumberOfChannels : max(1, session.inputNumberOfChannels)
    }

    func requestStereo(_ session: AVAudioSession) throws {
        if session.preferredInput?.uid != port.uid {
            try session.setPreferredInput(port)
            inputChanged = true
        }
        guard let source else { return } // Supported mono path, not a capture failure.
        if source.selectedPolarPattern != .stereo {
            try source.setPreferredPolarPattern(.stereo)
            patternChanged = true
        }
        if port.selectedDataSource?.dataSourceID != source.dataSourceID {
            try port.setPreferredDataSource(source)
            sourceChanged = true
        }
        if session.preferredInputOrientation != .portrait {
            try session.setPreferredInputOrientation(.portrait)
            orientationChanged = true
        }
        if session.maximumInputNumberOfChannels >= 2, session.preferredInputNumberOfChannels != 2 {
            try session.setPreferredInputNumberOfChannels(2)
            channelsChanged = true
        }
    }

    func restore(_ session: AVAudioSession) throws {
        // Attempt every changed property; one failed call must not skip the other restorations.
        var failures: [String] = []
        if orientationChanged {
            do { try session.setPreferredInputOrientation(previousOrientation); orientationChanged = false }
            catch { failures.append("orientation: \(error.localizedDescription)") }
        }
        if patternChanged, let source {
            do { try source.setPreferredPolarPattern(previousPattern); patternChanged = false }
            catch { failures.append("polar pattern: \(error.localizedDescription)") }
        }
        if sourceChanged {
            do { try port.setPreferredDataSource(previousDataSource); sourceChanged = false }
            catch { failures.append("data source: \(error.localizedDescription)") }
        }
        if inputChanged {
            do { try session.setPreferredInput(previousInput); inputChanged = false }
            catch { failures.append("input: \(error.localizedDescription)") }
        }
        // Restore the channel preference after returning to the original input route.
        if channelsChanged && !inputChanged {
            do {
                // Route loss can reduce the maximum. A valid channel count on the new route is safe.
                try session.setPreferredInputNumberOfChannels(min(previousChannels, max(1, session.maximumInputNumberOfChannels)))
                channelsChanged = false
            } catch { failures.append("channel count: \(error.localizedDescription)") }
        }
        if !failures.isEmpty {
            throw PreferenceRestoreError(details: failures.joined(separator: "; "))
        }
    }

    private struct PreferenceRestoreError: LocalizedError {
        let details: String
        var errorDescription: String? { "Unable to restore microphone preferences: \(details)" }
    }
}
