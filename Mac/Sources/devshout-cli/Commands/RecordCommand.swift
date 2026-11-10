// devshout-cli record: the microphone to a 16 kHz mono WAV, with a level meter, until Enter (or --seconds).
//
// Unsure on macOS (written on Linux, type-checked there against stand-ins for DevshoutMac, never run on a Mac):
// - Microphone permission for a command-line tool belongs to the app it runs in (Terminal, iTerm, the IDE). The
//   prompt should name that app; if macOS instead kills the tool for lacking NSMicrophoneUsageDescription, the
//   fix is to embed an Info.plist in the binary (see the pull request).
// - Ctrl-C is caught with a DispatchSource on SIGINT so the WAV is finalised; a second Ctrl-C quits at once.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ArgumentParser
import DevshoutCore
import DevshoutMac
import Foundation

struct RecordCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Record the microphone to a 16 kHz mono WAV until you press Enter.",
        discussion: """
        Run it from Terminal: macOS asks for microphone access on behalf of the app the command runs in. \
        The file is overwritten if it exists.
        """
    )

    @Argument(help: "The WAV file to write, e.g. bench/audio/s01.wav.")
    var output: String?

    @Option(help: "Core Audio UID of the input to use (see --list-devices). Default: the system's default input.")
    var device: String?

    @Option(help: "Stop after this many seconds instead of waiting for Enter.")
    var seconds: Double?

    @Flag(name: .customLong("list-devices"), help: "List the audio inputs and their UIDs, then exit.")
    var listDevices = false

    func validate() throws {
        if !listDevices, output == nil {
            throw ValidationError("Give the WAV file to write, e.g. devshout-cli record bench/audio/s01.wav")
        }
        if let seconds, !(seconds > 0) { throw ValidationError("--seconds must be more than 0.") }
    }

    mutating func run() async throws {
        if listDevices {
            let devices = AudioInputDevices.all()
            if devices.isEmpty { Console.out("No audio inputs found.") }
            for device in devices {
                Console.out("\(device.isDefault ? "*" : " ") \(device.name) (\(device.inputChannels) ch)  uid: \(device.uid)")
            }
            if !devices.isEmpty { Console.out("* = the system's default input") }
            return
        }
        guard let output else { return }
        try await Self.ensureMicrophoneAccess()

        if let device, AudioInputDevices.device(withUID: device) == nil {
            Console.error("Warning: no input with UID \(device) is connected, so the default input is used. "
                          + "See devshout-cli record --list-devices.")
        }

        let url = Files.url(output)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let level = Locked<Float>(0)
        let recorder = MicRecorder(deviceUID: device, levelHandler: { measured in
            let value = measured.meterValue()
            level.update { $0 = max($0, value) }
        })
        let stop = OneShot()

        let stream: AsyncStream<[Float]>
        do {
            stream = try await recorder.start(writingTo: url)
        } catch {
            throw CLIError("Couldn't start recording: \(error.localizedDescription)")
        }
        let samples = Locked<Int>(0)
        let collector = Task {
            for await buffer in stream { samples.update { $0 += buffer.count } }
        }

        let input = recorder.activeDevice?.name ?? "the default input"
        let stopHint = seconds.map { "Stops after \(SpikeFormat.seconds($0)), or press Enter." } ?? "Press Enter to stop."
        Console.error("Recording \(url.lastPathComponent) from \(input). \(stopHint)")

        // Enter (or the end of piped input, unless --seconds is set) stops the recording.
        let watchEndOfInput = seconds == nil
        Thread.detachNewThread {
            if readLine() != nil || watchEndOfInput { stop.fire() }
        }
        if let seconds {
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                stop.fire()
            }
        }
        // Ctrl-C stops and keeps the file; a second Ctrl-C quits at once.
        signal(SIGINT, SIG_IGN)
        let interrupts = Locked<Int>(0)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue.global())
        interrupt.setEventHandler {
            var count = 0
            interrupts.update { $0 += 1; count = $0 }
            if count > 1 { _exit(130) }
            stop.fire()
        }
        interrupt.resume()

        let meter = Task {
            var smoother = LevelSmoother()
            var lastLine = SpikeClock.now()
            let redraw = Console.stderrIsTerminal
            while !Task.isCancelled {
                var peak: Float = 0
                level.update { peak = $0; $0 = 0 }
                let shown = smoother.update(peak)
                let elapsed = Double(samples.get()) / Double(AudioFormat.sampleRate)
                let decibels = shown <= 0 ? "-60" : String(format: "%.0f", shown * 60 - 60)
                let line = "● REC \(SpikeFormat.clock(elapsed)) \(SpikeFormat.meter(shown, width: 30)) \(decibels) dB"
                if redraw {
                    Console.raw("\r\u{1B}[K" + line)
                } else if SpikeClock.now() - lastLine >= 5 {
                    Console.error(line)
                    lastLine = SpikeClock.now()
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        await stop.wait()
        meter.cancel()
        _ = await meter.value
        if Console.stderrIsTerminal { Console.raw("\r\u{1B}[K") }

        let duration: TimeInterval
        do {
            duration = try await recorder.stop()
        } catch {
            throw CLIError("Couldn't finish the recording: \(error.localizedDescription)")
        }
        _ = await collector.value
        interrupt.cancel()
        signal(SIGINT, SIG_DFL)

        if let writeError = recorder.writeError {
            Console.error("Warning: writing the file failed (\(writeError.localizedDescription)); it may be incomplete.")
        }
        Console.error("Saved \(url.path): \(SpikeFormat.clock(duration)), 16 kHz mono 16-bit.")
        Console.out(String(format: "%.2f", duration))
    }

    /// Checks (and if needed asks for) microphone access, with a message that names the real fix.
    static func ensureMicrophoneAccess() async throws {
        let howToFix = """
        Turn it on in System Settings → Privacy & Security → Microphone for the app you're running this in \
        (Terminal, iTerm, your editor…), then quit and reopen that app. To open the pane:
          open "\(MicrophonePermission.settingsURL.absoluteString)"
        """
        switch MicrophonePermission.status {
        case .authorised:
            return
        case .notDetermined:
            Console.error("Asking macOS for microphone access (it asks on behalf of the app this runs in)…")
            if await MicrophonePermission.request() { return }
            throw CLIError("Microphone access was refused. \(howToFix)")
        case .denied:
            throw CLIError("Microphone access is off. \(howToFix)")
        case .restricted:
            throw CLIError("Microphone access is blocked on this Mac (by a profile or parental controls), so recording can't work.")
        }
    }
}
