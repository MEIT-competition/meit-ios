import SwiftUI

@MainActor
struct FallbackModeView: View {
    @ObservedObject var audio: AudioCaptureManager
    @ObservedObject var network: NetworkManager
    @ObservedObject var devices: DeviceCoordinator
    @ObservedObject var haptics: HapticManager
    @Binding var operatingMode: OperatingMode
    let onStartCapture: () -> Void
    let onStopCapture: () -> Void
    let onDeactivate: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var presentedPage: FallbackPage?
    @State private var lastDetection: DetectionPresentation?
    @State private var lastAutomaticEventID: String?

    private struct DetectionPresentation {
        let result: AIInferenceResult
        let direction: String?
        let source: String
    }

    private var listeningTitle: String {
        if audio.microphonePermission == .denied { return "microphone access needed" }
        if audio.isStarting { return "starting…" }
        return audio.isCapturing ? "listening" : "not listening"
    }

    private var listeningDescription: String {
        if audio.microphonePermission == .denied {
            return "Allow microphone access in iPhone Settings to start listening."
        }
        if audio.isStarting { return "Waiting for microphone access." }
        guard audio.isCapturing else { return "Start listening when you’re ready." }
        guard devices.isRegistered, devices.pollingStatus == "Active" else {
            return "Your microphone is on. Connect to the server in settings to analyze sounds."
        }
        guard devices.autoStatus?.enabled == true else {
            return "Your microphone is on. Turn on auto detection to analyze sounds."
        }
        if !audio.aiBufferStatus.isReady { return "Preparing to analyze your surroundings." }
        return "Listening for environmental sounds."
    }

    private var autoEnabled: Binding<Bool> {
        Binding(get: { devices.autoStatus?.enabled ?? false }, set: { enabled in
            // Presentation only: use the existing global Auto action and eligibility rules.
            devices.setAutomaticDetection(enabled)
        })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(audio.isCapturing ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(listeningTitle).font(.title2.weight(.semibold))
                    }
                    Text(listeningDescription).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("auto detection", isOn: autoEnabled)
                        .disabled(!devices.isRegistered || devices.changingAuto
                                  || (devices.autoStatus?.enabled != true && !audio.isCapturing))
                        .accessibilityValue(devices.autoStatus.map { $0.enabled ? "on" : "off" } ?? "unavailable")
                    Text(devices.changingAuto ? "Updating…" :
                         (devices.autoStatus == nil ? "Connect to the server to check auto detection." :
                          "Automatically analyzes detected sounds. Shared by all connected phones."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let message = devices.autoMessage {
                        Text(message).font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                Divider()
                detectionSummary

                VStack(spacing: 16) {
                    Picker("device position", selection: $devices.role) {
                        ForEach(DeviceRole.allCases, id: \.self) { role in
                            Text(role.rawValue).tag(role)
                        }
                    }
                    .pickerStyle(.menu)
                    LabeledContent("server", value: devices.isRegistered && devices.pollingStatus == "Active"
                                   ? "connected" : "not connected")
                }

                if let error = audio.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
                if devices.networkError != nil || network.errorMessage != nil {
                    Text("Server communication needs attention. Open settings or diagnostics for details.")
                        .foregroundStyle(.secondary)
                }
                Divider()
                Button { presentedPage = .diagnostics } label: {
                    HStack {
                        Text("diagnostics")
                        Spacer()
                        Image(systemName: "chevron.right").accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(24)
        }
        .safeAreaInset(edge: .bottom) {
            listeningControl
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.background)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { presentedPage = .settings } label: {
                    Image(systemName: "gearshape").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("settings")
            }
        }
        // A sheet keeps this presenting screen in place while inspecting details.
        // Only leaving fallback invokes onDeactivate; detail navigation never owns capture.
        .sheet(item: $presentedPage) { page in
            NavigationStack {
                FallbackDetailsView(audio: audio, network: network, devices: devices, haptics: haptics,
                                    operatingMode: $operatingMode, page: page)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("done") { presentedPage = nil }
                        }
                    }
            }
            .presentationDetents([.large])
        }
        // Retain only the latest result observed by this screen, not an inference history.
        // Repeated polling of the same event must not overwrite a newer manual result.
        .onReceive(network.$result) { result in
            if let result {
                lastDetection = DetectionPresentation(result: result, direction: result.direction, source: "manual")
            }
        }
        .onReceive(devices.$autoStatus) { status in
            if let event = status?.last_event, let result = event.result,
               event.event_id != lastAutomaticEventID {
                lastAutomaticEventID = event.event_id
                lastDetection = DetectionPresentation(result: result, direction: event.direction, source: "automatic")
            }
        }
        .onChange(of: network.serverAddress) { _, _ in
            lastDetection = nil
            lastAutomaticEventID = nil
        }
        .onAppear {
            guard operatingMode == .fallback else { return }
            audio.refreshPermission()
            // Reuse this session's settings/objects after returning from Hardware.
            // Reconnect coordination only; capture still requires Start Capture.
            if scenePhase == .active, network.hasConnected {
                devices.connect(network: network, audio: audio, haptics: haptics)
            }
        }
        .onDisappear {
            onDeactivate()
        }
        .onChange(of: audio.isCapturing) { _, capturing in
            if !capturing {
                devices.cancelAutomaticSnapshot()
                network.cancel()
            }
        }
        .onChange(of: network.serverAddress) { _, _ in devices.disconnect() }
        .onChange(of: network.connectionStatus) { _, status in
            if operatingMode == .fallback, status == "Connected", scenePhase == .active {
                devices.connect(network: network, audio: audio, haptics: haptics)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard operatingMode == .fallback else { return }
            if phase != .active {
                devices.disconnect()
                haptics.stop()
            }
            if phase == .background {
                onDeactivate()
            } else if phase == .active {
                audio.refreshPermission()
                if network.hasConnected {
                    devices.connect(network: network, audio: audio, haptics: haptics)
                }
            }
        }
    }

    private var listeningControl: some View {
        Button {
            if audio.isCapturing || audio.isStarting { onStopCapture() }
            else { onStartCapture() }
        } label: {
            Text(audio.isCapturing || audio.isStarting ? "stop listening" : "start listening")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .frame(maxWidth: .infinity)
        .accessibilityHint(audio.isCapturing || audio.isStarting
                           ? "Stops microphone capture and pending audio uploads."
                           : "Starts microphone capture. Auto detection is controlled separately.")
    }

    private var detectionSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("last detection").font(.headline)
            if let detection = lastDetection {
                Text(displayLabel(detection.result.label)).font(.title2.weight(.medium))
                Text(String(format: "%.1f%% confidence", detection.result.confidence * 100))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text("Last \(detection.source) result").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("No detection yet").foregroundStyle(.secondary)
                Text("Results will appear after a sound is analyzed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            // Before the first result show live direction; afterwards show that result's direction.
            let direction = lastDetection == nil ? devices.direction?.direction : lastDetection?.direction
            if let direction, DeviceRole(rawValue: direction.lowercased()) != nil {
                LabeledContent("direction", value: direction.lowercased())
            } else {
                Text("direction unavailable")
                Text("Connect all four positions and check their microphone levels for direction detection.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func displayLabel(_ raw: String) -> String {
        switch raw {
        case "horn": return "Horn"
        case "siren": return "Siren"
        case "crash": return "Crash"
        case "normal": return "Normal Sound"
        default: return raw
        }
    }
}
