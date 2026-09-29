import AVFoundation
import Combine
import Foundation

@MainActor
final class AudioCaptureManager: ObservableObject {
    enum CaptureOwner: Equatable {
        case none, iphoneMode, wearableMode
    }

    enum MicrophonePermission: String {
        case notDetermined
        case granted
        case denied
    }

    @Published private(set) var captureOwner: CaptureOwner = .none
    @Published private(set) var wearableMic = WearableMicState()
    @Published private(set) var isCapturing = false
    @Published private(set) var isStarting = false
    @Published private(set) var rmsDBFS = -100.0
    @Published private(set) var microphonePermission: MicrophonePermission = .notDetermined
    @Published private(set) var errorMessage: String?
    @Published private(set) var inputFormatDescription: String?
    @Published private(set) var aiBufferStatus = AIInputBufferStatus.empty

    private let session = AVAudioSession.sharedInstance()
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var sessionActive = false
    private var captureID: UUID?
    private var hasMeterReading = false
    private var aiProcessor: AIInputProcessor?
    private var aiStatusTask: Task<Void, Never>?
    private var snapshotPending = false
    private var wearablePreferences: WearableAudioPreferences?
    private var wearableEstimator = StereoDirectionEstimator()
    private var wearableRouteSignature: String?
    private var engineObserver: AnyCancellable?
    private var sessionObservers = Set<AnyCancellable>()

    init() {
        refreshPermission()
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      type == AVAudioSession.InterruptionType.began.rawValue else { return }
                self?.stopForSystemEvent("Audio was interrupted. Tap Start Capture to retry.")
            }
            .store(in: &sessionObservers)

        NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.stopForSystemEvent("Audio services were reset. Tap Start Capture to retry.")
            }
            .store(in: &sessionObservers)
    }

    func refreshPermission() {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined: microphonePermission = .notDetermined
        case .granted: microphonePermission = .granted
        case .denied: microphonePermission = .denied
        @unknown default: microphonePermission = .denied
        }
    }

    func startCapture(owner: CaptureOwner = .iphoneMode) async {
        guard owner != .none, !Task.isCancelled, !isCapturing, !isStarting else { return }
        let id = UUID()
        captureID = id
        captureOwner = owner
        isStarting = true
        errorMessage = nil
        defer {
            if captureID == id { isStarting = false }
        }

        refreshPermission()
        if microphonePermission == .notDetermined {
            _ = await AVAudioApplication.requestRecordPermission()
            // Stop/backgrounding may have cancelled this request while the prompt was visible.
            guard captureID == id, captureOwner == owner else { return }
            if Task.isCancelled { stopCapture(owner: owner); return }
            refreshPermission()
        }
        guard microphonePermission == .granted else {
            errorMessage = "Microphone access is denied. Enable it for MEIT in Settings."
            isStarting = false
            captureID = nil
            captureOwner = .none
            return
        }

        do {
            // Preserve the iPhone-mode baseline. Only the wearable preferences transaction
            // temporarily changes mode to default, before creating any engine or tap.
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
            sessionActive = true
            guard session.isInputAvailable else { throw CaptureError.unavailableInput }
            // A failed previous restoration must be resolved before either mode can capture.
            try restoreWearablePreferences()
            if owner == .wearableMode {
                wearableMic = .init()
                wearableEstimator.reset()
                wearablePreferences = WearableAudioPreferences(session: session)
                guard let preferences = wearablePreferences else { throw CaptureError.unavailableInput }
                do { wearableMic.stereoRequest = try preferences.requestStereo(session) }
                catch {
                    // A stereo request failure is not a mono capture failure. Undo partial requests.
                    wearableMic.stereoRequest = .failed
                    wearableMic.configurationNote = "\(preferences.configurationStep): \(error.localizedDescription)"
                    try restoreWearablePreferences()
                }
                wearableMic.availableDataSources = preferences.availableDataSources
                // Wearable mode uses the built-in iPhone microphone, not an external headset.
                guard session.currentRoute.inputs.first?.portType == .builtInMic else {
                    throw CaptureError.unavailableInput
                }
            }

            // A fresh engine per capture avoids carrying a stopped/changed graph into a restart.
            let newEngine = AVAudioEngine()
            engine = newEngine
            let input = newEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate.isFinite, format.sampleRate > 0,
                  format.channelCount > 0, format.commonFormat == .pcmFormatFloat32 else {
                throw CaptureError.unavailableInput
            }

            if owner == .wearableMode {
                let configuration = wearableMic
                wearableMic = .inspect(session, nodeChannels: Int(format.channelCount))
                wearableMic.availableDataSources = configuration.availableDataSources
                wearableMic.stereoRequest = configuration.stereoRequest
                wearableMic.configurationNote = configuration.configurationNote
                wearableRouteSignature = currentWearableRouteSignature()
            }

            let processor = try AIInputProcessor(nativeFormat: format) { [weak self] message in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.captureID == id else { return }
                    self.stopForSystemEvent(message)
                }
            }
            aiProcessor = processor
            // Build the audio callback outside MainActor so it does not inherit UI isolation.
            let measureStereo = owner == .wearableMode && wearableMic.configuredStereo
                && wearableMic.sessionChannels >= 2 && wearableMic.nodeChannels >= 2
            let tap = NativeRMSMeter.makeTap(aiProcessor: processor,
                monitorStereo: owner == .wearableMode, measureStereo: measureStereo) { [weak self] dbFS, stereo in
                // Only scalar readings cross threads, at approximately 10 updates per second.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.captureID == id, self.isCapturing else { return }
                    self.rmsDBFS = self.hasMeterReading
                        ? self.rmsDBFS + 0.25 * (dbFS - self.rmsDBFS)
                        : dbFS
                    self.hasMeterReading = true
                    if self.captureOwner == .wearableMode, let stereo {
                        self.updateWearableReading(stereo)
                    }
                }
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: tap)
            tapInstalled = true
            newEngine.prepare()
            try newEngine.start()
            inputFormatDescription = "\(Int(format.sampleRate)) Hz · \(format.channelCount) channel(s)"
            isCapturing = true
            monitorAIInput(processor, captureID: id)

            engineObserver = NotificationCenter.default.publisher(
                for: .AVAudioEngineConfigurationChange, object: newEngine
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.captureID == id else { return }
                self.stopForSystemEvent("Audio input changed. Tap Start Capture to retry.")
            }
        } catch {
            stopCapture()
            errorMessage = "Unable to start microphone: \(error.localizedDescription)"
        }
    }

    /// Returns the latest full window, oldest to newest, or nil if not ready/stopped/busy.
    /// One in-flight request keeps snapshot allocations and queue submissions bounded.
    func makeAIInputSnapshot() async -> AIInputSnapshot? {
        guard !snapshotPending, isCapturing, let id = captureID, let processor = aiProcessor else { return nil }
        snapshotPending = true
        defer { snapshotPending = false }
        let snapshot = await processor.makeSnapshot()
        guard captureID == id, isCapturing else { return nil }
        return snapshot
    }

    private func monitorAIInput(_ processor: AIInputProcessor, captureID id: UUID) {
        aiStatusTask = Task { [weak self] in
            // Await each small status read: never enqueue an unbounded series of UI updates.
            while !Task.isCancelled {
                let status = await processor.status()
                guard !Task.isCancelled, let self, self.captureID == id else { return }
                self.aiBufferStatus = status
                if self.captureOwner == .wearableMode { self.wearableMic.audioReady = status.isReady }
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
            }
        }
    }

    func stopCapture(owner expectedOwner: CaptureOwner? = nil) {
        // A disappearing old mode can only stop its own capture, never the new mode's engine.
        if let expectedOwner, captureOwner != expectedOwner { return }
        // Invalidate permission completions and queued readings before touching the engine.
        captureID = nil
        captureOwner = .none
        aiStatusTask?.cancel()
        aiStatusTask = nil
        isStarting = false
        isCapturing = false
        engineObserver = nil
        engine?.stop()
        if tapInstalled {
            engine?.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine = nil
        aiProcessor?.stop()
        aiProcessor = nil
        aiBufferStatus = .empty
        rmsDBFS = -100
        hasMeterReading = false
        inputFormatDescription = nil
        wearableMic = .init()
        wearableEstimator.reset()
        wearableRouteSignature = nil

        if sessionActive {
            do { try restoreWearablePreferences() }
            catch { errorMessage = error.localizedDescription }
            do {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
                sessionActive = false
            } catch {
                errorMessage = "Unable to deactivate audio session: \(error.localizedDescription)"
            }
        }
    }

    private func restoreWearablePreferences() throws {
        guard let preferences = wearablePreferences else { return }
        try preferences.restore(session)
        wearablePreferences = nil
    }

    private func currentWearableRouteSignature() -> String {
        let port = session.currentRoute.inputs.first
        let source = port?.selectedDataSource
        return "\(port?.uid ?? "")|\(source?.dataSourceID.stringValue ?? "")|"
            + "\(source?.selectedPolarPattern?.rawValue ?? "")|\(session.inputOrientation.rawValue)|\(session.inputNumberOfChannels)"
    }

    private func updateWearableReading(_ reading: NativeStereoReading) {
        guard captureOwner == .wearableMode else { return }
        guard wearableRouteSignature == currentWearableRouteSignature() else {
            stopForSystemEvent("iPhone microphone input changed. Turn the microphone on again to retry.")
            return
        }
        wearableMic.bufferChannels = reading.channels
        let usable = wearableMic.configuredStereo && wearableMic.sessionChannels >= 2
            && wearableMic.nodeChannels >= 2 && reading.channels >= 2
        wearableMic.stereoUsable = usable
        wearableMic.channel1RMS = usable ? reading.channel1RMS : nil
        wearableMic.channel2RMS = usable ? reading.channel2RMS : nil
        wearableMic.channel1Peak = usable ? reading.channel1Peak : nil
        wearableMic.channel2Peak = usable ? reading.channel2Peak : nil
        wearableMic.channelDominance = StereoChannelDominance(estimate: wearableEstimator.update(
            leftRMS: reading.channel1RMS ?? .nan, rightRMS: reading.channel2RMS ?? .nan,
            stereoUsable: usable))
    }

    private func stopForSystemEvent(_ message: String) {
        guard isCapturing || isStarting else { return }
        stopCapture()
        errorMessage = message
    }

    private enum CaptureError: LocalizedError {
        case unavailableInput

        var errorDescription: String? {
            "No usable Float32 microphone input is available."
        }
    }
}

// Callback-confined state: create once for each tap; never access it from the UI thread.
// RMS remains native-format; AIInputProcessor copies PCM into its bounded conversion pipeline.
private final class NativeRMSMeter {
    private var sumOfSquares = 0.0
    private var sampleCount = 0
    private var frameCount = 0
    private var channel1Power = 0.0
    private var channel2Power = 0.0
    private var channel1Peak = 0.0
    private var channel2Peak = 0.0
    private var stereoFrames = 0
    private var stereoInvalid = false

    static func makeTap(aiProcessor: AIInputProcessor, monitorStereo: Bool, measureStereo: Bool,
                        onReading: @escaping @Sendable (Double, NativeStereoReading?) -> Void) -> AVAudioNodeTapBlock {
        let meter = NativeRMSMeter()
        return { buffer, _ in
            aiProcessor.enqueue(buffer)
            guard let reading = meter.consume(buffer, monitorStereo: monitorStereo, measureStereo: measureStereo) else { return }
            onReading(reading.0, reading.1)
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer, monitorStereo: Bool, measureStereo: Bool) -> (Double, NativeStereoReading?)? {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let sampleRate = buffer.format.sampleRate
        guard frames > 0, channels > 0, sampleRate.isFinite, sampleRate > 0,
              let channelData = buffer.floatChannelData else { return nil }

        // Respect frameLength and stride for both planar and interleaved Float32 PCM.
        // Average channel power, not signed samples (opposite phases must not cancel).
        let stride = buffer.stride
        for channel in 0..<channels {
            let samples = channelData[channel]
            for frame in 0..<frames {
                let sample = Double(samples[frame * stride])
                if sample.isFinite { sumOfSquares += sample * sample }
                if measureStereo && channels >= 2 {
                    if !sample.isFinite { stereoInvalid = true }
                    else if channel == 0 {
                        channel1Power += sample * sample
                        channel1Peak = max(channel1Peak, abs(sample))
                    } else if channel == 1 {
                        channel2Power += sample * sample
                        channel2Peak = max(channel2Peak, abs(sample))
                    }
                }
            }
        }
        if monitorStereo {
            if measureStereo && channels >= 2 { stereoFrames += frames }
            else { stereoInvalid = true }
        }
        sampleCount += frames * channels
        frameCount += frames
        guard Double(frameCount) >= sampleRate * 0.1 else { return nil }

        var stereo: NativeStereoReading?
        if monitorStereo {
            let validStereo = measureStereo && channels >= 2 && stereoFrames > 0 && !stereoInvalid
            stereo = NativeStereoReading(channels: channels,
                channel1RMS: validStereo ? sqrt(channel1Power / Double(stereoFrames)) : nil,
                channel2RMS: validStereo ? sqrt(channel2Power / Double(stereoFrames)) : nil,
                channel1Peak: validStereo ? channel1Peak : nil,
                channel2Peak: validStereo ? channel2Peak : nil)
            channel1Power = 0; channel2Power = 0
            channel1Peak = 0; channel2Peak = 0
            stereoFrames = 0; stereoInvalid = false
        }
        let rms = sqrt(sumOfSquares / Double(sampleCount))
        sumOfSquares = 0
        sampleCount = 0
        frameCount = 0
        // 1e-5 amplitude corresponds to -100 dBFS; never publish NaN or infinity.
        guard rms.isFinite else { return (-100, stereo) }
        return (min(0, max(-100, 20 * log10(max(rms, 0.00001)))), stereo)
    }
}
