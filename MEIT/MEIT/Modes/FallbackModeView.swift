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
    @Environment(\.appLanguage) private var language
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
        if audio.microphonePermission == .denied { return language.text("main.permission.title") }
        if audio.isStarting { return language.text("main.starting.title") }
        return audio.isCapturing ? language.text("main.listening.title") : language.text("main.idle.title")
    }

    private var listeningDescription: String {
        if audio.microphonePermission == .denied {
            return language.text("main.permission.subtitle")
        }
        if audio.isStarting { return language.text("main.starting.subtitle") }
        guard audio.isCapturing else { return language.text("main.idle.subtitle") }
        guard devices.isRegistered, devices.pollingStatus == "Active" else {
            return language.text("main.offline.subtitle")
        }
        guard devices.autoStatus?.enabled == true else {
            return language.text("main.manual.subtitle")
        }
        if !audio.aiBufferStatus.isReady { return language.text("main.buffering.subtitle") }
        return language.text("main.listening.subtitle")
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

                LiveAudioView(rmsDBFS: audio.rmsDBFS, isCapturing: audio.isCapturing)

                VStack(alignment: .leading, spacing: 8) {
                    Toggle(language.text("main.autoDetection"), isOn: autoEnabled)
                        .disabled(!devices.isRegistered || devices.changingAuto
                                  || (devices.autoStatus?.enabled != true && !audio.isCapturing))
                        .accessibilityValue(devices.autoStatus.map { $0.enabled ? language.text("status.on") : language.text("status.off") } ?? language.text("status.unavailable"))
                    Text(devices.changingAuto ? language.text("main.auto.updating") :
                         (devices.autoStatus == nil ? language.text("main.auto.connect") :
                          language.text("main.auto.description")))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if devices.autoMessage != nil {
                        Text(language.text("main.auto.notice")).font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                Divider()
                detectionSummary

                VStack(spacing: 16) {
                    Picker(language.text("main.devicePosition"), selection: $devices.role) {
                        ForEach(DeviceRole.allCases, id: \.self) { role in
                            Text(language.position(role.rawValue)).tag(role)
                        }
                    }
                    .pickerStyle(.menu)
                    LabeledContent(language.text("main.server"), value: devices.isRegistered && devices.pollingStatus == "Active"
                                   ? language.text("status.connected") : language.text("status.notConnected"))
                }

                if audio.errorMessage != nil {
                    Text(language.text("main.microphoneError")).foregroundStyle(.red)
                }
                if devices.networkError != nil || network.errorMessage != nil {
                    Text(language.text("main.networkError"))
                        .foregroundStyle(.secondary)
                }
                Divider()
                Button { presentedPage = .diagnostics } label: {
                    HStack {
                        Text(language.text("diagnostics.title"))
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
                .accessibilityLabel(language.text("settings.title"))
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
                            Button(language.text("common.done")) { presentedPage = nil }
                        }
                    }
            }
            // Keep the presented hierarchy on the current selection while the sheet is open.
            .environment(\.appLanguage, language)
            .environment(\.locale, language.locale)
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
            Text(audio.isCapturing || audio.isStarting ? language.text("main.stop") : language.text("main.start"))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .frame(maxWidth: .infinity)
        .accessibilityHint(audio.isCapturing || audio.isStarting
                           ? language.text("main.stop.hint")
                           : language.text("main.start.hint"))
    }

    private var detectionSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(language.text("main.lastDetection")).font(.headline)
            if let detection = lastDetection {
                Text(language.soundLabel(detection.result.label)).font(.title2.weight(.medium))
                Text(language.text("main.confidence", detection.result.confidence * 100))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(language.text(detection.source == "manual" ? "main.result.manual" : "main.result.automatic")).font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text(language.text("main.noDetection")).foregroundStyle(.secondary)
                Text(language.text("main.result.placeholder"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            // Before the first result show live direction; afterwards show that result's direction.
            let direction = lastDetection == nil ? devices.direction?.direction : lastDetection?.direction
            if let direction, DeviceRole(rawValue: direction.lowercased()) != nil {
                LabeledContent(language.text("main.direction"), value: language.position(direction))
            } else {
                Text(language.text("main.directionUnavailable"))
                Text(language.text("main.directionHelp"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
