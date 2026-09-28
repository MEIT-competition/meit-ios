import SwiftUI

@MainActor
struct ContentView: View {
    @StateObject private var audio = AudioCaptureManager()
    @Environment(\.scenePhase) private var scenePhase

    private var microphoneStatus: String {
        if audio.microphonePermission == .denied { return "Permission Denied" }
        if audio.isCapturing { return "Capturing" }
        if audio.isStarting { return "Requesting / Starting" }
        return "Ready"
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("MEIT iOS")
                .font(.title)
            Text("Microphone: \(microphoneStatus)")
            Text("Permission: \(audio.microphonePermission.rawValue)")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("RMS")
                Text(String(format: "%.1f dBFS", audio.rmsDBFS))
                    .font(.largeTitle.monospacedDigit())
                if let format = audio.inputFormatDescription {
                    Text(format)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button("Start Capture") {
                Task { await audio.startCapture() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(audio.isCapturing || audio.isStarting)

            Button("Stop Capture") {
                audio.stopCapture()
            }
            .buttonStyle(.bordered)
            .disabled(!audio.isCapturing && !audio.isStarting)

            if let error = audio.errorMessage {
                Text("Error: \(error)")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .onAppear { audio.refreshPermission() }
        .onDisappear { audio.stopCapture() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                audio.stopCapture()
            } else if phase == .active {
                audio.refreshPermission()
            }
        }
    }
}
