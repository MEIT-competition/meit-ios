import SwiftUI

enum FallbackPage: String, Identifiable {
    case settings
    case diagnostics
    case developerTools = "developer tools"
    var id: String { rawValue }
    var localizationKey: String {
        switch self {
        case .settings: return "settings.title"
        case .diagnostics: return "diagnostics.title"
        case .developerTools: return "developer.title"
        }
    }
}

// Detail screens observe the root's managers. Navigation never starts/stops capture or polling.
@MainActor
struct FallbackDetailsView: View {
    @ObservedObject var audio: AudioCaptureManager
    @ObservedObject var network: NetworkManager
    @ObservedObject var devices: DeviceCoordinator
    @ObservedObject var haptics: HapticManager
    @Binding var operatingMode: OperatingMode
    let page: FallbackPage
    @Environment(\.appLanguage) private var language
    @AppStorage("meit.language") private var selectedLanguage: AppLanguage = .english
    @State private var snapshotTask: Task<Void, Never>?
    @State private var snapshotInfo: String?
    @State private var checkingSnapshot = false

    var body: some View {
        List {
            switch page {
            case .settings: settings
            case .diagnostics: diagnostics
            case .developerTools: developerTools
            }
        }
        .listStyle(.inset)
        .navigationTitle(language.text(page.localizationKey))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { cancelSnapshotCheck() }
        .onChange(of: audio.isCapturing) { _, _ in cancelSnapshotCheck() }
    }

    private func destination(_ page: FallbackPage) -> FallbackDetailsView {
        FallbackDetailsView(audio: audio, network: network, devices: devices, haptics: haptics,
                            operatingMode: $operatingMode, page: page)
    }

    private var settings: some View {
        Group {
            Section {
                Picker(language.text("settings.language"), selection: $selectedLanguage) {
                    ForEach(AppLanguage.allCases, id: \.self) { option in
                        Text(option.nativeName).tag(option)
                    }
                }
                .pickerStyle(.menu)
            }
            Section {
                TextField(language.text("settings.addressPlaceholder"), text: $network.serverAddress)
                    .keyboardType(.decimalPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(network.isBusy)
                    .accessibilityLabel(language.text("settings.serverAddress"))
                LabeledContent(language.text("settings.port"), value: "8765")
                Button(language.text("developer.testConnection")) { network.testConnection() }
                    .disabled(network.isBusy)
                manualRequestState
            } header: { Text(language.text("settings.serverAddress")) }
            footer: { Text(language.text("settings.serverHelp")) }

            Section(language.text("settings.device")) {
                Picker(language.text("main.devicePosition"), selection: $devices.role) {
                    ForEach(DeviceRole.allCases, id: \.self) { role in
                        Text(language.position(role.rawValue)).tag(role)
                    }
                }
                .pickerStyle(.menu)
            }
            Section {
                NavigationLink(language.text("diagnostics.title")) { destination(.diagnostics) }
                NavigationLink(language.text("developer.title")) { destination(.developerTools) }
            }
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    Text("meit ios")
                        .font(.headline.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Text(language.text("settings.aboutDescription"))
                        .font(.body)
                        .lineSpacing(4)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Text(language.text("hardware.pending"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Keep copyright in the row's measured flow, after all About content.
                    Text(language.text("settings.copyright"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 16)
                        .padding(.bottom, 24)
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(language.text("settings.about"))
            } header: {
                Text(language.text("settings.about"))
            }
        }
    }

    private var diagnostics: some View {
        Group {
            Section(language.text("diagnostics.audio")) {
                LabeledContent("Permission", value: audio.microphonePermission.rawValue)
                LabeledContent("Capture", value: audio.isCapturing ? "Running" : (audio.isStarting ? "Starting" : "Stopped"))
                diagnosticValue("Current local RMS", audio.rmsDBFS, unit: "dBFS")
                LabeledContent("Native input", value: audio.inputFormatDescription ?? "—")
                Text("16000 Hz / mono / PCM16 (little-endian)")
                LabeledContent("AI buffer", value: audio.aiBufferStatus.isReady ? "Ready" : (audio.isCapturing ? "Buffering" : "Stopped"))
                LabeledContent("Samples", value: "\(audio.aiBufferStatus.sampleCount) / \(AIInputFormat.capacity)")
                LabeledContent("Bytes", value: "\(audio.aiBufferStatus.byteCount)")
                diagnosticValue("Duration", audio.aiBufferStatus.duration, unit: "s")
                LabeledContent("Converted total", value: "\(audio.aiBufferStatus.totalConvertedSamples) samples")
                if let error = audio.errorMessage { Text(error).foregroundStyle(.red) }
            }
            Section(language.text("diagnostics.network")) {
                LabeledContent("Server (poll)", value: devices.pollingStatus == "Active" ? "Connected" : devices.pollingStatus)
                LabeledContent("Registration", value: devices.registration)
                LabeledContent("RMS reporting", value: devices.rmsStatus)
                LabeledContent("Command polling", value: devices.pollingStatus)
                LabeledContent("Auto sync", value: devices.autoStatus == nil ? "Unavailable" : "Synced")
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    diagnosticValue("Last successful contact", devices.lastSuccessfulContactUptime.map {
                        max(0, ProcessInfo.processInfo.systemUptime - $0)
                    }, unit: "s ago")
                }
                if let error = devices.lastNetworkError { Text("Last network error: \(error)").foregroundStyle(.red) }
                if let error = devices.networkError { Text(error).foregroundStyle(.red) }
                if let error = network.errorMessage { Text(error).foregroundStyle(.red) }
                LabeledContent("Device ID", value: "\(devices.deviceID.prefix(8))…")
            }
            Section(language.text("main.direction")) {
                Text(language.position(devices.direction?.direction))
                if let direction = devices.direction {
                    diagnosticValue("Margin", direction.marginDB, unit: "dB")
                    Text(direction.detail)
                }
            }
            Section(language.text("diagnostics.auto")) {
                LabeledContent("Auto", value: devices.autoStatus.map { $0.enabled ? "On" : "Off" } ?? "Unavailable")
                LabeledContent("State", value: devices.autoStatus?.state.replacingOccurrences(of: "_", with: " ") ?? "Unavailable")
                if let status = devices.autoStatus {
                    diagnosticValue("Trigger", status.trigger_dbfs, unit: "dBFS")
                    diagnosticValue("Rearm below", status.release_dbfs, unit: "dBFS")
                    diagnosticValue("Cooldown remaining", status.cooldown_remaining_ms)
                    LabeledContent("Armed", value: status.armed ? "yes" : "no")
                    LabeledContent("Waiting for quiet", value: status.waiting_for_quiet == true ? "yes" : "no")
                    diagnosticValue("Quiet observed", status.quiet_elapsed_ms)
                    diagnosticValue("Quiet required", status.rearm_quiet_ms)
                    if let active = status.active_event {
                        LabeledContent("Current source", value: language.position(active.source_role))
                    }
                }
                if let message = devices.autoMessage { Text(message) }
            }
            if let event = devices.autoStatus?.last_event {
                Section(language.text("diagnostics.lastEvent")) {
                    LabeledContent("Source", value: language.position(event.source_role))
                    LabeledContent("Outcome", value: event.outcome.replacingOccurrences(of: "_", with: " "))
                    LabeledContent("Direction", value: language.position(event.direction))
                    if let result = event.result {
                        LabeledContent("Label", value: language.soundLabel(result.label))
                        diagnosticValue("Confidence", result.confidence * 100, unit: "%")
                    }
                }
            }
            if let event = devices.autoStatus?.active_event ?? devices.autoStatus?.last_event {
                Section(language.text("diagnostics.timing")) {
                    LabeledContent("Event", value: String(event.event_id.prefix(8)))
                    LabeledContent("Source", value: language.position(event.source_role))
                    diagnosticValue("Trigger RMS", event.trigger_rms_dbfs, unit: "dBFS")
                    LabeledContent("Reason", value: event.trigger_reason ?? "Unavailable")
                    Text("Timestamps: ms since this bridge started").foregroundStyle(.secondary)
                    ForEach(["triggered", "snapshot_requested", "snapshot_received", "inference_started", "inference_completed"], id: \.self) { key in
                        diagnosticValue(key.replacingOccurrences(of: "_", with: " "), event.timestamps_ms?[key])
                    }
                    if let timing = event.latency {
                        diagnosticValue("Trigger → command queued", timing.trigger_to_command_ms)
                        diagnosticValue("Command queued → audio received", timing.command_to_audio_ms)
                        diagnosticValue("Audio → inference start", timing.audio_to_inference_start_ms)
                        diagnosticValue("Inference (server)", timing.inference_ms)
                        diagnosticValue("Total event", timing.total_event_ms)
                    }
                }
            }
            Section {
                NavigationLink(language.text("developer.title")) { destination(.developerTools) }
            }
        }
    }

    private var developerTools: some View {
        Group {
            Section(language.text("developer.snapshotServer")) {
                Button(language.text("developer.testConnection")) { network.testConnection() }
                    .disabled(network.isBusy)
                Button(language.text("developer.sendSnapshot")) { network.sendSnapshot(from: audio) }
                    .disabled(!audio.aiBufferStatus.isReady || checkingSnapshot || network.isBusy)
                Button(language.text("developer.checkSnapshot")) { checkSnapshot() }
                    .disabled(!audio.aiBufferStatus.isReady || checkingSnapshot || network.isBusy)
                if checkingSnapshot { ProgressView(language.text("developer.checking")) }
                if let snapshotInfo { Text(snapshotInfo).monospacedDigit() }
                manualRequestState
            }
            if let result = network.result {
                Section(language.text("developer.manualResult")) {
                    LabeledContent("Label", value: language.soundLabel(result.label))
                    diagnosticValue("Confidence", result.confidence * 100, unit: "%")
                    diagnosticValue("Inference", result.inferenceMilliseconds)
                    LabeledContent("Direction", value: language.position(result.direction))
                    diagnosticValue("Direction margin", result.directionMarginDB, unit: "dB")
                }
            }
            Section(language.text("developer.vibration")) {
                Button(language.text("developer.testHaptic")) { haptics.play() }
                    .disabled(!haptics.isSupported)
                LabeledContent("Haptic", value: haptics.isSupported ? haptics.status : "Unsupported")
                Button(language.text("developer.testDirectionHaptic")) { devices.testDirectionHaptic() }
                    .disabled(!devices.isRegistered || devices.testingDirection || network.isBusy)
                if let result = devices.testResult { Text(result) }
                if let error = devices.networkError { Text(error).foregroundStyle(.red) }
                if let error = haptics.errorMessage { Text("Haptic error: \(error)").foregroundStyle(.red) }
            }
        }
    }

    private var manualRequestState: some View {
        Group {
            LabeledContent(language.text("developer.lastRequest"), value: language.connectionStatus(network.connectionStatus))
            if network.isBusy {
                ProgressView(network.isSending ? language.text("developer.sending") : language.text("developer.connecting"))
                Button(language.text("developer.cancel")) { network.cancel() }
            }
            if let error = network.errorMessage { Text(error).foregroundStyle(.red) }
        }
    }

    private func diagnosticValue(_ label: String, _ value: Double?, unit: String = "ms") -> some View {
        // A vertical fallback keeps long technical names readable with accessibility text sizes.
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(label)
                Spacer(minLength: 16)
                Text(value.map { String(format: "%.1f %@", $0, unit) } ?? "—").monospacedDigit()
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                Text(value.map { String(format: "%.1f %@", $0, unit) } ?? "—")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func checkSnapshot() {
        checkingSnapshot = true
        snapshotTask = Task {
            guard !Task.isCancelled, operatingMode == .fallback else { return }
            let snapshot = await audio.makeAIInputSnapshot()
            guard !Task.isCancelled, operatingMode == .fallback else { return }
            if let snapshot {
                snapshotInfo = "\(snapshot.sampleCount) samples / \(snapshot.byteCount) bytes / "
                    + String(format: "%.3f s", snapshot.duration)
            }
            checkingSnapshot = false
        }
    }

    private func cancelSnapshotCheck() {
        snapshotTask?.cancel()
        snapshotTask = nil
        checkingSnapshot = false
        snapshotInfo = nil
    }
}
