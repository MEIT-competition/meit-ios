import SwiftUI

@MainActor
struct HardwareModeView: View {
    @ObservedObject var audio: AudioCaptureManager
    @Binding var backupEnabled: Bool
    @Environment(\.appLanguage) private var language
    @State private var showingDiagnostics = false

    private var backupCapturing: Bool {
        audio.captureOwner == .wearableBackup && audio.isCapturing
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(language.text("hardware.wearable")).font(.headline)
                    Text(language.text("status.notConnected")).font(.title2.weight(.semibold))
                    Text(language.text("hardware.pending")).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text(language.text("wearable.audioInput")).font(.headline)
                    Text(language.text(backupEnabled ? "wearable.backupInput" : "wearable.primaryInput"))
                    Toggle(language.text("wearable.useMicrophone"), isOn: $backupEnabled)
                    if audio.captureOwner == .wearableBackup && audio.isStarting {
                        Text(language.text("main.starting.subtitle")).foregroundStyle(.secondary)
                    }
                    Text(language.text("hardware.description")).font(.subheadline).foregroundStyle(.secondary)
                }
                if backupEnabled {
                    LiveAudioView(rmsDBFS: audio.rmsDBFS, isCapturing: backupCapturing)
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent(language.text("wearable.stereoInput"), value:
                            language.text(audio.wearableBackup.stereoUsable ? "wearable.available" : "wearable.unavailable"))
                        LabeledContent(language.text("wearable.estimatedDirection"), value:
                            language.text(audio.wearableBackup.direction.localizationKey))
                        Text(language.text("wearable.experimentalNote")).font(.subheadline).foregroundStyle(.secondary)
                    }
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
        .onAppear { audio.refreshPermission() }
        .sheet(isPresented: $showingDiagnostics) {
            NavigationStack {
                WearableDiagnosticsView(audio: audio)
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
