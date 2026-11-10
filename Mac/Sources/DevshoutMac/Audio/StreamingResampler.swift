// Mono Float32 at any rate → 16 kHz mono Float32, using AVAudioConverter, for live capture and file import.
//
// Unsure on macOS (not compiled in CI yet):
// - That AVAudioConverter returns .inputRanDry after the input block answers .noDataNow, and keeps its resampler
//   state between convert calls (documented behaviour; FluidAudio relies on the .endOfStream variant).
// - The exact tail length flushed by finish() (a few milliseconds of resampler latency).
import AVFoundation
import DevshoutCore
import Foundation
import os

public enum StreamingResamplerError: Error, LocalizedError {
    case invalidInputRate(Double)
    case couldNotCreateFormat
    case couldNotCreateConverter
    case couldNotCreateBuffer
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInputRate(let rate): return "The audio input reported an invalid sample rate (\(rate) Hz)."
        case .couldNotCreateFormat: return "Couldn't describe the audio format for conversion."
        case .couldNotCreateConverter: return "Couldn't create an audio converter."
        case .couldNotCreateBuffer: return "Couldn't allocate an audio buffer."
        case .conversionFailed(let message): return "Audio conversion failed: \(message)"
        }
    }
}

/// Streams mono samples at `inputRate` through AVAudioConverter to 16 kHz. Not thread-safe: use from one queue.
/// When the input is already 16 kHz it passes samples straight through.
public final class StreamingResampler {
    public let inputRate: Double
    public let outputRate = Double(AudioFormat.sampleRate)

    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private var finished = false

    /// Largest number of input frames handed to the converter at once.
    private static let sliceFrames = 1 << 16

    public init(inputRate: Double) throws {
        guard inputRate.isFinite, inputRate > 0 else { throw StreamingResamplerError.invalidInputRate(inputRate) }
        self.inputRate = inputRate
        guard
            let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false),
            let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioFormat.sampleRate),
                                             channels: 1, interleaved: false)
        else { throw StreamingResamplerError.couldNotCreateFormat }
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        if inputRate == Double(AudioFormat.sampleRate) {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw StreamingResamplerError.couldNotCreateConverter
            }
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            self.converter = converter
        }
    }

    /// Converts the next stretch of input. Output lags input by the converter's latency; `finish()` flushes it.
    public func process(_ samples: [Float]) throws -> [Float] {
        guard !samples.isEmpty, !finished else { return [] }
        guard let converter else { return samples }
        var output: [Float] = []
        output.reserveCapacity(Int(Double(samples.count) * outputRate / inputRate) + 64)
        var start = 0
        while start < samples.count {
            let end = min(start + Self.sliceFrames, samples.count)
            let input = try makeInputBuffer(samples[start..<end])
            try run(converter, input: input, endOfStream: false, into: &output)
            start = end
        }
        return output
    }

    /// Flushes what the converter still holds. Further `process` calls return nothing.
    public func finish() -> [Float] {
        guard !finished else { return [] }
        finished = true
        guard let converter else { return [] }
        var output: [Float] = []
        do {
            try run(converter, input: nil, endOfStream: true, into: &output)
        } catch {
            // Losing a few milliseconds of tail is harmless.
        }
        return output
    }

    /// One-shot conversion of a whole signal.
    public static func resample(_ samples: [Float], from inputRate: Double) throws -> [Float] {
        let resampler = try StreamingResampler(inputRate: inputRate)
        return try resampler.process(samples) + resampler.finish()
    }

    private func makeInputBuffer(_ samples: ArraySlice<Float>) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData
        else { throw StreamingResamplerError.couldNotCreateBuffer }
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress {
                channel[0].update(from: base, count: src.count)
            }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    /// Feeds `input` (once) and drains everything the converter can produce from it.
    private func run(_ converter: AVAudioConverter, input: AVAudioPCMBuffer?, endOfStream: Bool,
                     into output: inout [Float]) throws {
        let inputFrames = Int(input?.frameLength ?? 0)
        let capacity = AVAudioFrameCount(max(4096, Int((Double(inputFrames) * outputRate / inputRate).rounded(.up)) + 1024))
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw StreamingResamplerError.couldNotCreateBuffer
        }

        // The converter calls the block synchronously inside convert(...).
        let supplied = OSAllocatedUnfairLock(initialState: input == nil)
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            let alreadySupplied = supplied.withLock { state -> Bool in
                let previous = state
                state = true
                return previous
            }
            if !alreadySupplied, let input {
                status.pointee = .haveData
                return input
            }
            status.pointee = endOfStream ? .endOfStream : .noDataNow
            return nil
        }

        var error: NSError?
        while true {
            out.frameLength = 0
            let status = converter.convert(to: out, error: &error, withInputFrom: inputBlock)
            if status == .error {
                throw StreamingResamplerError.conversionFailed(error?.localizedDescription ?? "unknown error")
            }
            if out.frameLength > 0, let channel = out.floatChannelData {
                output.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
            }
            // .haveData means the output buffer filled up and there is more to come.
            if status != .haveData { break }
        }
    }
}

extension AVAudioPCMBuffer {
    /// The buffer's frames as mono Float32, averaging channels. Handles float, Int16 and Int32 sample data,
    /// interleaved or not. Returns [] for an empty or unreadable buffer.
    func monoFloatSamples() -> [Float] {
        let frames = Int(frameLength)
        let channels = Int(format.channelCount)
        guard frames > 0, channels > 0 else { return [] }
        let interleaved = format.isInterleaved
        let scale = 1 / Float(channels)
        var mono = [Float](repeating: 0, count: frames)

        func mix(_ read: (_ channel: Int, _ frame: Int) -> Float) {
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += read(channel, frame) }
                mono[frame] = channels == 1 ? sum : sum * scale
            }
        }

        if let data = floatChannelData {
            if interleaved {
                mix { channel, frame in data[0][frame * channels + channel] }
            } else {
                mix { channel, frame in data[channel][frame] }
            }
        } else if let data = int16ChannelData {
            if interleaved {
                mix { channel, frame in Float(data[0][frame * channels + channel]) / 32_768 }
            } else {
                mix { channel, frame in Float(data[channel][frame]) / 32_768 }
            }
        } else if let data = int32ChannelData {
            if interleaved {
                mix { channel, frame in Float(Double(data[0][frame * channels + channel]) / 2_147_483_648) }
            } else {
                mix { channel, frame in Float(Double(data[channel][frame]) / 2_147_483_648) }
            }
        } else {
            return []
        }
        return mono
    }
}
