import SwiftUI

// Display only: uses the existing published RMS, never PCM or a second audio owner.
struct LiveAudioView: View {
    let rmsDBFS: Double
    let isCapturing: Bool
    @Environment(\.appLanguage) private var language

    private var safeDBFS: Double {
        guard isCapturing, rmsDBFS.isFinite else { return -100 }
        return min(0, max(-100, rmsDBFS))
    }

    private var level: Double {
        guard isCapturing else { return 0 }
        // Visual scale only: <= -60 -> 0, -30 -> 0.5, -10 -> 0.83, 0 -> 1.
        return min(1, max(0, (safeDBFS + 60) / 60))
    }

    private var roundedDBFS: Double {
        let rounded = safeDBFS.rounded()
        return rounded == 0 ? 0 : rounded // Avoid displaying or speaking negative zero.
    }

    private var spokenValue: String {
        guard isCapturing else { return language.text("liveAudio.inactive") }
        return roundedDBFS < 0
            ? language.text("liveAudio.voiceover.negative", abs(roundedDBFS))
            : language.text("liveAudio.voiceover.zero")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(language.text("main.liveAudio")).font(.headline)
            ProgressView(value: level, total: 1)
                .progressViewStyle(.linear)
                .tint(.primary)
            Text(isCapturing ? language.text("liveAudio.reading", roundedDBFS) : "— dBFS")
                .monospacedDigit()
            Text(language.text(isCapturing ? "liveAudio.active" : "liveAudio.inactive"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        // No live announcements at the RMS update rate; VoiceOver reads on focus.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(language.text("liveAudio.accessibilityLabel"))
        .accessibilityValue(spokenValue)
    }
}
