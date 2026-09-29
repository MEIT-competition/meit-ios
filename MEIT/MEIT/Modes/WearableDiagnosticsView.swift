import SwiftUI

@MainActor
struct WearableDiagnosticsView: View {
    @ObservedObject var audio: AudioCaptureManager
    @Environment(\.appLanguage) private var language
    private var state: WearableMicState { audio.wearableMic }

    private var inputFormat: String {
        // Report observed buffer channels, not the requested stereo configuration.
        switch state.bufferChannels {
        case 1: return language.text("wearable.mono")
        case 2...: return language.text("wearable.stereo")
        default: return language.text("wearable.waiting")
        }
    }

    private var directionAvailable: Bool {
        state.stereoUsable && state.physicalMappingVerified && state.direction != .unavailable
    }

    var body: some View {
        List {
            Section {
                LabeledContent(language.text("wearable.summary.audioInput"), value: language.text("wearable.iPhoneMicrophone"))
                LabeledContent(language.text("wearable.inputFormat"), value: inputFormat)
                LabeledContent(language.text("wearable.aiBuffer"), value: language.text(state.audioReady ? "wearable.ready" : "wearable.preparing"))
                LabeledContent(language.text("wearable.directionSensing"), value: language.text(directionAvailable ? "wearable.available" : "wearable.unavailable"))
            }
            Section {
                NavigationLink {
                    WearableAdvancedDiagnosticsView(audio: audio)
                } label: {
                    Text(language.text("wearable.advancedDiagnostics"))
                }
            }
        }
        .navigationTitle(language.text("diagnostics.title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
private struct WearableAdvancedDiagnosticsView: View {
    @ObservedObject var audio: AudioCaptureManager
    @State private var captureCapabilities = AVCaptureAudioCapabilities()
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
                value("wearable.nodeChannels", language.text("wearable.avcapture.noInputNode"))
                value("wearable.bufferChannels", "\(state.bufferChannels)")
                value("wearable.stereoUsable", language.text(state.stereoUsable ? "wearable.available" : "wearable.unavailable"))
                if !state.stereoUsable {
                    Text(language.text("wearable.stereoUnavailable")).foregroundStyle(.secondary)
                }
            }
            Section(language.text("wearable.captureProbe.title")) {
                Text(language.text(captureCapabilities.status.localizationKey)).foregroundStyle(.secondary)
                value("wearable.captureProbe.input", capabilityText(captureCapabilities.inputAvailable))
                value("wearable.captureProbe.stereo", capabilityText(captureCapabilities.stereoSupported))
                value("wearable.captureProbe.spatial", capabilityText(captureCapabilities.spatialAudioSupported))
                value("wearable.captureProbe.mode", captureCapabilities.currentMode ?? language.text("wearable.captureProbe.notChecked"))
                Text(language.text("wearable.captureProbe.note")).foregroundStyle(.secondary)
                if let error = captureCapabilities.errorMessage { Text(error).foregroundStyle(.red) }
            }
            Section(language.text("wearable.dataSourceCatalog")) {
                if state.availableDataSources.isEmpty {
                    Text(language.text("wearable.noDataSourceSnapshot")).foregroundStyle(.secondary)
                }
                ForEach(state.availableDataSources) { source in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(source.name).font(.headline)
                        value("wearable.sourceLocation", source.location)
                        value("wearable.sourceOrientation", source.orientation)
                        value("wearable.supportedPatterns", source.supportedPatterns)
                        value("wearable.sourceStereoSupport", language.text(source.supportsStereo ? "wearable.available" : "wearable.unavailable"))
                    }
                }
            }
            Section(language.text("wearable.inputConfiguration")) {
                value("wearable.sessionCategory", state.sessionCategory)
                value("wearable.sessionMode", state.sessionMode)
                value("wearable.avcapture.activeMode", state.activeMultichannelMode)
                value("wearable.orientation.requested", state.captureSession?.requestedOrientation ?? "—")
                value("wearable.avcapture.usesAppSession", capabilityText(state.captureSession?.usesAppAudioSession))
                value("wearable.avcapture.autoConfiguresSession", capabilityText(state.captureSession?.autoConfiguresAudioSession))
                if let pcm = state.capturePCM {
                    value("wearable.avcapture.sampleRate", "\(pcm.sampleRate) Hz")
                    value("wearable.avcapture.pcmFormat", pcm.formatSummary)
                    value("wearable.layout.tag", pcm.channelLayout.tag)
                    value("wearable.layout.channel0", pcm.channelLayout.channel0Label)
                    value("wearable.layout.channel1", pcm.channelLayout.channel1Label)
                    Text(language.text("wearable.layout.note")).foregroundStyle(.secondary)
                    value("wearable.avcapture.interleaving", language.text(pcm.interleaved ? "wearable.avcapture.interleaved" : "wearable.avcapture.planar"))
                }
                value("wearable.preferredChannels", "\(state.preferredChannels)")
                value("wearable.supportedPatterns", state.supportedPatterns)
                value("wearable.selectedPattern", state.selectedPattern)
                value("wearable.preferredOrientation", state.preferredOrientation)
                value("wearable.actualOrientation", state.actualOrientation)
                value("wearable.orientation.confirmed", capabilityText(state.captureSession == nil ? nil : state.portraitOrientationConfirmed))
                if let note = state.configurationNote { Text(note).foregroundStyle(.secondary) }
            }
            Section(language.text("wearable.channelLevels")) {
                level("wearable.channel1RMS", state.channel1RMS)
                level("wearable.channel1Peak", state.channel1Peak)
                level("wearable.channel2RMS", state.channel2RMS)
                level("wearable.channel2Peak", state.channel2Peak)
                value("wearable.channelDelta", state.channelDeltaDB.map { language.text("wearable.channelDelta.value", $0) } ?? "—")
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
        .navigationTitle(language.text("wearable.advancedDiagnostics"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: audio.microphonePermission.rawValue) {
            captureCapabilities = AVCaptureAudioCapabilities(status: .checking)
            let result = await AVCaptureAudioCapabilityProbe.inspect()
            guard !Task.isCancelled else { return }
            captureCapabilities = result
        }
    }

    private func capabilityText(_ supported: Bool?) -> String {
        guard let supported else { return language.text("wearable.captureProbe.notChecked") }
        return supported ? "true" : "false"
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
