import Foundation

// Experimental defaults, not calibrated danger/AI thresholds. Amplitudes are linear RMS.
struct StereoDirectionConfiguration: Sendable {
    var marginDB = 3.0
    var silenceDBFS = -65.0
    var smoothingAlpha = 0.25
}

enum WearableDirection: String, Sendable {
    case left, right, center, unavailable

    var localizationKey: String { "wearable.direction.\(rawValue)" }
}

// No audio/session/UI dependency. Left/right refer to logical channels, not verified physical sides.
struct StereoDirectionEstimator {
    let configuration: StereoDirectionConfiguration
    private var smoothedLeft: Double?
    private var smoothedRight: Double?

    init(configuration: StereoDirectionConfiguration = .init()) {
        self.configuration = configuration
    }

    mutating func reset() {
        smoothedLeft = nil
        smoothedRight = nil
    }

    mutating func update(leftRMS: Double, rightRMS: Double, stereoUsable: Bool) -> WearableDirection {
        guard stereoUsable, Self.valid(leftRMS), Self.valid(rightRMS),
              configuration.smoothingAlpha.isFinite,
              (0...1).contains(configuration.smoothingAlpha), configuration.smoothingAlpha > 0,
              Self.classify(leftRMS: leftRMS, rightRMS: rightRMS, configuration: configuration) != .unavailable else {
            // Quiet/invalid input immediately clears old direction instead of decaying through CENTER.
            reset()
            return .unavailable
        }
        let alpha = configuration.smoothingAlpha
        let left = smoothedLeft.map { $0 + alpha * (leftRMS - $0) } ?? leftRMS
        let right = smoothedRight.map { $0 + alpha * (rightRMS - $0) } ?? rightRMS
        smoothedLeft = left
        smoothedRight = right
        return Self.classify(leftRMS: left, rightRMS: right, configuration: configuration)
    }

    static func classify(leftRMS: Double, rightRMS: Double,
                         configuration: StereoDirectionConfiguration = .init()) -> WearableDirection {
        guard valid(leftRMS), valid(rightRMS), configuration.marginDB.isFinite,
              configuration.marginDB > 0, configuration.silenceDBFS.isFinite,
              configuration.silenceDBFS < 0 else { return .unavailable }
        let floor = pow(10, configuration.silenceDBFS / 20)
        guard max(leftRMS, rightRMS) > floor else { return .unavailable }
        if leftRMS == 0 { return .right }
        if rightRMS == 0 { return .left }
        // 20 log10(L) - 20 log10(R) == 20 log10(L/R); never multiply dB values.
        let difference = 20 * (log10(leftRMS) - log10(rightRMS))
        if difference > configuration.marginDB { return .left }
        if difference < -configuration.marginDB { return .right }
        return .center
    }

    static func dbFS(_ amplitude: Double) -> Double {
        guard valid(amplitude) else { return -100 }
        return min(0, max(-100, 20 * log10(max(amplitude, 0.00001))))
    }

    private static func valid(_ value: Double) -> Bool { value.isFinite && value >= 0 }
}
