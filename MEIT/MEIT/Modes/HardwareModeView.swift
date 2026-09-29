import SwiftUI

struct HardwareModeView: View {
    // TODO: Connect meit-ee/ESP32-S3, hardware direction and AI result synchronization.
    // TODO: Add motor status/test and system start/stop when the hardware protocol is defined.
    // No fallback managers, transport or simulated state belong in this UI shell.
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Hardware Mode").font(.title2)
                GroupBox("Wearable Hardware") {
                    LabeledContent("Status", value: "Not Connected")
                }
                GroupBox("AI") {
                    VStack(spacing: 8) {
                        LabeledContent("Status", value: "Not Connected")
                        LabeledContent("Result", value: "—")
                    }
                }
                LabeledContent("Direction", value: "—")
                GroupBox("Hardware Status") {
                    VStack(spacing: 8) {
                        LabeledContent("ESP32", value: "Not Connected")
                        LabeledContent("Microphones", value: "—")
                        LabeledContent("Motors", value: "—")
                    }
                }
                Text("Hardware integration pending")
                    .foregroundStyle(.secondary)
                Button("Connect Hardware") { }
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
                Button("Test Motors") { }
                    .buttonStyle(.bordered)
                    .disabled(true)
            }
            .padding()
        }
    }
}
