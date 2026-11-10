import Foundation

/// A simple, dependency-free resampler for files that are not already 16 kHz (live capture uses AVAudioConverter).
///
/// Upsampling interpolates linearly between neighbouring samples. Downsampling averages the source over each output
/// sample's span (a box filter, then the average), which takes the edge off aliasing without a full FIR filter. Both
/// are O(n) and good enough for speech recognition, which only needs up to 8 kHz of bandwidth.
public enum LinearResampler {
    /// Output length for `count` input samples: `count × to / from`, rounded down.
    public static func outputCount(forInputCount count: Int, from sourceRate: Int, to targetRate: Int) -> Int {
        guard sourceRate > 0, targetRate > 0, count > 0 else { return 0 }
        return Int((Int64(count) * Int64(targetRate)) / Int64(sourceRate))
    }

    public static func resample(_ samples: [Float], from sourceRate: Int, to targetRate: Int) -> [Float] {
        guard sourceRate > 0, targetRate > 0 else { return [] }
        if sourceRate == targetRate { return samples }
        let outCount = outputCount(forInputCount: samples.count, from: sourceRate, to: targetRate)
        guard outCount > 0 else { return [] }
        let step = Double(sourceRate) / Double(targetRate)
        return step < 1
            ? interpolate(samples, step: step, count: outCount)
            : average(samples, step: step, count: outCount)
    }

    static func interpolate(_ x: [Float], step: Double, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        let last = x.count - 1
        x.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for i in 0..<count {
                    let position = Double(i) * step
                    let k = min(Int(position), last)
                    let frac = Float(position - Double(k))
                    let a = src[k]
                    let b = src[min(k + 1, last)]
                    dst[i] = a + (b - a) * frac
                }
            }
        }
        return out
    }

    /// Box-filtered decimation: output i is the mean of the source (as a step function) over
    /// [i·step − step/2, i·step + step/2], clipped to the signal.
    static func average(_ x: [Float], step: Double, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        let n = x.count
        x.withUnsafeBufferPointer { src in
            // Running integral of the step function up to `t`, with t only ever increasing.
            var k = 0
            var sumToK = 0.0
            func integral(to t: Double) -> Double {
                let whole = min(Int(t), n)
                while k < whole {
                    sumToK += Double(src[k])
                    k += 1
                }
                guard k < n else { return sumToK }
                return sumToK + (t - Double(k)) * Double(src[k])
            }

            var start = 0.0
            var startIntegral = 0.0
            var previous: Float = n > 0 ? src[0] : 0
            out.withUnsafeMutableBufferPointer { dst in
                for i in 0..<count {
                    let end = min(max((Double(i) + 0.5) * step, 0), Double(n))
                    let endIntegral = integral(to: end)
                    let width = end - start
                    let value = width > 0 ? Float((endIntegral - startIntegral) / width) : previous
                    dst[i] = value
                    previous = value
                    start = end
                    startIntegral = endIntegral
                }
            }
        }
        return out
    }
}
