import AVFoundation
import CoreMedia
import Foundation

struct CapturePCMDescription: Sendable {
    let sampleRate: Double
    let channels: Int
    let formatID: UInt32
    let flags: UInt32
    let bitsPerChannel: UInt32
    let interleaved: Bool

    init(_ asbd: AudioStreamBasicDescription) {
        sampleRate = asbd.mSampleRate
        channels = Int(asbd.mChannelsPerFrame)
        formatID = asbd.mFormatID
        flags = asbd.mFormatFlags
        bitsPerChannel = asbd.mBitsPerChannel
        interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
    }

    var formatSummary: String {
        let id = formatID == kAudioFormatLinearPCM ? "lpcm" : String(format: "0x%08X", formatID)
        return "\(id) · flags=\(String(format: "0x%08X", flags)) · \(bitsPerChannel)-bit"
    }
}

// Confined to WearableStereoCapture's bounded worker. No rate conversion, downmix or ring here.
final class CapturePCMAdapter {
    let description: CapturePCMDescription
    let floatFormat: AVAudioFormat
    private let sourceDescription: CMFormatDescription
    private let native: AVAudioPCMBuffer
    private let floatPCM: AVAudioPCMBuffer
    private let converter: AVAudioConverter

    init(firstSample: CMSampleBuffer) throws {
        guard let formatDescription = CMSampleBufferGetFormatDescription(firstSample),
              CMFormatDescriptionGetMediaType(formatDescription) == kCMMediaType_Audio,
              let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            throw CapturePCMError("AVCapture returned no audio stream description.")
        }
        var asbd = pointer.pointee
        let info = CapturePCMDescription(asbd)
        description = info
        // Inspect native ASBD before constructing any PCM buffers; never assume Float32 or 48 kHz.
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate.isFinite,
              (8_000...192_000).contains(asbd.mSampleRate),
              (1...32).contains(asbd.mChannelsPerFrame), asbd.mFramesPerPacket == 1,
              asbd.mBytesPerFrame > 0, (1...64).contains(asbd.mBitsPerChannel),
              asbd.mBytesPerFrame <= (info.interleaved ? asbd.mChannelsPerFrame : 1) * 8,
              let nativeFormat = AVAudioFormat(streamDescription: &asbd, channelLayout: nil),
              let floatFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                  sampleRate: asbd.mSampleRate, channels: asbd.mChannelsPerFrame, interleaved: false),
              let converter = AVAudioConverter(from: nativeFormat, to: floatFormat) else {
            throw CapturePCMError("Unsupported AVCapture PCM: \(info.formatSummary), \(info.channels) channels, \(info.sampleRate) Hz.")
        }
        let capacity = AVAudioFrameCount(max(4_096, Int(ceil(asbd.mSampleRate * 0.5))))
        guard let native = AVAudioPCMBuffer(pcmFormat: nativeFormat, frameCapacity: capacity),
              let floatPCM = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: capacity) else {
            throw CapturePCMError("Unable to allocate bounded AVCapture PCM buffers.")
        }
        self.sourceDescription = formatDescription
        self.floatFormat = floatFormat
        self.native = native
        self.floatPCM = floatPCM
        self.converter = converter
    }

    // Returned storage is reused. AIInputProcessor.enqueue copies it synchronously before reuse.
    func copyFloatPCM(_ sample: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard CMSampleBufferDataIsReady(sample),
              let current = CMSampleBufferGetFormatDescription(sample),
              CMFormatDescriptionEqual(current, otherFormatDescription: sourceDescription) else {
            throw CapturePCMError("AVCapture PCM format changed or data is not ready. Restart capture.")
        }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, frames <= Int(native.frameCapacity) else {
            throw CapturePCMError("AVCapture PCM frame count exceeds the bounded adapter capacity.")
        }
        native.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0,
            frameCount: Int32(frames), into: native.mutableAudioBufferList)
        guard status == noErr else {
            throw CapturePCMError("Unable to copy AVCapture PCM (OSStatus \(status)).")
        }
        floatPCM.frameLength = 0
        // This API changes only sample representation/interleaving at the SAME rate/channel count.
        try converter.convert(to: floatPCM, from: native)
        guard floatPCM.frameLength == native.frameLength else {
            throw CapturePCMError("AVCapture Float32 adapter returned an incomplete PCM buffer.")
        }
        return floatPCM
    }
}

struct CapturePCMError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
