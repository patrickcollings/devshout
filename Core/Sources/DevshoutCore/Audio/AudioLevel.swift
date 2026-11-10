import Foundation

/// The loudness of a buffer, for the recording overlay's level meter.
public struct AudioLevel: Sendable, Hashable {
    /// Root mean square of the samples, 0…1.
    public var rms: Float
    /// Largest absolute sample, 0…1 (clipped samples count as 1).
    public var peak: Float

    public init(rms: Float, peak: Float) {
        self.rms = rms
        self.peak = peak
    }

    public static let silent = AudioLevel(rms: 0, peak: 0)

    /// Measures `samples`. An empty buffer is silent.
    public static func measure(_ samples: [Float]) -> AudioLevel {
        samples.withUnsafeBufferPointer { measure($0) }
    }

    public static func measure(_ samples: UnsafeBufferPointer<Float>) -> AudioLevel {
        guard !samples.isEmpty else { return .silent }
        var sumOfSquares: Double = 0
        var peak: Float = 0
        for sample in samples where !sample.isNaN {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
            sumOfSquares += Double(sample) * Double(sample)
        }
        let rms = Float((sumOfSquares / Double(samples.count)).squareRoot())
        return AudioLevel(rms: min(rms, 1), peak: min(peak, 1))
    }

    /// RMS in dBFS, floored at `floor` (silence would otherwise be −∞).
    public func rmsDecibels(floor: Float = -80) -> Float { Self.decibels(rms, floor: floor) }
    public func peakDecibels(floor: Float = -80) -> Float { Self.decibels(peak, floor: floor) }

    /// RMS mapped to 0…1 on a decibel scale from `floor` dBFS (0) to 0 dBFS (1): what a meter bar should show.
    /// Speech usually sits around −30 to −10 dBFS, so the default floor of −60 leaves room either side.
    public func meterValue(floor: Float = -60) -> Float {
        guard floor < 0 else { return rms }
        let db = rmsDecibels(floor: floor)
        return min(max((db - floor) / -floor, 0), 1)
    }

    static func decibels(_ amplitude: Float, floor: Float) -> Float {
        guard amplitude > 0 else { return floor }
        return max(20 * log10(amplitude), floor)
    }
}

/// Smooths meter values so the bar rises quickly and falls slowly, as hardware meters do.
public struct LevelSmoother: Sendable, Hashable {
    /// Fraction of the gap closed per update when the level rises (0…1; 1 = jump straight there).
    public var attack: Float
    /// Fraction of the gap closed per update when the level falls.
    public var release: Float
    public private(set) var value: Float = 0

    public init(attack: Float = 0.6, release: Float = 0.15) {
        self.attack = attack
        self.release = release
    }

    /// Feeds a new meter value (0…1) and returns the smoothed one.
    @discardableResult
    public mutating func update(_ target: Float) -> Float {
        let clamped = min(max(target.isNaN ? 0 : target, 0), 1)
        let factor = clamped > value ? attack : release
        value += (clamped - value) * factor
        return value
    }

    public mutating func reset() { value = 0 }
}
