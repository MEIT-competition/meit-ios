import SwiftUI

struct HardwareModeView: View {
    // TODO: Connect meit-ee/ESP32-S3, hardware direction and AI result synchronization.
    // TODO: Add motor status/test and system start/stop when the hardware protocol is defined.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("wearable").font(.headline)
                    Text("not connected").font(.title2.weight(.semibold))
                    Text("Hardware integration is not available yet.")
                        .foregroundStyle(.secondary)
                }
                Text("Your iPhone does not listen or vibrate in hardware mode.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }
}
