import Foundation

// Standalone production-code tests; NOT part of an Xcode test target or current Actions workflow.
// swiftc MEIT/MEIT/Audio/StereoDirectionEstimator.swift Tests/StereoDirectionEstimatorTests.swift -o <temporary executable>
@main
struct StereoDirectionEstimatorTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    // Resolve pow/log round-off toward the tested inclusive boundary by at most a few ULPs.
    static func leftAmplitude(delta: Double) -> Double {
        var left = 0.1 * pow(10, delta / 20)
        for _ in 0..<16 {
            let actual = 20 * (log10(left) - log10(0.1))
            if delta >= 0 && actual < delta { left = left.nextUp }
            else if delta < 0 && actual > delta { left = left.nextDown }
            else {
                expect(abs(actual - delta) < 1e-12, "boundary reconstruction")
                return left
            }
        }
        preconditionFailure("could not construct threshold input")
    }

    static func main() {
        // alpha=1 isolates hysteresis through the public update API. Default EMA is tested below.
        var direct = StereoDirectionConfiguration()
        direct.smoothingAlpha = 1
        var estimator = StereoDirectionEstimator(configuration: direct)
        let sequence: [(Double, WearableDirection)] = [
            (0.6, .center), (0.7, .left), (0.6, .left), (0.5, .left), (0.49, .center),
            (-0.6, .center), (-0.7, .right), (-0.6, .right), (-0.5, .right), (-0.49, .center)
        ]
        for (delta, expected) in sequence {
            expect(estimator.update(leftRMS: leftAmplitude(delta: delta), rightRMS: 0.1,
                                    stereoUsable: true) == expected, "hysteresis sequence \(delta)")
            expect(estimator.state == expected, "published state")
        }
        expect(estimator.update(leftRMS: 0.2, rightRMS: 0.1, stereoUsable: true) == .left, "enter left")
        expect(estimator.update(leftRMS: 0.1, rightRMS: 0.2, stereoUsable: true) == .center, "left must release through center")
        expect(estimator.update(leftRMS: 0.1, rightRMS: 0.2, stereoUsable: true) == .right, "then enter right")
        expect(estimator.update(leftRMS: 0.2, rightRMS: 0.1, stereoUsable: true) == .center, "right must release through center")
        expect(estimator.update(leftRMS: 0.2, rightRMS: 0.1, stereoUsable: true) == .left, "then enter left")

        // Exact computed boundaries also verify >= and <= without decimal reconstruction.
        var exact = direct
        exact.enterThresholdDB = 20 * (log10(0.2) - log10(0.1))
        exact.releaseThresholdDB = 20 * (log10(0.11) - log10(0.1))
        expect(StereoDirectionEstimator.classify(leftRMS: 0.2, rightRMS: 0.1, configuration: exact) == .left, "inclusive enter left")
        expect(StereoDirectionEstimator.classify(leftRMS: 0.1, rightRMS: 0.2, configuration: exact) == .right, "inclusive enter right")
        expect(StereoDirectionEstimator.classify(leftRMS: 0.11, rightRMS: 0.1, configuration: exact, previousState: .left) == .left, "inclusive release left")
        expect(StereoDirectionEstimator.classify(leftRMS: 0.1, rightRMS: 0.11, configuration: exact, previousState: .right) == .right, "inclusive release right")

        var smoothed = StereoDirectionEstimator()
        expect(smoothed.update(leftRMS: 0.1, rightRMS: 0.1, stereoUsable: true) == .center, "EMA initial center")
        let left = leftAmplitude(delta: 1.0)
        expect(smoothed.update(leftRMS: left, rightRMS: 0.1, stereoUsable: true) == .center, "raw 1 dB does not bypass EMA")
        let expectedDelta = 20 * (log10(0.1 + 0.25 * (left - 0.1)) - log10(0.1))
        expect(abs((smoothed.smoothedDeltaDB ?? .nan) - expectedDelta) < 1e-12, "linear RMS EMA then dB difference")
        for _ in 0..<12 { _ = smoothed.update(leftRMS: left, rightRMS: 0.1, stereoUsable: true) }
        expect(smoothed.state == .left, "sustained level crosses entry")
        for _ in 0..<12 {
            expect(smoothed.update(leftRMS: leftAmplitude(delta: 0.6), rightRMS: 0.1, stereoUsable: true) == .left, "stable in hysteresis band")
        }
        expect(smoothed.update(leftRMS: 0, rightRMS: 0, stereoUsable: true) == .unavailable, "silence clears immediately")
        expect(smoothed.smoothedDeltaDB == nil, "silence clears delta")
        expect(smoothed.update(leftRMS: 0.1, rightRMS: 1, stereoUsable: true) == .right, "no stale EMA after silence")
        expect(smoothed.update(leftRMS: 1, rightRMS: 0.1, stereoUsable: false) == .unavailable, "mono or semantic gate loss clears history")
        expect(smoothed.smoothedDeltaDB == nil, "gate loss clears delta")
        expect(smoothed.update(leftRMS: 1, rightRMS: 0.1, stereoUsable: true) == .left, "fresh after gate reset")
        expect(smoothed.update(leftRMS: 0.00001, rightRMS: 0.000001, stereoUsable: true) == .unavailable, "quiet imbalance")
        let floor = pow(10, StereoDirectionConfiguration().silenceDBFS / 20)
        expect(smoothed.update(leftRMS: floor, rightRMS: 0, stereoUsable: true) == .unavailable, "exact silence threshold")
        for invalid in [Double.nan, .infinity, -.infinity, -0.1] {
            expect(smoothed.update(leftRMS: invalid, rightRMS: 0.1, stereoUsable: true) == .unavailable, "invalid left")
            expect(smoothed.update(leftRMS: 0.1, rightRMS: invalid, stereoUsable: true) == .unavailable, "invalid right")
        }
        expect(smoothed.update(leftRMS: 0.1, rightRMS: 0, stereoUsable: true) == .left, "zero right channel")
        expect(smoothed.smoothedDeltaDB?.isFinite == true, "zero channel delta is finite")
        smoothed.reset()
        expect(smoothed.state == .unavailable && smoothed.smoothedDeltaDB == nil, "explicit reset")
        var invalid = direct
        invalid.releaseThresholdDB = invalid.enterThresholdDB
        expect(StereoDirectionEstimator.classify(leftRMS: 1, rightRMS: 0.1, configuration: invalid) == .unavailable, "invalid hysteresis range")
        invalid = direct
        invalid.enterThresholdDB = .nan
        expect(StereoDirectionEstimator.classify(leftRMS: 1, rightRMS: 0.1, configuration: invalid) == .unavailable, "invalid threshold")
        invalid = direct
        invalid.smoothingAlpha = 0
        var badEMA = StereoDirectionEstimator(configuration: invalid)
        expect(badEMA.update(leftRMS: 1, rightRMS: 0.1, stereoUsable: true) == .unavailable, "invalid EMA")
        expect(StereoDirectionEstimator.dbFS(.nan) == -100, "finite meter output")
        print("PASS: hysteresis, inclusive boundaries, no direct reversal, EMA, silence, invalid input, reset")
    }
}
