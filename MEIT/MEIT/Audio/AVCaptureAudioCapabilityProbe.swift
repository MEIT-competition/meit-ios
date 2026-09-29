import AVFoundation
import Foundation

// Separate from WearableMicState: capability of an unattached input is not active stereo PCM.
struct AVCaptureAudioCapabilities: Sendable {
    enum Status: String, Sendable {
        case notChecked, checking, requiresIOS18, permissionRequired, permissionDenied
        case inputUnavailable, failed, complete
        var localizationKey: String { "wearable.captureProbe.\(rawValue)" }
    }

    var status: Status = .notChecked
    var inputAvailable: Bool?
    var stereoSupported: Bool?
    var spatialAudioSupported: Bool?
    var currentMode: String?
    var errorMessage: String?
}

enum AVCaptureAudioCapabilityProbe {
    static func inspect() async -> AVCaptureAudioCapabilities {
        // Create/release AVFoundation objects off the UI/audio threads; return only scalar values.
        await Task.detached(priority: .utility) {
            autoreleasepool { readInputCapabilities() }
        }.value
    }

    private static func readInputCapabilities() -> AVCaptureAudioCapabilities {
        guard #available(iOS 18.0, *) else {
            return AVCaptureAudioCapabilities(status: .requiresIOS18)
        }
        // Diagnostics never requests permission or starts a recording. Use the existing Start flow.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined: return AVCaptureAudioCapabilities(status: .permissionRequired)
        case .denied, .restricted: return AVCaptureAudioCapabilities(status: .permissionDenied)
        @unknown default: return AVCaptureAudioCapabilities(status: .permissionDenied)
        }
        // On iOS this is a logical audio device; the audio routing subsystem selects the physical mic.
        guard let device = AVCaptureDevice.default(.microphone, for: .audio, position: .unspecified) else {
            return AVCaptureAudioCapabilities(status: .inputUnavailable, inputAvailable: false)
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            // Read-only input probe: no AVCaptureSession/output, mode assignment or AVAudioSession changes.
            // https://developer.apple.com/documentation/avfoundation/avcapturedeviceinput/ismultichannelaudiomodesupported(_:)
            let stereo = input.isMultichannelAudioModeSupported(.stereo)
            let spatial = input.isMultichannelAudioModeSupported(.firstOrderAmbisonics)
            let mode: String
            switch input.multichannelAudioMode {
            case .none: mode = "none"
            case .stereo: mode = "stereo"
            case .firstOrderAmbisonics: mode = "firstOrderAmbisonics"
            @unknown default: mode = "unknown (\(input.multichannelAudioMode.rawValue))"
            }
            return AVCaptureAudioCapabilities(status: .complete, inputAvailable: true,
                stereoSupported: stereo, spatialAudioSupported: spatial, currentMode: mode)
        } catch {
            // Unknown capability is not false: failed input creation cannot prove lack of support.
            return AVCaptureAudioCapabilities(status: .failed, inputAvailable: false,
                errorMessage: error.localizedDescription)
        }
    }
}
