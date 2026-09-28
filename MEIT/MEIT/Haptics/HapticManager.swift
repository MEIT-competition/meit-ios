import AudioToolbox
import AVFAudio
import Combine
import UIKit

@MainActor
final class HapticManager: ObservableObject {
    @Published private(set) var status = "Not tested"
    @Published private(set) var errorMessage: String?
    // System Sound Services has no API to check whether vibration is enabled in Settings.
    let isSupported: Bool = {
        #if targetEnvironment(simulator)
        return false
        #else
        return UIDevice.current.userInterfaceIdiom == .phone
        #endif
    }()

    private var burstID: UUID?
    private var waitingForPulse = 0
    private var pendingTask: Task<Void, Never>?
    private var cooldownUntil: TimeInterval = 0
    private let completionTimeout: TimeInterval = 2

    func play() {
        guard UIApplication.shared.applicationState == .active else { return }
        guard isSupported else {
            status = "Unsupported"
            return
        }
        // Drop new commands/debug taps throughout the burst and its cooldown; never queue them.
        guard burstID == nil, ProcessInfo.processInfo.systemUptime >= cooldownUntil else { return }
        do {
            errorMessage = nil
            let session = AVAudioSession.sharedInstance()
            let inputCategory = [AVAudioSession.Category.record, .playAndRecord, .multiRoute].contains(session.category)
            if inputCategory && !session.allowHapticsAndSystemSoundsDuringRecording {
                try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            }
            let id = UUID()
            burstID = id
            requestPulse(id: id, number: 1)
        } catch {
            errorMessage = error.localizedDescription
            status = "Failed"
        }
    }

    private func requestPulse(id: UUID, number: Int) {
        guard burstID == id else { return }
        guard UIApplication.shared.applicationState == .active else {
            stop()
            return
        }
        waitingForPulse = number
        status = "Vibration requested (\(number)/3)"
        // A missing completion must not hang the manager or trigger overlapping fallback pulses.
        pendingTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            guard let self, burstID == id, waitingForPulse == number else { return }
            finish(status: "Vibration unconfirmed", cooldown: completionTimeout)
            errorMessage = "System vibration completion timed out. Check the iPhone vibration settings."
        }
        AudioServicesPlayAlertSoundWithCompletion(kSystemSoundID_Vibrate) { [weak self] in
            Task { @MainActor [weak self] in
                self?.pulseCompleted(id: id, number: number)
            }
        }
    }

    private func pulseCompleted(id: UUID, number: Int) {
        guard burstID == id, waitingForPulse == number else { return }
        waitingForPulse = 0  // Ignore duplicate/late completion callbacks, including during the gap.
        pendingTask?.cancel()
        pendingTask = nil
        if number == 3 {
            // Completion is not proof of physical vibration: iOS/user settings can suppress it.
            finish(status: "3 system vibrations requested", cooldown: 0.5)
            return
        }
        pendingTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            self?.requestPulse(id: id, number: number + 1)
        }
    }

    private func finish(status: String, cooldown: TimeInterval) {
        burstID = nil
        waitingForPulse = 0
        pendingTask?.cancel()
        pendingTask = nil
        cooldownUntil = max(cooldownUntil, ProcessInfo.processInfo.systemUptime + cooldown)
        self.status = status
    }

    func stop() {
        // There is no public cancellation API for an already requested system vibration.
        // Invalidate future pulses/callbacks and reserve time for the current request to finish.
        if burstID != nil {
            finish(status: "Stopped", cooldown: completionTimeout)
        } else {
            status = "Stopped"
        }
    }
}
