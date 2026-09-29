import SwiftUI

@MainActor
struct ContentView: View {
    // One owner for the entire root view lifetime, independent of the selected mode.
    @StateObject private var audio = AudioCaptureManager()
    @StateObject private var network = NetworkManager()
    @StateObject private var devices = DeviceCoordinator()
    @StateObject private var haptics = HapticManager()
    @AppStorage("meit.operatingMode") private var operatingMode: OperatingMode = .hardware
    @AppStorage("meit.language") private var language: AppLanguage = .english
    @State private var startCaptureTask: Task<Void, Never>?
    @State private var backupCaptureTask: Task<Void, Never>?
    @State private var backupRequestID: UUID?
    @State private var modeGeneration = UUID()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let generation = modeGeneration
        NavigationStack {
            VStack(spacing: 0) {
                Picker(language.text("mode.selector"), selection: modeSelection) {
                    ForEach(OperatingMode.allCases, id: \.self) { mode in
                        Text(language.text(mode.localizationKey)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)

                switch operatingMode {
                case .hardware:
                    HardwareModeView(audio: audio, backupEnabled: Binding(
                        get: { backupRequestID != nil }, set: setBackupMicrophone))
                case .fallback:
                    FallbackModeView(audio: audio, network: network, devices: devices, haptics: haptics,
                                     operatingMode: $operatingMode, onStartCapture: startCapture,
                                     onStopCapture: stopCapture, onDeactivate: {
                                         guard generation == modeGeneration else { return }
                                         deactivateFallback()
                                     })
                }
            }
            .navigationTitle("meit ios")
            .navigationBarTitleDisplayMode(.inline)
        }
        .environment(\.appLanguage, language)
        .environment(\.locale, language.locale)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { stopBackupMicrophone() }
            else if phase == .active, operatingMode == .hardware { audio.refreshPermission() }
        }
        .onChange(of: audio.captureOwner) { _, owner in
            if owner == .none, audio.captureOwner == .none, backupCaptureTask == nil { stopBackupMicrophone() }
        }
    }

    private var modeSelection: Binding<OperatingMode> {
        Binding(get: { operatingMode }, set: { next in
            guard next != operatingMode else { return }
            // Stop before rendering the next mode; invalidate cleanup closures from the old screen.
            if next == .hardware { deactivateFallback() }
            else { stopBackupMicrophone() }
            modeGeneration = UUID()
            operatingMode = next
        })
    }

    private func startCapture() {
        guard operatingMode == .fallback, scenePhase == .active,
              !audio.isCapturing, !audio.isStarting else { return }
        startCaptureTask?.cancel()
        startCaptureTask = Task {
            // A queued Start tap must not start recording after a mode switch/Stop.
            guard !Task.isCancelled, operatingMode == .fallback, scenePhase == .active else { return }
            await audio.startCapture()
        }
    }

    private func stopCapture() {
        startCaptureTask?.cancel()
        startCaptureTask = nil
        devices.cancelAutomaticSnapshot()
        network.cancel()
        audio.stopCapture(owner: .iphoneMode)
    }

    private func setBackupMicrophone(_ enabled: Bool) {
        if !enabled { stopBackupMicrophone(); return }
        guard operatingMode == .hardware, scenePhase == .active,
              backupRequestID == nil, !audio.isCapturing, !audio.isStarting else { return }
        let id = UUID()
        backupRequestID = id
        backupCaptureTask = Task {
            guard !Task.isCancelled, backupRequestID == id,
                  operatingMode == .hardware, scenePhase == .active else { return }
            await audio.startCapture(owner: .wearableBackup)
            guard backupRequestID == id else { return }
            if !audio.isCapturing || audio.captureOwner != .wearableBackup { stopBackupMicrophone() }
            backupCaptureTask = nil
        }
    }

    private func stopBackupMicrophone() {
        backupRequestID = nil
        backupCaptureTask?.cancel()
        backupCaptureTask = nil
        audio.stopCapture(owner: .wearableBackup)
    }

    private func deactivateFallback() {
        // Existing generation guards invalidate late network/permission completions.
        // Keep address, role and device ID; do not change the bridge's global Auto setting.
        devices.disconnect()
        haptics.stop()
        stopCapture()
    }
}
