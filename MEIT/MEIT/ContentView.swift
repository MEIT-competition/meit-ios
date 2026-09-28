import SwiftUI

@MainActor
struct ContentView: View {
    @StateObject private var audio = AudioCaptureManager()
    @StateObject private var network = NetworkManager()
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
                    .disabled(!audio.aiBufferStatus.isReady || checkingSnapshot || network.isBusy)
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
                    network.cancel()
                    audio.stopCapture()
                }
                .buttonStyle(.bordered)
                .disabled(!audio.isCapturing && !audio.isStarting)

                if let error = audio.errorMessage {
                    Text("Error: \(error)")
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                Divider()
                serverControls
            }
            .padding()
        }
        .onAppear { audio.refreshPermission() }
        .onDisappear {
            audio.stopCapture()
            network.cancel()
        }
        .onChange(of: audio.isCapturing) { _, capturing in
            snapshotInfo = nil
            if !capturing { network.cancel() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                audio.stopCapture()
                network.cancel()
            } else if phase == .active {
                audio.refreshPermission()
            }
        }
    }

    private var serverControls: some View {
        VStack(spacing: 12) {
            Text("AI Server").font(.headline)
            HStack {
                TextField("Windows private IPv4", text: $network.serverAddress)
                    .keyboardType(.decimalPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .disabled(network.isBusy)
                Text(": 8765")
            }
            Text("Connection: \(network.connectionStatus)")
            Button("Test Connection") { network.testConnection() }
                .disabled(network.isBusy)
            Button("Send Snapshot") { network.sendSnapshot(from: audio) }
                .buttonStyle(.borderedProminent)
                .disabled(!audio.aiBufferStatus.isReady || checkingSnapshot || network.isBusy)
            if network.isBusy {
                ProgressView(network.isSending ? "Sending..." : "Testing Connection...")
                Button("Cancel Request") { network.cancel() }
            }
            if let result = network.result {
                Text("AI Result").font(.headline)
                Text("Label: \(result.label)")
                Text(String(format: "Confidence: %.1f%%", result.confidence * 100))
                Text(String(format: "Inference: %.1f ms", result.inferenceMilliseconds))
            }
            if let error = network.errorMessage {
                Text("Network Error: \(error)")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
