// Permissions (polled: macOS sends no notification for Accessibility), the input device list, and the level meter
// shown in onboarding and Settings → Transcription.

import AppKit
import DevshoutCore
import DevshoutMac
import Foundation

// MARK: - Permissions

@MainActor
final class PermissionsController {
    private let microphone: MicrophoneViewModel
    private let accessibility: AccessibilityViewModel
    private var timer: Timer?
    /// Called when Accessibility trust changes (the menu bar badge, paste fallbacks).
    var onChange: (() -> Void)?

    init(microphone: MicrophoneViewModel, accessibility: AccessibilityViewModel) {
        self.microphone = microphone
        self.accessibility = accessibility

        microphone.actions.requestAccess = { [weak self] in
            Task {
                _ = await MicrophonePermission.request()
                self?.poll()
            }
        }
        microphone.actions.openPrivacySettings = { MicrophonePermission.openSystemSettings() }
        accessibility.actions = AccessibilityViewModel.Actions(
            requestTrust: { AccessibilityPermission.prompt() },
            openSettings: { AccessibilityPermission.openSystemSettings() },
            revealAppInFinder: { AccessibilityPermission.revealAppInFinder() }
        )
    }

    /// Check now, then once a second for as long as the app runs (both checks are cheap).
    func start() {
        poll()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func poll() {
        let mic: MicPermission
        switch MicrophonePermission.status {
        case .authorised: mic = .granted
        case .notDetermined: mic = .notDetermined
        case .denied, .restricted: mic = .denied
        }
        // Assign only on change: every assignment would redraw every view watching these models.
        if microphone.permission != mic { microphone.permission = mic }
        let trusted = AccessibilityPermission.isTrusted
        if accessibility.isTrusted != trusted {
            accessibility.isTrusted = trusted
            onChange?()
        }
    }
}

// MARK: - Input devices

@MainActor
final class InputDevicesController {
    private let microphone: MicrophoneViewModel
    private var observer: AudioInputDevicesObserver?
    var onSelect: ((String?) -> Void)?

    init(microphone: MicrophoneViewModel, selectedUID: String?) {
        self.microphone = microphone
        microphone.actions.selectDevice = { [weak self] uid in self?.onSelect?(uid) }
        refresh(selectedUID: selectedUID)
        observer = AudioInputDevicesObserver { [weak self] in
            MainActor.assumeIsolated { self?.refresh(selectedUID: self?.microphone.selectedDeviceID) }
        }
    }

    func refresh(selectedUID: String?) {
        let devices = AudioInputDevices.all().map { InputDeviceOption(id: $0.uid, name: $0.name) }
        microphone.sync {
            if microphone.devices != devices { microphone.devices = devices }
            if microphone.selectedDeviceID != selectedUID { microphone.selectedDeviceID = selectedUID }
        }
    }
}

// MARK: - Level meter

/// Runs the microphone for the level meter while a meter is on screen and no dictation is recording. It uses a
/// `MicRecorder` (so the chosen input device is honoured) writing a throwaway file in the temporary folder, which is
/// deleted when the meter stops. Nothing it hears is kept or transcribed.
@MainActor
final class LevelMeterController {
    private let level: AudioLevelViewModel
    private let scratch: URL
    private var deviceUID: String?
    private var wanted = false
    private var paused = false
    private var recorder: MicRecorder?
    private var fileURL: URL?
    /// Start and stop run one after another, never interleaved.
    private var chain: Task<Void, Never>?

    init(level: AudioLevelViewModel, scratch: URL) {
        self.level = level
        self.scratch = scratch
    }

    func setWanted(_ value: Bool) {
        wanted = value
        update()
    }

    /// A dictation is recording: it feeds the same level model, so the meter steps aside.
    func setPaused(_ value: Bool) {
        paused = value
        update()
    }

    func setDevice(_ uid: String?) {
        guard uid != deviceUID else { return }
        deviceUID = uid
        if recorder != nil {
            stopRecorder()
            update()
        }
    }

    private func update() {
        let shouldRun = wanted && !paused
        if shouldRun, recorder == nil {
            startRecorder()
        } else if !shouldRun, recorder != nil {
            stopRecorder()
        }
    }

    private func startRecorder() {
        let level = level
        let recorder = MicRecorder(deviceUID: deviceUID, levelHandler: { measured in
            let value = measured.meterValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { level.push(value) }
            }
        })
        self.recorder = recorder
        let url = scratch.appendingPathComponent("meter-\(UUID().uuidString).wav")
        fileURL = url
        let scratch = scratch
        let previous = chain
        chain = Task {
            await previous?.value
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            do {
                let stream = try await recorder.start(writingTo: url)
                // Nobody needs the samples: drain them so the stream's buffer stays empty.
                Task.detached { for await _ in stream {} }
            } catch {
                // No microphone, or access was refused: the meter just stays still.
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func stopRecorder() {
        guard let recorder else { return }
        self.recorder = nil
        let url = fileURL
        fileURL = nil
        let previous = chain
        chain = Task {
            await previous?.value
            await recorder.cancel()
            if let url { try? FileManager.default.removeItem(at: url) }
        }
        level.reset()
    }
}
