import Foundation

// Wearable experimental defaults from device trials, not AI thresholds or physical calibration.
struct StereoDirectionConfiguration: Sendable {
    var enterThresholdDB = 0.7
    var releaseThresholdDB = 0.5
    var silenceDBFS = -65.0
    var smoothingAlpha = 0.25
}

enum WearableDirection: String, Sendable {
    case left, right, center, unavailable

    var localizationKey: String { "wearable.direction.\(rawValue)" }
}

// No audio/session/UI dependency. The caller must gate unverified stream semantics.
struct StereoDirectionEstimator {
    let configuration: StereoDirectionConfiguration
    private var smoothedLeft: Double?
    private var smoothedRight: Double?
    private(set) var state: WearableDirection = .unavailable
    private(set) var smoothedDeltaDB: Double?

    init(configuration: StereoDirectionConfiguration = .init()) {
        self.configuration = configuration
    }

    mutating func reset() {
        smoothedLeft = nil
        smoothedRight = nil
        smoothedDeltaDB = nil
        state = .unavailable
    }

    mutating func update(leftRMS: Double, rightRMS: Double, stereoUsable: Bool) -> WearableDirection {
        guard stereoUsable, Self.signalIsUsable(leftRMS, rightRMS, configuration),
              configuration.smoothingAlpha.isFinite,
              (0...1).contains(configuration.smoothingAlpha), configuration.smoothingAlpha > 0 else {
            // Raw silence/invalid input clears history immediately, without EMA decay.
            reset()
            return state
        }
        let alpha = configuration.smoothingAlpha
        let left = smoothedLeft.map { $0 + alpha * (leftRMS - $0) } ?? leftRMS
        let right = smoothedRight.map { $0 + alpha * (rightRMS - $0) } ?? rightRMS
        guard Self.signalIsUsable(left, right, configuration) else {
            reset()
            return state
        }
        smoothedLeft = left
        smoothedRight = right
        smoothedDeltaDB = Self.deltaDB(left, right)
        state = Self.classify(leftRMS: left, rightRMS: right,
                              configuration: configuration, previousState: state)
        return state
    }

    // One hysteresis step on already-smoothed RMS. update() is the production entry point.
    static func classify(leftRMS: Double, rightRMS: Double,
                         configuration: StereoDirectionConfiguration = .init(),
                         previousState: WearableDirection = .center) -> WearableDirection {
        guard signalIsUsable(leftRMS, rightRMS, configuration) else { return .unavailable }
        let difference = deltaDB(leftRMS, rightRMS)
        switch previousState {
        case .left:
            return difference >= configuration.releaseThresholdDB ? .left : .center
        case .right:
            return difference <= -configuration.releaseThresholdDB ? .right : .center
        case .center, .unavailable:
            if difference >= configuration.enterThresholdDB { return .left }
            if difference <= -configuration.enterThresholdDB { return .right }
            return .center
        }
    }

    private static func signalIsUsable(_ left: Double, _ right: Double,
                                       _ configuration: StereoDirectionConfiguration) -> Bool {
        guard valid(left), valid(right), configuration.enterThresholdDB.isFinite,
              configuration.releaseThresholdDB.isFinite, configuration.releaseThresholdDB >= 0,
              configuration.enterThresholdDB > configuration.releaseThresholdDB,
              configuration.silenceDBFS.isFinite, configuration.silenceDBFS < 0 else { return false }
        return max(left, right) > pow(10, configuration.silenceDBFS / 20)
    }

    private static func deltaDB(_ left: Double, _ right: Double) -> Double {
        // Difference of dB levels of EMA-smoothed LINEAR RMS, not subtraction of amplitudes.
        // The existing -100 dBFS meter floor handles a zero channel; the silence gate is separate.
        20 * (log10(max(left, 0.00001)) - log10(max(right, 0.00001)))
    }

    static func dbFS(_ amplitude: Double) -> Double {
        guard valid(amplitude) else { return -100 }
        return min(0, max(-100, 20 * log10(max(amplitude, 0.00001))))
    }

    private static func valid(_ value: Double) -> Bool { value.isFinite && value >= 0 }
}
