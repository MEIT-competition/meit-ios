import SwiftUI

@MainActor
struct HardwareModeView: View {
    @ObservedObject var audio: AudioCaptureManager
    @ObservedObject var network: NetworkManager
    let isCaptureRequested: Bool
    let onStartCapture: () -> Void
    let onStopCapture: () -> Void
    @Environment(\.appLanguage) private var language
    @State private var showingDiagnostics = false
    @State private var showingSettings = false

    private var isCapturing: Bool {
        audio.captureOwner == .wearableMode && audio.isCapturing
    }

    private var listeningTitle: String {
        if audio.microphonePermission == .denied { return language.text("main.permission.title") }
        if isCaptureRequested && !isCapturing { return language.text("main.starting.title") }
        return language.text(isCapturing ? "main.listening.title" : "wearable.waiting")
    }

    private var serverSummary: String {
        let address = network.configuredServerAddress
        guard !address.isEmpty else { return language.text("settings.required") }
        let connected = network.wearable.connectionStatus == "Connected"
        return "\(address) · \(language.text(connected ? "status.connected" : "status.notConnected"))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(isCapturing ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(listeningTitle).font(.title2.weight(.semibold))
                    }
                    Text(language.text("hardware.description")).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                LiveAudioView(rmsDBFS: audio.rmsDBFS, isCapturing: isCapturing)

                VStack(alignment: .leading, spacing: 16) {
                    LabeledContent(language.text("wearable.audioInput"), value: language.text("wearable.iPhoneMicrophone"))
                    LabeledContent(language.text("wearable.aiServer")) {
                        Text(serverSummary).multilineTextAlignment(.trailing)
                    }
                    LabeledContent(language.text("hardware.wearable"), value: language.text("status.notConnected"))
                    Text(language.text("wearable.ai.note")).font(.subheadline).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent(language.text("main.direction"), value: language.text(audio.wearableMic.direction.localizationKey))
                    Text(language.text("wearable.experimentalNote")).font(.subheadline).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(language.text("main.result.automatic")).font(.subheadline).foregroundStyle(.secondary)
                    if let result = network.wearable.result {
                        Text("\(language.soundLabel(result.label)) · \(language.text("main.confidence", result.confidence * 100))")
                            .font(.title3)
                        Text(language.text((WearableDirection(rawValue: result.direction ?? "") ?? .unavailable).localizationKey))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(language.text("main.result.placeholder")).foregroundStyle(.secondary)
                    }
                    if network.wearable.inFlight { Text(language.text("wearable.ai.inFlight")).foregroundStyle(.secondary) }
                    if let key = network.wearable.errorKey { Text(language.text(key)).foregroundStyle(.secondary) }
                }
                if audio.microphonePermission == .denied {
                    Text(language.text("main.permission.subtitle")).foregroundStyle(.secondary)
                }
                if audio.errorMessage != nil {
                    Text(language.text("main.microphoneError")).foregroundStyle(.red)
                }
                Divider()
                Button { showingDiagnostics = true } label: {
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                if isCaptureRequested { onStopCapture() }
                else { onStartCapture() }
            } label: {
                Text(language.text(isCaptureRequested ? "main.stop" : "main.start"))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityHint(language.text(isCaptureRequested ? "wearable.stopHint" : "wearable.startHint"))
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.background)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSettings = true } label: {
                    Image(systemName: "gearshape").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(language.text("settings.title"))
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                List {
                    ServerSettingsSection(network: network) {
                        Text(serverSummary).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
                .navigationTitle(language.text("settings.title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(language.text("common.done")) { showingSettings = false }
                    }
                }
            }
            .environment(\.appLanguage, language)
            .environment(\.locale, language.locale)
        }
        .onAppear { audio.refreshPermission() }
        .sheet(isPresented: $showingDiagnostics) {
            NavigationStack {
                WearableDiagnosticsView(audio: audio, network: network)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(language.text("common.done")) { showingDiagnostics = false }
                        }
                    }
            }
            .environment(\.appLanguage, language)
            .environment(\.locale, language.locale)
        }
    }
}
