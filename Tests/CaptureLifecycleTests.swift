import Foundation

// Standalone production policy tests; no Xcode test target and NOT run by current Actions.
// swiftc MEIT/MEIT/Audio/CaptureLifecycle.swift Tests/CaptureLifecycleTests.swift -o <temporary executable>
@main
struct CaptureLifecycleTests {
    static func main() {
        var state = CaptureLifecycle()
        for _ in 0..<5 {
            precondition(state.beginStart())
            precondition(!state.beginStart(), "duplicate Start must not configure a second backend")
            state.didStart()
            precondition(state.phase == .capturing)
            state.beginStop()
            precondition(!state.beginStart(), "Start cannot bypass Stop/drain/restore completion")
            state.finishStop()
            precondition(state.phase == .idle)
        }
        precondition(state.beginStart())
        state.beginStop() // Immediate Stop while still starting.
        state.didStart() // A stale completion cannot promote stopping to capturing.
        precondition(state.phase == .stopping)
        precondition(!state.beginStart())
        state.finishStop()
        precondition(state.beginStart())

        let rejected = NSError(domain: NSOSStatusErrorDomain, code: -50)
        var optional = MicrophoneRestoreReport()
        optional.record("setPreferredInputOrientation", error: rejected, essential: false)
        precondition(!optional.blocksCapture)
        precondition(optional.result == "completed with warning")
        precondition(optional.summary.contains("-50"))
        var required = MicrophoneRestoreReport()
        required.record("category/mode", error: rejected, essential: true)
        precondition(required.blocksCapture)
        precondition(required.result == "failed")
        print("Capture lifecycle/restore policy assertions passed")
    }
}
