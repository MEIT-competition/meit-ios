import AVFAudio
import Combine
import CoreHaptics
import UIKit

@MainActor
final class HapticManager: ObservableObject {
    @Published private(set) var status = "Not tested"
    @Published private(set) var errorMessage: String?
    let isSupported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private var engine: CHHapticEngine?
    private var player: CHHapticPatternPlayer?
    private var lastPlay: TimeInterval = -.infinity

    func play() {
        guard UIApplication.shared.applicationState == .active else { return }
        guard isSupported else {
            status = "Unsupported"
            return
        }
        // Prevent overlapping bursts, including rapid local debug taps.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPlay >= 0.5 else { return }
        do {
            errorMessage = nil
            let session = AVAudioSession.sharedInstance()
            let inputCategory = [AVAudioSession.Category.record, .playAndRecord, .multiRoute].contains(session.category)
            if inputCategory && !session.allowHapticsAndSystemSoundsDuringRecording {
                try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            }
            if engine == nil {
                let newEngine = try CHHapticEngine(audioSession: nil)
                newEngine.playsHapticsOnly = true
                newEngine.isAutoShutdownEnabled = true
                newEngine.resetHandler = { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.player = nil
                        self?.status = "Reset; ready for next command"
                    }
                }
                newEngine.stoppedHandler = { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.player = nil
                        self?.status = "Stopped; ready for next command"
                    }
                }
                engine = newEngine
            }
            guard let engine else { return }
            try engine.start()
            if player == nil {
                let events = [0.0, 0.12, 0.24].map { time in
                    CHHapticEvent(eventType: .hapticTransient, parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.7)
                    ], relativeTime: time)
                }
                let pattern = try CHHapticPattern(events: events, parameters: [])
                player = try engine.makePlayer(with: pattern)
            }
            try player?.start(atTime: CHHapticTimeImmediate)
            lastPlay = now
            status = "Played"
        } catch {
            player = nil
            errorMessage = error.localizedDescription
            status = "Failed"
        }
    }

    func stop() {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        engine?.stop(completionHandler: nil)
        status = "Stopped"
    }
}
