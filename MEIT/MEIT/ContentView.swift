import SwiftUI

@MainActor
struct ContentView: View {
    @StateObject private var audio = AudioCaptureManager()
    @StateObject private var network = NetworkManager()
    @StateObject private var devices = DeviceCoordinator()
    @StateObject private var haptics = HapticManager()
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
                Divider()
                deviceControls
            }
            .padding()
        }
        .onAppear { audio.refreshPermission() }
        .onDisappear {
            devices.disconnect()
            haptics.stop()
            audio.stopCapture()
            network.cancel()
        }
        .onChange(of: audio.isCapturing) { _, capturing in
            snapshotInfo = nil
            if !capturing { network.cancel() }
        }
        .onChange(of: network.serverAddress) { _, _ in devices.disconnect() }
        .onChange(of: network.connectionStatus) { _, status in
            if status == "Connected", scenePhase == .active {
                devices.connect(network: network, audio: audio, haptics: haptics)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                devices.disconnect()
                haptics.stop()
            }
            if phase == .background {
                audio.stopCapture()
                network.cancel()
            } else if phase == .active {
                audio.refreshPermission()
                if network.connectionStatus == "Connected" {
                    devices.connect(network: network, audio: audio, haptics: haptics)
                }
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
                Text("AI Direction: \(result.direction?.uppercased() ?? "UNKNOWN")")
                if let margin = result.directionMarginDB {
                    Text(String(format: "AI Direction Margin: %.1f dB", margin))
                }
            }
            if let error = network.errorMessage {
                Text("Network Error: \(error)")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var deviceControls: some View {
        VStack(spacing: 12) {
            Text("Device").font(.headline)
            Picker("Device Role", selection: $devices.role) {
                ForEach(DeviceRole.allCases, id: \.self) { role in
                    Text(role.rawValue.uppercased()).tag(role)
                }
            }
            .pickerStyle(.menu)
            Text("Device ID: \(devices.deviceID.prefix(8))...").font(.caption)
            Text("Registration: \(devices.registration)")
            Text("RMS: \(devices.rmsStatus)").font(.caption)
            Text("Direction").font(.headline)
            Text(devices.direction?.direction.uppercased() ?? "UNKNOWN")
            if let direction = devices.direction {
                if let margin = direction.marginDB {
                    Text(String(format: "Margin: %.1f dB", margin))
                }
                Text(direction.detail).font(.caption)
            }
            Button("Test Haptic") { haptics.play() }
                .disabled(!haptics.isSupported)
            Text("Haptic: \(haptics.isSupported ? haptics.status : "Unsupported")")
                .font(.caption)
            Button("Test Direction + Haptic") { devices.testDirectionHaptic() }
                .disabled(!devices.isRegistered || devices.testingDirection || network.isBusy)
            if let result = devices.testResult { Text(result).font(.caption) }
            if let error = devices.networkError { Text(error).foregroundStyle(.red) }
            if let error = haptics.errorMessage { Text("Haptic Error: \(error)").foregroundStyle(.red) }
        }
    }
}
