import SwiftUI

@MainActor
struct WearableDiagnosticsView: View {
    @ObservedObject var audio: AudioCaptureManager
    @Environment(\.appLanguage) private var language
    private var state: WearableMicState { audio.wearableMic }

    var body: some View {
        List {
            Section(language.text("wearable.stereoInput")) {
                value("wearable.audioInput", language.text("wearable.iPhoneMicrophone"))
                value("wearable.inputPort", state.inputPort)
                value("wearable.dataSource", state.dataSource)
                value("wearable.maximumChannels", "\(state.maximumChannels)")
                value("wearable.actualChannels", "\(state.sessionChannels)")
                value("wearable.nodeChannels", "\(state.nodeChannels)")
                value("wearable.bufferChannels", "\(state.bufferChannels)")
                value("wearable.stereoUsable", language.text(state.stereoUsable ? "wearable.available" : "wearable.unavailable"))
                if !state.stereoUsable {
                    Text(language.text("wearable.stereoUnavailable")).foregroundStyle(.secondary)
                }
            }
            Section(language.text("wearable.inputConfiguration")) {
                value("wearable.supportedPatterns", state.supportedPatterns)
                value("wearable.selectedPattern", state.selectedPattern)
                value("wearable.preferredOrientation", state.preferredOrientation)
                value("wearable.actualOrientation", state.actualOrientation)
                if let note = state.configurationNote { Text(note).foregroundStyle(.secondary) }
            }
            Section(language.text("wearable.channelLevels")) {
                level("wearable.channel1RMS", state.channel1RMS)
                level("wearable.channel1Peak", state.channel1Peak)
                level("wearable.channel2RMS", state.channel2RMS)
                level("wearable.channel2Peak", state.channel2Peak)
                value("wearable.channelDominance", language.text(state.channelDominance.localizationKey))
                value("wearable.logicalMapping", language.text("wearable.mappingUnverified"))
                value("wearable.estimatedDirection", language.text(state.direction.localizationKey))
                Text(language.text("wearable.experimentalNote")).foregroundStyle(.secondary)
                Text(language.text("wearable.testInstructions")).foregroundStyle(.secondary)
            }
            Section(language.text("diagnostics.audio")) {
                value("wearable.aiReady", language.text(state.audioReady ? "wearable.ready" : "wearable.notReady"))
                Text("16000 Hz / mono / PCM16LE / 2.5 s")
                Text("\(audio.aiBufferStatus.sampleCount) / \(AIInputFormat.capacity) samples")
                Text(language.text("wearable.localOnly")).foregroundStyle(.secondary)
                if let error = audio.errorMessage { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle(language.text("diagnostics.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func value(_ key: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(language.text(key))
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func level(_ key: String, _ amplitude: Double?) -> some View {
        value(key, amplitude.map { language.text("wearable.level", StereoDirectionEstimator.dbFS($0)) } ?? "—")
    }
}
