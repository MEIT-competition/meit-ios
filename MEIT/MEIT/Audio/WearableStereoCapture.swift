import AVFoundation
import CoreMedia
import Foundation

// Values read after startRunning; separate from the disconnected capability probe.
struct WearableCaptureSessionState: Sendable {
    let activeMode: String
    let requestedOrientation: String
    let preferredOrientation: String
    let actualOrientation: String
    let usesAppAudioSession: Bool
    let autoConfiguresAudioSession: Bool
}

// MainActor owns this helper's lifetime. Session, delivery and PCM worker queues own disjoint state.
// @unchecked Sendable is this confinement contract, not permission for arbitrary shared mutation.
final class WearableStereoCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let sessionQueue = DispatchQueue(label: "org.meit.wearable-session", qos: .userInitiated)
    private let deliveryQueue = DispatchQueue(label: "org.meit.wearable-delivery", qos: .userInitiated)
    private let worker = DispatchQueue(label: "org.meit.wearable-pcm", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: 4)
    private let cancellationLock = NSLock()
    private var startCancelled = false // cancellationLock only; avoids starting queued work after Stop.
    private let onPrepared: @Sendable (CapturePCMDescription, AIInputProcessor) -> Void
    private let onReading: @Sendable (Double, NativeStereoReading) -> Void
    private let onFailure: @Sendable (String) -> Void
    // sessionQueue only.
    private var drainingProcessor: AIInputProcessor?
    private var session: AVCaptureSession?
    private var input: AVCaptureDeviceInput?
    private var output: AVCaptureAudioDataOutput?
    private var observers: [NSObjectProtocol] = []
    // deliveryQueue only.
    private var accepting = false
    // worker only.
    private var stopped = false
    private var failed = false
    private var adapter: CapturePCMAdapter?
    private var processor: AIInputProcessor?
    private var meter: NativeRMSMeter?

    init(onPrepared: @escaping @Sendable (CapturePCMDescription, AIInputProcessor) -> Void,
         onReading: @escaping @Sendable (Double, NativeStereoReading) -> Void,
         onFailure: @escaping @Sendable (String) -> Void) {
        self.onPrepared = onPrepared
        self.onReading = onReading
        self.onFailure = onFailure
        super.init()
    }

    func invalidatePendingStart() {
        cancellationLock.lock()
        startCancelled = true
        cancellationLock.unlock()
    }

    private func checkStartCancellation() throws {
        cancellationLock.lock()
        let cancelled = startCancelled
        cancellationLock.unlock()
        if cancelled { throw CancellationError() }
    }

    func start() async throws -> WearableCaptureSessionState {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [self] in
                do { continuation.resume(returning: try configureAndStart()) }
                catch { cleanup(); continuation.resume(throwing: error) }
            }
        }
    }

    // Completion is a barrier: no running session or queued PCM producer work remains.
    func stop() async {
        invalidatePendingStart()
        let draining: AIInputProcessor? = await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                cleanup()
                continuation.resume(returning: drainingProcessor)
            }
        }
        // stop() enqueues converter/ring cleanup. The existing status read is a FIFO barrier
        // on that same AI worker: no new queue or converter, and no delay/retry workaround.
        if let draining { _ = await draining.status() }
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                drainingProcessor = nil
                continuation.resume()
            }
        }
    }

    private func configureAndStart() throws -> WearableCaptureSessionState {
        try checkStartCancellation()
        guard #available(iOS 18.0, *) else { throw CapturePCMError("Wearable stereo capture requires iOS 18 or later.") }
        guard let device = AVCaptureDevice.default(.microphone, for: .audio, position: .unspecified) else {
            throw CapturePCMError("No AVCapture audio input is available.")
        }
        let capture = AVCaptureSession()
        session = capture
        capture.usesApplicationAudioSession = true
        // Let AVFoundation select the recording configuration needed by multichannel capture.
        // AudioCaptureManager snapshots/restores the shared session around this backend.
        capture.automaticallyConfiguresApplicationAudioSession = true
        let deviceInput = try AVCaptureDeviceInput(device: device)
        guard deviceInput.isMultichannelAudioModeSupported(.stereo) else {
            throw CapturePCMError("This AVCapture input does not support stereo mode.")
        }
        deviceInput.multichannelAudioMode = .stereo
        guard deviceInput.multichannelAudioMode == .stereo else {
            throw CapturePCMError("AVCapture did not accept stereo mode.")
        }
        let audioOutput = AVCaptureAudioDataOutput()
        // Do not set audioSettings (macOS-only). Inspect the actual native sample buffers on iOS.
        capture.beginConfiguration()
        guard capture.canAddInput(deviceInput) else {
            capture.commitConfiguration()
            throw CapturePCMError("Unable to add the AVCapture stereo input.")
        }
        capture.addInput(deviceInput)
        input = deviceInput
        guard capture.canAddOutput(audioOutput) else {
            capture.commitConfiguration()
            throw CapturePCMError("Unable to add the AVCapture PCM output.")
        }
        capture.addOutput(audioOutput)
        output = audioOutput
        audioOutput.setSampleBufferDelegate(self, queue: deliveryQueue)
        capture.commitConfiguration()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVCaptureSessionRuntimeError, object: capture, queue: nil) { [weak self] note in
            let message = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "Unknown runtime error."
            self?.reportFailure("AVCapture runtime error: \(message)")
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: capture, queue: nil) { [weak self] _ in
            self?.reportFailure("Wearable capture was interrupted. Tap Start to retry.")
        })
        try checkStartCancellation()
        // Apply AFTER input/output configuration is committed, BEFORE any recording starts.
        // Auto-configuration may still change preferences at startRunning: verify afterward,
        // never repair orientation during recording or disable the proven stereo configuration.
        let audioSession = AVAudioSession.sharedInstance()
        let requestedOrientation: AVAudioSession.StereoOrientation = .portrait
        try audioSession.setPreferredInputOrientation(requestedOrientation)
        try checkStartCancellation()
        deliveryQueue.sync { accepting = true }
        capture.startRunning() // Blocking API stays off MainActor and outside configuration brackets.
        guard capture.isRunning else { throw CapturePCMError("AVCaptureSession did not start.") }
        worker.asyncAfter(deadline: .now() + 5) { [self] in
            if adapter == nil { fail("AVCapture produced no usable PCM within 5 seconds. Restart capture.") }
        }
        guard deviceInput.multichannelAudioMode == .stereo else {
            throw CapturePCMError("Active AVCapture multichannel mode changed unexpectedly.")
        }
        return WearableCaptureSessionState(activeMode: "stereo",
            requestedOrientation: WearableMicState.orientationName(requestedOrientation),
            preferredOrientation: WearableMicState.orientationName(audioSession.preferredInputOrientation),
            actualOrientation: WearableMicState.orientationName(audioSession.inputOrientation),
            usesAppAudioSession: capture.usesApplicationAudioSession,
            autoConfiguresAudioSession: capture.automaticallyConfiguresApplicationAudioSession)
    }

    private func cleanup() {
        output?.setSampleBufferDelegate(nil, queue: nil)
        deliveryQueue.sync { accepting = false }
        session?.stopRunning() // Also cancel a session suspended by interruption; never let it auto-resume.
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        // Delivery has drained and cannot enqueue new jobs; finish/release the bounded PCM work.
        let retiring: AIInputProcessor? = worker.sync {
            stopped = true
            let retiring = processor
            retiring?.stop()
            processor = nil
            adapter = nil
            meter = nil
            return retiring
        }
        // A failed start may already have run cleanup; retain its drain until stop completes.
        if let retiring { drainingProcessor = retiring }
        if let session {
            session.beginConfiguration()
            if let output { session.removeOutput(output) }
            if let input { session.removeInput(input) }
            session.commitConfiguration()
        }
        output = nil
        input = nil
        session = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard accepting else { return }
        guard slots.wait(timeout: .now()) == .success else {
            accepting = false
            reportFailure("Wearable PCM processing could not keep up. Capture stopped to avoid an audio gap.")
            return
        }
        // Retain, never mutate; at most four samples are in flight. No conversion/allocation of PCM here.
        let retained = RetainedCaptureSample(sampleBuffer)
        worker.async { [self] in
            defer { slots.signal() }
            guard !stopped, !failed else { return }
            do { try consume(retained.sample) }
            catch { fail("Wearable PCM: \(error.localizedDescription)") }
        }
    }

    private func consume(_ sample: CMSampleBuffer) throws {
        if adapter == nil {
            let newAdapter = try CapturePCMAdapter(firstSample: sample)
            let newProcessor = try AIInputProcessor(nativeFormat: newAdapter.floatFormat) { [weak self] message in
                self?.reportFailure(message)
            }
            adapter = newAdapter
            processor = newProcessor
            meter = NativeRMSMeter()
            onPrepared(newAdapter.description, newProcessor)
        }
        guard let adapter, let processor, let meter else { return }
        let pcm = try adapter.copyFloatPCM(sample)
        processor.enqueue(pcm) // Existing equal-weight mono downmix, sole 16 kHz resampler and ring.
        if let (dbFS, stereo) = meter.consume(pcm, monitorStereo: true, measureStereo: pcm.format.channelCount >= 2),
           let stereo {
            onReading(dbFS, stereo)
        }
    }

    private func reportFailure(_ message: String) {
        worker.async { [weak self] in self?.fail(message) }
    }

    private func fail(_ message: String) {
        guard !stopped, !failed else { return }
        failed = true
        onFailure(message)
    }
}

// The retained CMSampleBuffer is read by one worker and never mutated or exposed to UI.
private final class RetainedCaptureSample: @unchecked Sendable {
    let sample: CMSampleBuffer
    init(_ sample: CMSampleBuffer) { self.sample = sample }
}
