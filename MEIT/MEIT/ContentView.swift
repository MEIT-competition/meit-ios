import SwiftUI

@MainActor
struct ContentView: View {
    // One owner for the entire root view lifetime, independent of the selected mode.
    @StateObject private var audio = AudioCaptureManager()
    @StateObject private var network = NetworkManager()
    @StateObject private var devices = DeviceCoordinator()
    @StateObject private var haptics = HapticManager()
    @AppStorage("meit.operatingMode") private var operatingMode: OperatingMode = .hardware
    @State private var startCaptureTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("operating mode", selection: modeSelection) {
                    ForEach(OperatingMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)

                switch operatingMode {
                case .hardware:
                    HardwareModeView()
                case .fallback:
                    FallbackModeView(audio: audio, network: network, devices: devices, haptics: haptics,
                                     operatingMode: $operatingMode, onStartCapture: startCapture,
                                     onStopCapture: stopCapture, onDeactivate: deactivateFallback)
                }
            }
            .navigationTitle("meit ios")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var modeSelection: Binding<OperatingMode> {
        Binding(get: { operatingMode }, set: { next in
            guard next != operatingMode else { return }
            // Stop immediately, before rendering Hardware. onDisappear repeats this safely.
            if next == .hardware { deactivateFallback() }
            operatingMode = next
        })
    }

    private func startCapture() {
        guard operatingMode == .fallback, scenePhase == .active,
              !audio.isCapturing, !audio.isStarting else { return }
        startCaptureTask?.cancel()
        startCaptureTask = Task {
            // A queued Start tap must not start recording after a mode switch/Stop.
            guard !Task.isCancelled else { return }
            await audio.startCapture()
        }
    }

    private func stopCapture() {
        startCaptureTask?.cancel()
        startCaptureTask = nil
        devices.cancelAutomaticSnapshot()
        network.cancel()
        audio.stopCapture()
    }

    private func deactivateFallback() {
        // Existing generation guards invalidate late network/permission completions.
        // Keep address, role and device ID; do not change the bridge's global Auto setting.
        devices.disconnect()
        haptics.stop()
        stopCapture()
    }
}
