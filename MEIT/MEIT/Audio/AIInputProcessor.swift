import AVFoundation
import Foundation

// One producer (the input tap). Converter, ring, and active state belong to queue only.
// Slots are handed from producer to FIFO worker with a semaphore; never reused while in flight.
// @unchecked Sendable expresses this ownership protocol, not unrestricted mutable access.
final class AIInputProcessor: @unchecked Sendable {
    private static let slotCount = 4
    private let queue = DispatchQueue(label: "org.meit.ai-input", qos: .userInitiated)
    private let freeSlots = DispatchSemaphore(value: AIInputProcessor.slotCount)
    private let nativeFormat: AVAudioFormat
    private let slots: [AVAudioPCMBuffer]
    private let monoBuffer: AVAudioPCMBuffer
    private let converterInput: AVAudioPCMBuffer
    private let outputBuffer: AVAudioPCMBuffer
    private let converter: AVAudioConverter
    private let onFailure: @Sendable (String) -> Void

    // Tap thread only; a failure stops all further submissions for this capture.
    private var nextSlot = 0
    private var tapFailed = false
    // Worker queue only.
    private var active = true
    private var ring = PCM16RingBuffer()

    init(nativeFormat: AVAudioFormat, onFailure: @escaping @Sendable (String) -> Void) throws {
        let rate = nativeFormat.sampleRate
        // Bound allocation even for an unexpected system format; no 48 kHz assumption.
        guard rate.isFinite, rate >= 8_000, rate <= 192_000,
              (1...32).contains(Int(nativeFormat.channelCount)),
              nativeFormat.commonFormat == .pcmFormatFloat32 else {
            throw ProcessingError("Unsupported native PCM format.")
        }
        let capacity = AVAudioFrameCount(max(4_096, Int(ceil(rate * 0.5))))
        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: rate, channels: 1, interleaved: false),
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                              sampleRate: Double(AIInputFormat.sampleRate),
                                              channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: monoFormat, to: targetFormat) else {
            throw ProcessingError("Unable to create the 16 kHz PCM16 converter.")
        }
        self.nativeFormat = nativeFormat
        self.onFailure = onFailure
        self.converter = converter
        // Keep filter/priming state across all buffers in this capture.
        converter.sampleRateConverterQuality = Int(AVAudioQuality.high.rawValue)
        converter.primeMethod = .normal
        slots = try (0..<AIInputProcessor.slotCount).map { _ in
            try AIInputProcessor.allocate(nativeFormat, capacity: capacity)
        }
        monoBuffer = try AIInputProcessor.allocate(monoFormat, capacity: capacity)
        converterInput = try AIInputProcessor.allocate(monoFormat, capacity: capacity)
        outputBuffer = try AIInputProcessor.allocate(targetFormat, capacity: 2_048)
        assert(targetFormat.sampleRate == 16_000 && targetFormat.channelCount == 1)
        assert(targetFormat.commonFormat == .pcmFormatInt16)
    }

    /// Called only by the tap. No wait, conversion, ring writes, or large allocation here.
    func enqueue(_ input: AVAudioPCMBuffer) {
        guard !tapFailed, input.frameLength > 0 else { return }
        guard input.format.isEqual(nativeFormat), input.frameLength <= slots[0].frameCapacity else {
            rejectInput("Native input format or buffer size changed. Tap Start Capture to retry.")
            return
        }
        guard freeSlots.wait(timeout: .now()) == .success else {
            rejectInput("AI conversion could not keep up. Capture stopped to avoid an audio gap.")
            return
        }
        let slot = slots[nextSlot]
        guard copy(input, to: slot) else {
            freeSlots.signal()
            rejectInput("Unable to copy native PCM input.")
            return
        }
        nextSlot = (nextSlot + 1) % slots.count
        // At most four of these jobs can be outstanding, including the current conversion.
        queue.async { [self] in
            defer { freeSlots.signal() }
            guard active else { return }
            process(slot)
        }
    }

    /// MainActor calls this only after invalidating its capture ID and removing the tap.
    func stop() {
        queue.async { [self] in
            active = false
            converter.reset()
            ring.reset()
        }
    }

    func status() async -> AIInputBufferStatus {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: active ? ring.status : .empty)
            }
        }
    }

    func makeSnapshot() async -> AIInputSnapshot? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: active ? ring.makeSnapshot() : nil)
            }
        }
    }

    private static func allocate(_ format: AVAudioFormat, capacity: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw ProcessingError("Unable to allocate audio conversion buffers.")
        }
        return buffer
    }

    private func copy(_ input: AVAudioPCMBuffer, to destination: AVAudioPCMBuffer) -> Bool {
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard source.count == target.count else { return false }
        let byteCount = Int(input.frameLength) * Int(nativeFormat.streamDescription.pointee.mBytesPerFrame)
        destination.frameLength = input.frameLength
        for index in source.indices {
            guard Int(source[index].mDataByteSize) >= byteCount, Int(target[index].mDataByteSize) >= byteCount,
                  let sourceData = source[index].mData, let targetData = target[index].mData else { return false }
            memcpy(targetData, sourceData, byteCount)
        }
        return true
    }

    private func rejectInput(_ message: String) {
        // Tap-confined latch: enqueue only one failure, even if the main thread is busy.
        tapFailed = true
        queue.async { [self] in fail(message) }
    }

    private func fail(_ message: String) {
        guard active else { return }
        active = false
        converter.reset()
        ring.reset()
        onFailure(message)
    }

    private func process(_ input: AVAudioPCMBuffer) {
        guard let channels = input.floatChannelData,
              let mono = monoBuffer.floatChannelData?[0],
              let feed = converterInput.floatChannelData?[0] else {
            fail("Float32 PCM data is unavailable.")
            return
        }
        let frames = Int(input.frameLength)
        let channelCount = Int(input.format.channelCount)
        monoBuffer.frameLength = input.frameLength
        // Explicit equal-weight mono mix handles planar/interleaved input without layout assumptions.
        for frame in 0..<frames {
            var sum = 0.0
            for channel in 0..<channelCount {
                let value = Double(channels[channel][frame * input.stride])
                if value.isFinite { sum += value }
            }
            mono[frame] = Float(min(1, max(-1, sum / Double(channelCount))))
        }

        var offset = 0
        let expectedFrames = Double(frames) * Double(AIInputFormat.sampleRate) / nativeFormat.sampleRate
        let passLimit = Int(ceil(expectedFrames / Double(outputBuffer.frameCapacity))) + 8
        // Drain valid output, including partial output returned with inputRanDry.
        for _ in 0..<passLimit {
            outputBuffer.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { [self] requested, inputStatus in
                let count = min(Int(requested), frames - offset)
                guard count > 0 else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                // The same source frames must never be supplied twice when the converter asks again.
                feed.update(from: mono.advanced(by: offset), count: count)
                converterInput.frameLength = AVAudioFrameCount(count)
                offset += count
                inputStatus.pointee = .haveData
                return converterInput
            }
            guard status != .error, error == nil else {
                fail("AI conversion failed: \(error?.localizedDescription ?? "unknown converter error")")
                return
            }
            if outputBuffer.frameLength > 0 {
                guard let samples = outputBuffer.int16ChannelData?[0] else {
                    fail("PCM16 converter returned no sample data.")
                    return
                }
                ring.append(samples, count: Int(outputBuffer.frameLength))
            }
            switch status {
            case .inputRanDry:
                if offset != frames { fail("AI conversion did not consume all input frames.") }
                return
            case .haveData:
                guard outputBuffer.frameLength > 0 else {
                    fail("AI converter made no progress.")
                    return
                }
            case .endOfStream, .error:
                fail("AI converter unexpectedly ended the live stream.")
                return
            @unknown default:
                fail("Unknown AI converter status.")
                return
            }
        }
        fail("AI converter exceeded its bounded drain limit.")
    }

    private struct ProcessingError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
