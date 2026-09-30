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
    var captureSession: WearableCaptureSessionState?
    // Trusted only for the original standard Stereo tag with an ASBD channel count of two.
    var stereoSemanticMappingAvailable: Bool {
        capturePCM?.channelLayout.isStandardStereo == true && capturePCM?.channels == bufferChannels
    }
    var estimatorState: WearableDirection = .unavailable
    var smoothedDeltaDB: Double?
    let directionConfiguration = StereoDirectionConfiguration()
    // This is an orientation check, NOT a measured physical channel mapping.
    var portraitOrientationConfirmed: Bool {
        captureSession?.requestedOrientation == "portrait"
            && preferredOrientation == "portrait" && actualOrientation == "portrait"
            && activeMultichannelMode == "stereo" && stereoUsable && bufferChannels >= 2
    }
    // Unsmoothed displayed channel dBFS difference; positive means CH1 has higher level.
    var channelDeltaDB: Double? {
        guard stereoUsable, let channel1RMS, let channel2RMS,
              channel1RMS.isFinite, channel2RMS.isFinite, channel1RMS >= 0, channel2RMS >= 0 else { return nil }
        return StereoDirectionEstimator.dbFS(channel1RMS) - StereoDirectionEstimator.dbFS(channel2RMS)
    }
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
    // Experimental stream-semantic direction for local Wearable UI only.
    // Silence/invalid input resets estimatorState to unavailable before it is published.
    var direction: WearableDirection {
        guard activeMultichannelMode == "stereo", bufferChannels >= 2, stereoUsable,
              stereoSemanticMappingAvailable else { return .unavailable }
        return estimatorState
    }
    var audioReady = false
    var configurationNote: String?
    // Separate physical calibration is still unverified; semantic UI output does not verify motor directions.
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

    static func orientationName(_ value: AVAudioSession.StereoOrientation) -> String {
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
    private let dataSource: AVAudioSessionDataSourceDescription?
    private let patterns: [(AVAudioSessionDataSourceDescription, AVAudioSession.PolarPattern?)]
    private let orientation: AVAudioSession.StereoOrientation
    private let channels: Int
    let savedPreferredOrientation: String
    let savedActualOrientation: String

    init?(session: AVAudioSession) {
        guard let port = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else { return nil }
        category = session.category
        mode = session.mode
        options = session.categoryOptions
        previousInput = session.preferredInput
        dataSource = port.preferredDataSource
        patterns = (port.dataSources ?? []).filter { !($0.supportedPolarPatterns ?? []).isEmpty }
            .map { ($0, $0.preferredPolarPattern) }
        orientation = session.preferredInputOrientation
        savedPreferredOrientation = WearableMicState.orientationName(orientation)
        savedActualOrientation = WearableMicState.orientationName(session.inputOrientation)
        // Zero means unspecified; the setter rejects 0, so preserve the effective baseline count.
        channels = session.preferredInputNumberOfChannels > 0
            ? session.preferredInputNumberOfChannels : max(1, session.inputNumberOfChannels)
    }

    func prepareForCapture(_ session: AVAudioSession) throws {
        try session.setCategory(.record, mode: .default, options: [])
        try session.setActive(true)
        guard let currentPort = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else {
            throw CapturePCMError("Built-in microphone is no longer available.")
        }
        try session.setPreferredInput(currentPort)
        // No polar-pattern stereo/channel request: AVCapture's multichannel API owns that path.
    }

    func restore(_ session: AVAudioSession) -> MicrophoneRestoreReport {
        var report = MicrophoneRestoreReport()
        report.orientationTarget = savedPreferredOrientation
        func attempt(_ field: String, essential: Bool = true, _ action: () throws -> Void) {
            do { try action() }
            catch { report.record(field, error: error, essential: essential) }
        }
        // Restore prerequisites before querying routes or applying route-dependent preferences.
        // AVCapture has fully stopped; automatic configuration is no longer racing these calls.
        attempt("category/mode") { try session.setCategory(category, mode: mode, options: options) }
        attempt("activation") { try session.setActive(true) }
        guard !report.blocksCapture else { return report }
        let inputs = session.availableInputs ?? []
        let restoredInput = previousInput.flatMap { old in inputs.first { $0.uid == old.uid } }
        // A disconnected input cannot be restored; nil releases the override to system routing.
        attempt("input") { try session.setPreferredInput(restoredInput) }
        guard !report.blocksCapture else { return report }
        if let currentPort = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            for (original, pattern) in patterns {
                // Never hand a stale description object back to Core Audio after route changes.
                guard let source = currentPort.dataSources?.first(where: { $0.dataSourceID == original.dataSourceID }) else { continue }
                if let pattern, source.supportedPolarPatterns?.contains(pattern) != true { continue }
                if source.preferredPolarPattern != pattern {
                    attempt("polar pattern") { try source.setPreferredPolarPattern(pattern) }
                }
            }
            let restoredSource = dataSource.flatMap { old in
                currentPort.dataSources?.first { $0.dataSourceID == old.dataSourceID }
            }
            attempt("data source") { try currentPort.setPreferredDataSource(restoredSource) }
        }
        attempt("channel count") {
            try session.setPreferredInputNumberOfChannels(min(channels, max(1, session.maximumInputNumberOfChannels)))
        }
        // .none describes a non-stereo configuration, not an orientation reset command.
        // Orientation has no bearing on the mono measurement baseline. Do not force a stereo
        // preference into that route or let a rejected optional hint poison all future Starts.
        let selected = session.currentRoute.inputs.first
        let stereoRoute = selected?.portType == .builtInMic
            && selected?.selectedDataSource?.selectedPolarPattern == .stereo
        if orientation == .none {
            report.orientationResult = "not applicable: saved none (non-stereo baseline)"
        } else if ![AVAudioSession.StereoOrientation.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight].contains(orientation) {
            report.orientationResult = "not applicable: unknown saved orientation"
        } else if !stereoRoute || report.blocksCapture {
            report.orientationResult = "not applicable: restored route is not configured for stereo"
        } else if session.preferredInputOrientation == orientation {
            report.orientationResult = "already matches saved preference"
        } else {
            attempt("setPreferredInputOrientation", essential: false) {
                try session.setPreferredInputOrientation(orientation)
            }
            report.orientationResult = report.issues.contains { $0.field == "setPreferredInputOrientation" }
                ? "failed (optional preference)" : "applied saved preference"
        }
        report.restoredPreferredOrientation = WearableMicState.orientationName(session.preferredInputOrientation)
        return report
    }
}
