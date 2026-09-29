import Foundation

// Standalone production-code tests. No iOS SDK, package manager, or third-party dependency.
// swiftc MEIT/MEIT/Audio/StereoDirectionEstimator.swift Tests/StereoDirectionEstimatorTests.swift -o <temporary executable>
@main
struct StereoDirectionEstimatorTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func main() {
        expect(StereoDirectionEstimator.classify(leftRMS: 0.3, rightRMS: 0.03) == .left, "strong left")
        expect(StereoDirectionEstimator.classify(leftRMS: 0.03, rightRMS: 0.3) == .right, "strong right")
        expect(StereoDirectionEstimator.classify(leftRMS: 0.1, rightRMS: 0.11) == .center, "near equal")
        expect(StereoDirectionEstimator.classify(leftRMS: 0, rightRMS: 0) == .unavailable, "silence")
        expect(StereoDirectionEstimator.classify(leftRMS: 0.00001, rightRMS: 0.000001) == .unavailable, "quiet imbalance is not a direction")
        for invalid in [Double.nan, .infinity, -.infinity, -0.1] {
            expect(StereoDirectionEstimator.classify(leftRMS: invalid, rightRMS: 0.1) == .unavailable, "invalid left")
            expect(StereoDirectionEstimator.classify(leftRMS: 0.1, rightRMS: invalid) == .unavailable, "invalid right")
        }
        var config = StereoDirectionConfiguration()
        // Use the exact computed difference to test strict boundary semantics without pow rounding.
        config.marginDB = 20 * (log10(0.2) - log10(0.1))
        expect(StereoDirectionEstimator.classify(leftRMS: 0.2, rightRMS: 0.1, configuration: config) == .center, "positive boundary")
        expect(StereoDirectionEstimator.classify(leftRMS: 0.1, rightRMS: 0.2, configuration: config) == .center, "negative boundary")
        config.marginDB -= 0.000001
        expect(StereoDirectionEstimator.classify(leftRMS: 0.2, rightRMS: 0.1, configuration: config) == .left, "beyond margin")
        expect(StereoDirectionEstimator.classify(leftRMS: 0.1, rightRMS: 0.2, configuration: config) == .right, "beyond negative margin")
        config.marginDB = .nan
        expect(StereoDirectionEstimator.classify(leftRMS: 0.2, rightRMS: 0.1, configuration: config) == .unavailable, "invalid configuration")

        var estimator = StereoDirectionEstimator()
        expect(estimator.update(leftRMS: 1, rightRMS: 0.1, stereoUsable: true) == .left, "initial reading")
        expect(estimator.update(leftRMS: 0.1, rightRMS: 1, stereoUsable: true) == .left, "smooth a single reversal")
        expect(estimator.update(leftRMS: 0, rightRMS: 0, stereoUsable: true) == .unavailable, "quiet clears history immediately")
        expect(estimator.update(leftRMS: 0.1, rightRMS: 1, stereoUsable: true) == .right, "fresh reading after silence")
        expect(estimator.update(leftRMS: 1, rightRMS: 0.1, stereoUsable: false) == .unavailable, "mono clears history")
        expect(estimator.update(leftRMS: 1, rightRMS: 0.1, stereoUsable: true) == .left, "fresh reading after mono")
        expect(StereoDirectionEstimator.dbFS(.nan) == -100, "finite meter output")
        print("PASS: strong left/right, near equal, silence, invalid values, threshold boundaries, smoothing/reset")
    }
}
