import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

struct CapturePCMDescription: Sendable {
    let sampleRate: Double
    let channels: Int
    let formatID: UInt32
    let flags: UInt32
    let bitsPerChannel: UInt32
    let interleaved: Bool
    let channelLayout: CaptureChannelLayout

    init(_ asbd: AudioStreamBasicDescription, formatDescription: CMAudioFormatDescription) {
        channelLayout = CaptureChannelLayout.read(formatDescription, channels: Int(asbd.mChannelsPerFrame))
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

// Read-only metadata from the ORIGINAL CMSampleBuffer, never from the Float32 adapter.
// Core Audio labels describe stream roles; they do not prove a physical microphone mapping.
struct CaptureChannelLayout: Sendable {
    var tag = "unknown"
    var channel0Label = "unknown"
    var channel1Label = "unknown"

    static func read(_ description: CMAudioFormatDescription, channels: Int) -> Self {
        var result = Self()
        var bytes = 0
        guard let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &bytes),
              let headerSize = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions),
              bytes >= headerSize else { return result }
        let raw = UnsafeRawPointer(layout)
        let tag = raw.load(as: AudioChannelLayoutTag.self)
        result.tag = String(format: "0x%08X", tag)
        if tag == kAudioChannelLayoutTag_UseChannelDescriptions {
            result.setLabels(raw, bytes: bytes, channels: channels)
            return result
        }
        // A supplied standard tag/bitmap defines labels. Expand it using Core Audio;
        // do not infer Stereo/Left/Right merely because the ASBD has two channels.
        let property: AudioFormatPropertyID
        var specifier: UInt32
        if tag == kAudioChannelLayoutTag_UseChannelBitmap {
            property = kAudioFormatProperty_ChannelLayoutForBitmap
            guard let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelBitmap) else { return result }
            specifier = raw.load(fromByteOffset: offset, as: AudioChannelBitmap.self).rawValue
        } else {
            property = kAudioFormatProperty_ChannelLayoutForTag
            specifier = tag
        }
        var size: UInt32 = 0
        let specifierSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioFormatGetPropertyInfo(property, specifierSize, &specifier, &size) == noErr,
              size >= UInt32(headerSize), size <= 4096 else { return result }
        let expanded = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { expanded.deallocate() }
        let capacity = size
        guard AudioFormatGetProperty(property, specifierSize, &specifier, &size, expanded) == noErr,
              size <= capacity else { return result }
        result.setLabels(UnsafeRawPointer(expanded), bytes: Int(size), channels: channels)
        return result
    }

    private mutating func setLabels(_ raw: UnsafeRawPointer, bytes: Int, channels: Int) {
        guard let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions),
              let countOffset = MemoryLayout<AudioChannelLayout>.offset(of: \.mNumberChannelDescriptions),
              bytes >= offset,
              raw.load(as: AudioChannelLayoutTag.self) == kAudioChannelLayoutTag_UseChannelDescriptions else { return }
        let count = Int(raw.load(fromByteOffset: countOffset, as: UInt32.self))
        let stride = MemoryLayout<AudioChannelDescription>.stride
        guard count == channels, count <= (bytes - offset) / stride else { return }
        if count > 0 { channel0Label = Self.label(raw.load(fromByteOffset: offset, as: AudioChannelDescription.self).mChannelLabel) }
        if count > 1 { channel1Label = Self.label(raw.load(fromByteOffset: offset + stride, as: AudioChannelDescription.self).mChannelLabel) }
    }

    private static func label(_ value: AudioChannelLabel) -> String {
        switch value {
        case kAudioChannelLabel_Left: return "Left"
        case kAudioChannelLabel_Right: return "Right"
        case kAudioChannelLabel_Center: return "Center"
        case kAudioChannelLabel_Mono: return "Mono"
        default: return String(format: "unknown (label 0x%08X)", value)
        }
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
        let info = CapturePCMDescription(asbd, formatDescription: formatDescription)
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
