import Foundation

enum AIInputFormat {
    static let sampleRate = 16_000
    static let channels = 1
    static let capacity = 40_000
    static let bytesPerSample = MemoryLayout<Int16>.size
    static let byteCount = capacity * bytesPerSample
}

struct AIInputBufferStatus: Sendable {
    let sampleCount: Int
    let totalConvertedSamples: UInt64

    static let empty = AIInputBufferStatus(sampleCount: 0, totalConvertedSamples: 0)
    var byteCount: Int { sampleCount * AIInputFormat.bytesPerSample }
    var duration: Double { Double(sampleCount) / Double(AIInputFormat.sampleRate) }
    var isReady: Bool { sampleCount == AIInputFormat.capacity }
}

/// Immutable, headerless, chronological PCM16LE. Safe to hand to a future network sender.
struct AIInputSnapshot: Sendable {
    let pcm16LittleEndian: Data
    var sampleRate: Int { AIInputFormat.sampleRate }
    var channels: Int { AIInputFormat.channels }
    var sampleFormat: String { "Int16 (PCM16LE)" }
    var sampleCount: Int { pcm16LittleEndian.count / AIInputFormat.bytesPerSample }
    var byteCount: Int { pcm16LittleEndian.count }
    var duration: Double { Double(sampleCount) / Double(sampleRate) }

    fileprivate init?(pcm16LittleEndian: Data) {
        guard pcm16LittleEndian.count == AIInputFormat.byteCount else { return nil }
        self.pcm16LittleEndian = pcm16LittleEndian
        assert(sampleRate == 16_000 && channels == 1 && AIInputFormat.bytesPerSample == 2)
        assert(sampleCount == 40_000 && byteCount == 80_000 && duration == 2.5)
    }
}

/// Access only on AIInputProcessor's serial queue. No shifting, growing, or shared array snapshots.
struct PCM16RingBuffer {
    private var storage = [Int16](repeating: 0, count: AIInputFormat.capacity)
    private var writeIndex = 0
    private(set) var count = 0
    private(set) var totalConvertedSamples: UInt64 = 0

    var status: AIInputBufferStatus {
        AIInputBufferStatus(sampleCount: count, totalConvertedSamples: totalConvertedSamples)
    }

    mutating func append(_ samples: UnsafePointer<Int16>, count sampleCount: Int) {
        guard sampleCount > 0 else { return }
        for index in 0..<sampleCount {
            storage[writeIndex] = samples[index]
            writeIndex += 1
            if writeIndex == storage.count { writeIndex = 0 }
        }
        count = min(storage.count, count + sampleCount)
        totalConvertedSamples += UInt64(sampleCount)
    }

    mutating func reset() {
        writeIndex = 0
        count = 0
        totalConvertedSamples = 0
        // Old slots are inaccessible until all 40,000 positions have been overwritten.
    }

    func makeSnapshot() -> AIInputSnapshot? {
        guard count == AIInputFormat.capacity else { return nil }
        var bytes = Data(count: AIInputFormat.byteCount)
        bytes.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let destination = raw.bindMemory(to: UInt8.self)
            for offset in 0..<count {
                // When full, the next write position is the oldest retained sample.
                let sample = storage[(writeIndex + offset) % storage.count]
                let bits = UInt16(bitPattern: sample)
                destination[offset * 2] = UInt8(truncatingIfNeeded: bits)
                destination[offset * 2 + 1] = UInt8(truncatingIfNeeded: bits >> 8)
            }
        }
        return AIInputSnapshot(pcm16LittleEndian: bytes)
    }
}
