import SwiftUI

@MainActor
struct ContentView: View {
    @StateObject private var audio = AudioCaptureManager()
    @Environment(\.scenePhase) private var scenePhase
    @State private var snapshotInfo: String?
    @State private var checkingSnapshot = false

    private var microphoneStatus: String {
        if audio.microphonePermission == .denied { return "Permission Denied" }
        if audio.isCapturing { return "Capturing" }
        if audio.isStarting { return "Requesting / Starting" }
        return "Ready"
    }

    var body: some View {
        ScrollView {
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
                    Text("Native Input")
                    Text(audio.inputFormatDescription ?? "—")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 8) {
                    Text("AI Input")
                    Text("16000 Hz / mono / PCM16 (little-endian)")
                        .font(.caption)
                    Text("AI Buffer")
                    Text("\(audio.aiBufferStatus.sampleCount) / \(AIInputFormat.capacity) samples")
                    Text("\(audio.aiBufferStatus.byteCount) bytes")
                    Text(String(format: "%.3f s", audio.aiBufferStatus.duration))
                    Text(audio.aiBufferStatus.isReady ? "AI Buffer Ready" : (audio.isCapturing ? "Buffering..." : "Stopped"))
                    Text("Converted total: \(audio.aiBufferStatus.totalConvertedSamples) samples")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Check Snapshot") {
                        checkingSnapshot = true
                        Task {
                            if let snapshot = await audio.makeAIInputSnapshot() {
                                snapshotInfo = "\(snapshot.sampleCount) samples / \(snapshot.byteCount) bytes / "
                                    + String(format: "%.3f s", snapshot.duration)
                            }
                            checkingSnapshot = false
                        }
                    }
                    .disabled(!audio.aiBufferStatus.isReady || checkingSnapshot)
                    if let snapshotInfo {
                        Text("Snapshot: \(snapshotInfo)")
                            .font(.caption)
                    }
                }
                .monospacedDigit()

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
        }
        .onAppear { audio.refreshPermission() }
        .onDisappear { audio.stopCapture() }
        .onChange(of: audio.isCapturing) { _, _ in snapshotInfo = nil }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                audio.stopCapture()
            } else if phase == .active {
                audio.refreshPermission()
            }
        }
    }
}
