import AVFoundation
import Combine
import Foundation

@MainActor
final class AudioCaptureManager: ObservableObject {
    enum MicrophonePermission: String {
        case notDetermined
        case granted
        case denied
    }

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

    func startCapture() async {
        guard !isCapturing, !isStarting else { return }
        let id = UUID()
        captureID = id
        isStarting = true
        errorMessage = nil
        defer {
            if captureID == id { isStarting = false }
        }

        refreshPermission()
        if microphonePermission == .notDetermined {
            _ = await AVAudioApplication.requestRecordPermission()
            // Stop/backgrounding may have cancelled this request while the prompt was visible.
            guard captureID == id else { return }
            refreshPermission()
        }
        guard microphonePermission == .granted else {
            errorMessage = "Microphone access is denied. Enable it for MEIT in Settings."
            isStarting = false
            captureID = nil
            return
        }

        do {
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
            sessionActive = true
            guard session.isInputAvailable else { throw CaptureError.unavailableInput }

            // A fresh engine per capture avoids carrying a stopped/changed graph into a restart.
            let newEngine = AVAudioEngine()
            engine = newEngine
            let input = newEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate.isFinite, format.sampleRate > 0,
                  format.channelCount > 0, format.commonFormat == .pcmFormatFloat32 else {
                throw CaptureError.unavailableInput
            }

            let processor = try AIInputProcessor(nativeFormat: format) { [weak self] message in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.captureID == id else { return }
                    self.stopForSystemEvent(message)
                }
            }
            aiProcessor = processor
            // Build the audio callback outside MainActor so it does not inherit UI isolation.
            let tap = NativeRMSMeter.makeTap(aiProcessor: processor) { [weak self] dbFS in
                // Only a scalar crosses threads, at approximately 10 updates per second.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.captureID == id, self.isCapturing else { return }
                    self.rmsDBFS = self.hasMeterReading
                        ? self.rmsDBFS + 0.25 * (dbFS - self.rmsDBFS)
                        : dbFS
                    self.hasMeterReading = true
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
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
            }
        }
    }

    func stopCapture() {
        // Invalidate permission completions and queued readings before touching the engine.
        captureID = nil
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

        if sessionActive {
            do {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
                sessionActive = false
            } catch {
                errorMessage = "Unable to deactivate audio session: \(error.localizedDescription)"
            }
        }
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

    static func makeTap(aiProcessor: AIInputProcessor,
                        onReading: @escaping @Sendable (Double) -> Void) -> AVAudioNodeTapBlock {
        let meter = NativeRMSMeter()
        return { buffer, _ in
            aiProcessor.enqueue(buffer)
            guard let dbFS = meter.consume(buffer) else { return }
            onReading(dbFS)
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer) -> Double? {
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
            }
        }
        sampleCount += frames * channels
        frameCount += frames
        guard Double(frameCount) >= sampleRate * 0.1 else { return nil }

        let rms = sqrt(sumOfSquares / Double(sampleCount))
        sumOfSquares = 0
        sampleCount = 0
        frameCount = 0
        // 1e-5 amplitude corresponds to -100 dBFS; never publish NaN or infinity.
        guard rms.isFinite else { return -100 }
        return min(0, max(-100, 20 * log10(max(rms, 0.00001))))
    }
}
