import SwiftUI

struct HardwareModeView: View {
    @Environment(\.appLanguage) private var language
    // TODO: Connect meit-ee/ESP32-S3, hardware direction and AI result synchronization.
    // TODO: Add motor status/test and system start/stop when the hardware protocol is defined.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(language.text("hardware.wearable")).font(.headline)
                    Text(language.text("status.notConnected")).font(.title2.weight(.semibold))
                    Text(language.text("hardware.pending"))
                        .foregroundStyle(.secondary)
                }
                Text(language.text("hardware.description"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }
}
