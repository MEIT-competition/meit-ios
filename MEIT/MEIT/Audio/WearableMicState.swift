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

enum WearableStereoRequest: String, Sendable {
    case notRequested, noStereoSource, requested, channelsUnavailable, failed
    var localizationKey: String { "wearable.stereoRequest.\(rawValue)" }
}

// Immutable snapshots are published by the existing audio owner; metadata for a future laptop transport; no transport or motor command.
struct WearableMicState: Sendable {
    var availableDataSources: [BuiltInMicDataSource] = []
    var stereoRequest: WearableStereoRequest = .notRequested
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

// Only touches preferences while the session is active and the engine/tap are not running.
// Retain failed restoration work so a later start cannot silently inherit wearable capture settings.
@MainActor
final class WearableAudioPreferences {
    private let previousInput: AVAudioSessionPortDescription?
    private var port: AVAudioSessionPortDescription
    private let previousMode: AVAudioSession.Mode
    private var modeChanged = false
    private(set) var availableDataSources: [BuiltInMicDataSource] = []
    private(set) var configurationStep = "session mode"
    private let previousDataSource: AVAudioSessionDataSourceDescription?
    private var source: AVAudioSessionDataSourceDescription?
    private var previousPattern: AVAudioSession.PolarPattern?
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
        previousMode = session.mode
        previousOrientation = session.preferredInputOrientation
        // The API rejects 0. Preserve the effective baseline if no positive preference was set.
        previousChannels = session.preferredInputNumberOfChannels > 0
            ? session.preferredInputNumberOfChannels : max(1, session.inputNumberOfChannels)
    }

    func requestStereo(_ session: AVAudioSession) throws -> WearableStereoRequest {
        // Wearable owner only. Measurement selects the primary mic; enumerate again in default mode.
        // Apple: activate before availableInputs/input selection and channel-count requests.
        // https://developer.apple.com/library/archive/qa/qa1799/_index.html
        if session.mode != .default {
            modeChanged = true
            try session.setMode(.default)
        }
        configurationStep = "activate default-mode session"
        try session.setActive(true)
        configurationStep = "enumerate built-in microphone sources"
        guard let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else {
            throw StereoConfigurationError(details: "No built-in microphone input is available.")
        }
        port = builtIn
        let sources = port.dataSources ?? []
        availableDataSources = sources.map { BuiltInMicDataSource($0) }
        let candidates = sources.filter { $0.supportedPolarPatterns?.contains(.stereo) == true }
        // Keep the existing front-first choice; never infer physical channel mapping from it.
        source = candidates.first(where: { $0.orientation == .front }) ?? candidates.first
        previousPattern = source?.preferredPolarPattern

        configurationStep = "preferred built-in input"
        if session.preferredInput?.uid != port.uid {
            inputChanged = true
            try session.setPreferredInput(port)
        }
        guard let source else { return .noStereoSource } // Keep real mono capture / AI PCM working.

        // Apple's stereo sample sets the source's pattern before selecting that source on the port.
        // https://developer.apple.com/documentation/avfaudio/capturing-stereo-audio-from-built-in-microphones
        configurationStep = "preferred stereo polar pattern"
        if source.preferredPolarPattern != .stereo {
            patternChanged = true
            try source.setPreferredPolarPattern(.stereo)
        }
        configurationStep = "preferred stereo data source"
        if port.preferredDataSource?.dataSourceID != source.dataSourceID {
            sourceChanged = true
            try port.setPreferredDataSource(source)
        }
        configurationStep = "preferred portrait input orientation"
        if session.preferredInputOrientation != .portrait {
            orientationChanged = true
            try session.setPreferredInputOrientation(.portrait)
        }
        // Query capacity only after the stereo source is applied to the active route.
        configurationStep = "activate configured stereo source"
        try session.setActive(true)
        guard session.maximumInputNumberOfChannels >= 2 else { return .channelsUnavailable }
        configurationStep = "preferred input channels = 2"
        if session.preferredInputNumberOfChannels != 2 {
            channelsChanged = true
            try session.setPreferredInputNumberOfChannels(2)
        }
        // This records a request, not success. Session/node/buffer counts decide stereoUsable.
        return .requested
    }

    func restore(_ session: AVAudioSession) throws {
        // Attempt every changed property; one failed call must not skip the other restorations.
        var failures: [String] = []
        // A retry may begin in measurement mode. Restore stereo preferences in their valid mode.
        if modeChanged && session.mode != .default { try session.setMode(.default) }
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
        // Restore the baseline mode last; retain the snapshot if any earlier restoration failed.
        if failures.isEmpty && modeChanged {
            do { try session.setMode(previousMode); modeChanged = false }
            catch { failures.append("session mode: \(error.localizedDescription)") }
        }
        if !failures.isEmpty {
            throw PreferenceRestoreError(details: failures.joined(separator: "; "))
        }
    }

    private struct StereoConfigurationError: LocalizedError {
        let details: String
        var errorDescription: String? { details }
    }

    private struct PreferenceRestoreError: LocalizedError {
        let details: String
        var errorDescription: String? { "Unable to restore microphone preferences: \(details)" }
    }
}
