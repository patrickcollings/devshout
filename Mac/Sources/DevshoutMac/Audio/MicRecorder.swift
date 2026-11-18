// Microphone capture with AVAudioEngine → 16 kHz mono Float32 → WAV on disk first, then the AsyncStream.
//
// Unsure on macOS (not compiled in CI yet):
// - Setting kAudioOutputUnitProperty_CurrentDevice on the input node's audio unit before reading its format is
//   the usual way to pick a non-default input with AVAudioEngine; it needs checking with a USB mic and AirPods.
// - Whether AVAudioEngineConfigurationChange always arrives with the engine already stopped (Apple says it does).
//   Others report a spurious change ~100 ms after starting with a pinned device, so changes where the device and
//   format are unchanged are ignored (or just restart the engine), and rebuilds are capped at 4 per 5 s.
// - kAudioDevicePropertyDeviceIsAlive firing when a pinned USB mic is unplugged (we then pin the default).
// - The tap's real buffer size (AVAudioEngine may ignore the 4,096 we ask for).
import AudioToolbox
import AVFoundation
import CoreAudio
import DevshoutCore
import Foundation
import os

public enum MicRecorderError: Error, LocalizedError, Equatable {
    case microphoneNotAuthorised
    case alreadyRecording
    case notRecording
    case noInputDevice
    case couldNotSelectDevice(uid: String, status: OSStatus)
    case engineFailed(String)

    public var errorDescription: String? {
        switch self {
        case .microphoneNotAuthorised:
            return "devshout doesn't have permission to use the microphone. Allow it in System Settings → Privacy & Security → Microphone."
        case .alreadyRecording:
            return "A recording is already in progress."
        case .notRecording:
            return "No recording is in progress."
        case .noInputDevice:
            return "No microphone is available."
        case .couldNotSelectDevice(let uid, let status):
            return "Couldn't switch to the selected microphone (\(uid), error \(status))."
        case .engineFailed(let message):
            return "The audio engine couldn't start: \(message)"
        }
    }
}

/// Records the microphone to a 16 kHz mono 16-bit WAV and streams the same samples (16 kHz mono Float32).
///
/// Every buffer is written to the file *before* it is yielded to the stream or measured for the level meter.
/// All state lives on one serial queue; the tap callback only mixes the hardware buffer to mono and hands it over.
public final class MicRecorder: AudioRecorder, @unchecked Sendable {
    private let logger = Logger(subsystem: "app.devshout.mac", category: "MicRecorder")
    private let queue = DispatchQueue(label: "app.devshout.mac.mic", qos: .userInitiated)

    // Settings, read when a recording starts. Guarded by `settingsLock`.
    private let settingsLock = NSLock()
    private var _deviceUID: String?
    private var _levelHandler: (@Sendable (AudioLevel) -> Void)?

    // Recording state. Only touched on `queue`.
    private var engine: AVAudioEngine?
    private var writer: WavFileWriter?
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var resampler: StreamingResampler?
    private var configurationObserver: NSObjectProtocol?
    private var _writeError: Error?
    private var _activeDevice: AudioInputDevice?
    /// What the current tap was installed for, to tell real configuration changes from spurious ones.
    private var tapSignature: TapSignature?
    /// Whether this engine's input unit has been pointed at a device explicitly.
    private var pinnedDevice = false
    private var aliveWatch: (deviceID: AudioDeviceID, block: AudioObjectPropertyListenerBlock)?
    private var recentRebuilds: [Date] = []
    private var rebuildRetryScheduled = false

    private struct TapSignature: Equatable {
        var deviceID: AudioDeviceID?
        var sampleRate: Double
        var channels: AVAudioChannelCount
    }

    /// - Parameters:
    ///   - deviceUID: Core Audio UID of the input to use; nil (or a device that has gone) means the system default.
    ///   - levelHandler: Called on the recorder's queue with the level of each buffer, after it has been written.
    public init(deviceUID: String? = nil, levelHandler: (@Sendable (AudioLevel) -> Void)? = nil) {
        _deviceUID = deviceUID
        _levelHandler = levelHandler
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    /// The input to use from the next `start` on. Nil = system default.
    public var deviceUID: String? {
        get { settingsLock.lock(); defer { settingsLock.unlock() }; return _deviceUID }
        set { settingsLock.lock(); defer { settingsLock.unlock() }; _deviceUID = newValue }
    }

    /// Receives the level of every buffer (on the recorder's queue: hop to the main actor for UI).
    public var levelHandler: (@Sendable (AudioLevel) -> Void)? {
        get { settingsLock.lock(); defer { settingsLock.unlock() }; return _levelHandler }
        set { settingsLock.lock(); defer { settingsLock.unlock() }; _levelHandler = newValue }
    }

    /// The input device in use (nil when idle, or when Core Audio couldn't name it).
    /// Don't read these three from `levelHandler`: they sync on the recorder's queue, where the handler runs.
    public var activeDevice: AudioInputDevice? { queue.sync { _activeDevice } }

    /// The first disk error of the current or last recording. Samples are still streamed when writing fails,
    /// so the transcript survives a full disk; the pipeline should flag the recording.
    public var writeError: Error? { queue.sync { _writeError } }

    public var isRecording: Bool { queue.sync { engine != nil } }

    // MARK: AudioRecorder

    public func start(writingTo fileURL: URL) async throws -> AsyncStream<[Float]> {
        switch MicrophonePermission.status {
        case .authorised:
            break
        case .notDetermined:
            guard await MicrophonePermission.request() else { throw MicRecorderError.microphoneNotAuthorised }
        case .denied, .restricted:
            throw MicRecorderError.microphoneNotAuthorised
        }
        return try await withCheckedThrowingContinuation { (result: CheckedContinuation<AsyncStream<[Float]>, Error>) in
            queue.async {
                do {
                    result.resume(returning: try self.startOnQueue(fileURL))
                } catch {
                    result.resume(throwing: error)
                }
            }
        }
    }

    public func stop() async throws -> TimeInterval {
        try await withCheckedThrowingContinuation { (result: CheckedContinuation<TimeInterval, Error>) in
            queue.async {
                guard self.engine != nil else {
                    result.resume(throwing: MicRecorderError.notRecording)
                    return
                }
                self.stopEngineOnQueue()
                // Buffers the tap handed over before it was removed are queued behind this block: let them be
                // written before closing the file.
                self.queue.async {
                    result.resume(returning: self.finishOnQueue())
                }
            }
        }
    }

    public func cancel() async {
        _ = try? await stop()
    }

    // MARK: Queue-confined work

    private func startOnQueue(_ fileURL: URL) throws -> AsyncStream<[Float]> {
        guard engine == nil else { throw MicRecorderError.alreadyRecording }

        let writer = try WavFileWriter(url: fileURL)
        let engine = AVAudioEngine()
        let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
        self.writer = writer
        self.continuation = continuation
        self.engine = engine
        _writeError = nil
        pinnedDevice = false
        tapSignature = nil
        recentRebuilds = []
        rebuildRetryScheduled = false

        do {
            try installTap(on: engine)
            engine.prepare()
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            try? writer.close()
            try? FileManager.default.removeItem(at: fileURL)
            continuation.finish()
            self.engine = nil
            self.writer = nil
            self.continuation = nil
            self.resampler = nil
            _activeDevice = nil
            if error is MicRecorderError || error is StreamingResamplerError { throw error }
            throw MicRecorderError.engineFailed(error.localizedDescription)
        }

        watchActiveDevice()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.handleConfigurationChange(for: engine) }
        }
        logger.info("Recording started: \(fileURL.lastPathComponent, privacy: .public)")
        return stream
    }

    /// Picks the input device, builds a resampler for the input's current format and installs the tap.
    private func installTap(on engine: AVAudioEngine, pinDefault: Bool = false) throws {
        let input = engine.inputNode
        _activeDevice = try selectDevice(on: input, pinDefault: pinDefault)

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicRecorderError.noInputDevice }
        let resampler = try StreamingResampler(inputRate: format.sampleRate)
        self.resampler = resampler
        tapSignature = TapSignature(deviceID: Self.currentDeviceID(of: input) ?? _activeDevice?.deviceID,
                                    sampleRate: format.sampleRate, channels: format.channelCount)
        logger.info("Input format: \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch")

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            // Audio thread: copy out as mono and get off it.
            let mono = buffer.monoFloatSamples()
            guard !mono.isEmpty, let self else { return }
            self.queue.async { self.handleCaptured(mono, resampler: resampler) }
        }
    }

    /// The device the input should use: the selected one when it's connected, else the system default.
    /// `nil` device ID means "leave the unit alone" (no selection, never pinned, nothing forced).
    private func desiredDevice(pinDefault: Bool) -> (device: AudioInputDevice?, pin: Bool) {
        let defaultDevice = AudioInputDevices.defaultDevice()
        if let uid = deviceUID {
            if let device = AudioInputDevices.device(withUID: uid) { return (device, true) }
            logger.notice("Selected input \(uid, privacy: .public) isn't connected; using the system default")
            // Pin the default explicitly: a unit pinned to a device that has gone stays pinned to it (and silent).
            return (defaultDevice, true)
        }
        // No selection: a fresh unit follows the default by itself. Once pinned (or when the device died), pin.
        return (defaultDevice, pinnedDevice || pinDefault)
    }

    /// Points the input node at the desired device, skipping the call when the unit is already on it
    /// (setting it again can post another configuration change).
    private func selectDevice(on input: AVAudioInputNode, pinDefault: Bool) throws -> AudioInputDevice? {
        let (device, pin) = desiredDevice(pinDefault: pinDefault)
        guard pin, let device else { return device }
        guard let unit = input.audioUnit else { throw MicRecorderError.noInputDevice }
        if Self.currentDeviceID(of: input) == device.deviceID {
            pinnedDevice = true
            return device
        }
        var deviceID = device.deviceID
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw MicRecorderError.couldNotSelectDevice(uid: device.uid, status: status) }
        pinnedDevice = true
        return device
    }

    /// The device the input node's audio unit is on right now.
    static func currentDeviceID(of input: AVAudioInputNode) -> AudioDeviceID? {
        guard let unit = input.audioUnit else { return nil }
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &deviceID, &size)
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    /// Each buffer carries the resampler of the tap that captured it, so buffers from a tap replaced after a
    /// configuration change (possibly at another rate) still go through the right one.
    private func handleCaptured(_ mono: [Float], resampler: StreamingResampler) {
        let samples: [Float]
        do {
            samples = try resampler.process(mono)
        } catch {
            logger.error("Resampling failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        deliver(samples)
    }

    /// Disk first, then the stream, then the level meter.
    private func deliver(_ samples: [Float]) {
        guard !samples.isEmpty, let writer else { return }
        do {
            try writer.write(samples)
        } catch {
            if _writeError == nil {
                _writeError = error
                logger.error("Writing audio failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        continuation?.yield(samples)
        levelHandler?(AudioLevel.measure(samples))
    }

    // MARK: Configuration changes and lost devices

    /// AVAudioEngine posts configuration changes that change nothing (for example ~100 ms after starting with a
    /// pinned device). Only rebuild the tap when the device or format really moved, or the device died.
    private func handleConfigurationChange(for changedEngine: AVAudioEngine) {
        guard let engine, engine === changedEngine else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let current = Self.currentDeviceID(of: input)
        let wanted = desiredDevice(pinDefault: false)
        let wantedMatches = !wanted.pin || wanted.device?.deviceID == current
        let currentAlive = current.map(AudioInputDevices.isAlive) ?? false
        if let signature = tapSignature, wantedMatches, currentAlive,
           signature == TapSignature(deviceID: current, sampleRate: format.sampleRate, channels: format.channelCount) {
            if engine.isRunning {
                logger.debug("Configuration change with nothing changed; ignoring")
                return
            }
            // Same device and format, but the engine stopped: start it again with the tap as it is.
            engine.prepare()
            do {
                try engine.start()
                logger.notice("Engine restarted after a configuration change (same device and format)")
                return
            } catch {
                logger.error("Restart with the same tap failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        rebuildTap(reason: "configuration change", pinDefault: !currentAlive)
    }

    /// Removes the tap and installs a new one for the input as it now is, at most a few times in a few seconds.
    private func rebuildTap(reason: String, pinDefault: Bool) {
        guard let engine else { return }
        let now = Date()
        recentRebuilds = recentRebuilds.filter { now.timeIntervalSince($0) < Self.rebuildWindow }
        guard recentRebuilds.count < Self.maxRebuildsPerWindow else {
            // Something keeps posting changes: back off rather than loop, then try once more.
            guard !rebuildRetryScheduled else { return }
            rebuildRetryScheduled = true
            logger.error("Too many audio restarts; trying again in \(Self.rebuildWindow, privacy: .public) s")
            queue.asyncAfter(deadline: .now() + Self.rebuildWindow) { [weak self] in
                guard let self, self.engine === engine else { return }
                self.rebuildRetryScheduled = false
                self.rebuildTap(reason: "retry after backing off", pinDefault: pinDefault)
            }
            return
        }
        recentRebuilds.append(now)
        logger.notice("Rebuilding the input tap (\(reason, privacy: .public))")

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Flush the old resampler's tail once any buffers the old tap already handed over have gone through it.
        // This block is queued before the new tap can deliver anything, so the order on disk stays right.
        if let old = resampler {
            queue.async { self.deliver(old.finish()) }
        }
        do {
            try installTap(on: engine, pinDefault: pinDefault)
            engine.prepare()
            try engine.start()
        } catch {
            // Leave the recording open: a later configuration change (the device coming back) may restart it,
            // and stop() still finalises what was captured.
            tapSignature = nil
            logger.error("Couldn't restart the input: \(error.localizedDescription, privacy: .public)")
        }
        watchActiveDevice()
    }

    /// Listens for the active device dying (unplugged), which doesn't always post a configuration change.
    private func watchActiveDevice() {
        unwatchActiveDevice()
        guard let deviceID = tapSignature?.deviceID ?? _activeDevice?.deviceID else { return }
        var address = Self.isAliveAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Runs on `queue` (passed below).
            guard let self, self.engine != nil, self.aliveWatch?.deviceID == deviceID else { return }
            guard !AudioInputDevices.isAlive(deviceID) else { return }
            self.logger.notice("The input device went away; switching to the system default")
            // Rebuild outside the listener callback, since rebuilding removes this listener.
            self.queue.async {
                guard self.engine != nil, self.aliveWatch?.deviceID == deviceID else { return }
                self.rebuildTap(reason: "device lost", pinDefault: true)
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, block)
        if status == noErr {
            aliveWatch = (deviceID, block)
        }
    }

    private func unwatchActiveDevice() {
        guard let watch = aliveWatch else { return }
        var address = Self.isAliveAddress
        _ = AudioObjectRemovePropertyListenerBlock(watch.deviceID, &address, queue, watch.block)
        aliveWatch = nil
    }

    private static let isAliveAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private static let rebuildWindow: TimeInterval = 5
    private static let maxRebuildsPerWindow = 4

    private func stopEngineOnQueue() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        unwatchActiveDevice()
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func finishOnQueue() -> TimeInterval {
        if let resampler { deliver(resampler.finish()) }
        var duration: TimeInterval = 0
        if let writer {
            do {
                duration = try writer.close()
            } catch {
                duration = writer.duration
                if _writeError == nil { _writeError = error }
                logger.error("Finalising the WAV failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        continuation?.finish()
        continuation = nil
        writer = nil
        resampler = nil
        engine = nil
        _activeDevice = nil
        tapSignature = nil
        logger.info("Recording stopped after \(duration, privacy: .public) s")
        return duration
    }
}
