import Foundation

// Pure transition policy. Stop completion means backend/PCM drain AND session cleanup finished.
struct CaptureLifecycle {
    enum Phase: String { case idle, starting, capturing, stopping }
    private(set) var phase: Phase = .idle

    mutating func beginStart() -> Bool {
        guard phase == .idle else { return false }
        phase = .starting
        return true
    }
    mutating func didStart() { if phase == .starting { phase = .capturing } }
    mutating func beginStop() { phase = .stopping }
    mutating func finishStop() { phase = .idle }
}

struct MicrophoneRestoreReport {
    struct Issue {
        let field: String
        let code: String
        let message: String
        let essential: Bool
    }
    var issues: [Issue] = []
    var orientationTarget = "—"
    var orientationResult = "not attempted"
    var restoredPreferredOrientation = "—"
    var blocksCapture: Bool { issues.contains { $0.essential } }
    var result: String { blocksCapture ? "failed" : (issues.isEmpty ? "success" : "completed with warning") }
    var summary: String { issues.map { "\($0.field): \($0.message) [\($0.code)]" }.joined(separator: "; ") }

    mutating func record(_ field: String, error: Error, essential: Bool) {
        let error = error as NSError
        issues.append(Issue(field: field, code: "\(error.domain) \(error.code)",
                            message: error.localizedDescription, essential: essential))
    }
}

// Last cycle only; survives resetting the live stereo readings on Stop.
struct MicrophoneLifecycleDiagnostics {
    var lastStop = "not run"
    var restore = MicrophoneRestoreReport()
    var lastRestore = "not run"
    var savedPreferred = "—"
    var savedActual = "—"
    var startedPreferred = "—"
    var startedActual = "—"
    var stoppedPreferred = "—"
    var stoppedActual = "—"
    var restoreContext = "—"
}
