// Sample view models for SwiftUI #Previews. Not used at run time. Kept outside `#if DEBUG` so #Preview blocks
// (which are compiled in every configuration) always find them.

import DevshoutCore
import Foundation

@MainActor
enum PreviewData {
    static let devices = [
        InputDeviceOption(id: "builtin", name: "MacBook Pro Microphone"),
        InputDeviceOption(id: "airpods", name: "Patrick's AirPods Pro"),
    ]

    static let levelHistory: [Float] = (0..<AudioLevelViewModel.historyLength).map { i in
        let x = Double(i) / 4
        return Float(abs(sin(x) * 0.6 + sin(x * 2.3) * 0.25))
    }

    static func microphone(_ permission: MicPermission = .granted) -> MicrophoneViewModel {
        MicrophoneViewModel(permission: permission, devices: devices, selectedDeviceID: nil,
                            level: AudioLevelViewModel(history: levelHistory))
    }

    static func speech(_ status: SpeechModelStatus = .ready(sizeOnDisk: 486_000_000)) -> SpeechEngineViewModel {
        SpeechEngineViewModel(selectedEngine: .parakeetV3,
                              statuses: [.parakeetV3: status, .whisperLargeV3Turbo: .notDownloaded])
    }

    static let downloading = SpeechModelStatus.downloading(fraction: 0.42, bytesDone: 204_000_000,
                                                          bytesTotal: 486_000_000, bytesPerSecond: 18_500_000)

    nonisolated static let installation = ClaudeInstallation(path: "/Users/patrick/.local/bin/claude", version: "2.1.301")

    static func claude(_ account: ClaudeAccountStatus = .connected(tokenCreatedAt: Date().addingTimeInterval(-90 * 86_400)),
                       install: ClaudeInstallStatus = .found(installation),
                       test: ClaudeTestStatus = .idle, installLog: String = "") -> ClaudeViewModel {
        let model = ClaudeViewModel(install: install, account: account, test: test)
        model.installLog = installLog
        return model
    }

    static let installLog = "Downloading Claude Code…\nVerifying checksum…\nInstalling to ~/.local/bin/claude"

    /// A token made 350 days ago: expires in about 15 days.
    static let expiringAccount = ClaudeAccountStatus.connected(tokenCreatedAt: Date().addingTimeInterval(-350 * 86_400))

    static let signingIn = ClaudeAccountStatus.signingIn(
        ClaudeSignInProgress(signInURL: URL(string: "https://claude.ai/oauth/authorize?code=true"), needsCode: true))

    static let defaultInstructions: [ModeID: String] = [
        .tidy: "Keep the speaker's words, order and meaning. Fix punctuation, capitalisation, sentence breaks and paragraphs. Correct misheard words using the glossary. Remove filler words, false starts and accidental repetitions.",
        .structure: "The transcript is someone talking through instructions for an AI coding agent. Rewrite it as a clear, well-ordered written brief that the agent can act on. Every point must appear in your output: drop none, invent none.",
    ]

    static let glossaryText = """
    # Abatable glossary

    ## Terms
    - **CORSIA** — Carbon Offsetting and Reduction Scheme for International Aviation
      - heard: core sea, corsair, causia
    - **NDC** — Nationally Determined Contribution
    - **My Supply** — heard: my supplies, mice apply

    ## People
    - **Siobhán Murphy** — heard: shiv on, chevonne

    ## Patterns
    - **AB-{n}** — Linear ticket IDs
      - heard: a b {n}, AB {n}
    """

    /// History samples, newest first: a plain Tidy dictation, one re-run as Structure (three texts to show), one
    /// that failed, and an old one whose audio retention has deleted.
    static let recordings: [Recording] = {
        let now = Date()
        let rambling = "um so the corsia flag is wrong on the project page and also can you add a test for it and er check the n d c field too"
        let tidied = "The CORSIA flag is wrong on the project page. Can you add a test for it, and check the NDC field too?"
        return [
            Recording(id: UUID(), createdAt: now, duration: 7, mode: .tidy, engine: .parakeetV3,
                      rawText: "um can you check the corsia flag",
                      versions: [CleanVersion(mode: .tidy, model: "haiku", text: "Can you check the CORSIA flag?",
                                              elapsed: 1.4, createdAt: now)],
                      deliveredText: "Can you check the CORSIA flag?",
                      delivered: DeliveryRecord(.pasted(appName: "Slack")),
                      timings: RecordingTimings(total: 2.1)),
            Recording(id: UUID(), createdAt: now.addingTimeInterval(-1800), duration: 19, mode: .tidy,
                      engine: .whisperLargeV3Turbo, rawText: rambling,
                      versions: [
                          CleanVersion(mode: .tidy, model: "haiku", text: tidied, elapsed: 1.8,
                                       createdAt: now.addingTimeInterval(-1795)),
                          CleanVersion(mode: .structure, model: "sonnet",
                                       text: "Fix the project page:\n\n1. The CORSIA flag is wrong: correct it.\n2. Add a test for the flag.\n3. Check the NDC field as well.",
                                       elapsed: 6.2, createdAt: now.addingTimeInterval(-600)),
                      ],
                      deliveredText: tidied, delivered: DeliveryRecord(.pasted(appName: "Linear")),
                      timings: RecordingTimings(total: 3.4)),
            Recording(id: UUID(), createdAt: now.addingTimeInterval(-3600), duration: 3, status: .failed,
                      errorMessage: "No speech was detected."),
            Recording(id: UUID(), createdAt: now.addingTimeInterval(-40 * 86_400), duration: 12, mode: .raw,
                      engine: .parakeetV3, rawText: "remember to renew the procurement contract before friday",
                      deliveredText: "remember to renew the procurement contract before friday",
                      delivered: DeliveryRecord(.copiedOnly(reason: "No text field was focused")),
                      audioDeletedAt: now.addingTimeInterval(-10 * 86_400)),
        ]
    }()

    /// A crude stand-in for the real parser: counts bullets per section.
    static func countTerms(_ text: String) -> GlossaryTermCounts {
        var counts = GlossaryTermCounts()
        var section = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") { section = String(trimmed.dropFirst(3)); continue }
            if trimmed.contains("heard:") {
                let list = trimmed.components(separatedBy: "heard:").last ?? ""
                counts.mishearings += list.split(separator: ",").count
            }
            guard line.hasPrefix("- ") else { continue }
            switch section {
            case "Terms": counts.terms += 1
            case "People": counts.people += 1
            case "Patterns": counts.patterns += 1
            default: break
            }
        }
        return counts
    }

    static func models(account: ClaudeAccountStatus = .connected(tokenCreatedAt: Date().addingTimeInterval(-90 * 86_400)),
                       speechStatus: SpeechModelStatus = .ready(sizeOnDisk: 486_000_000),
                       accessibilityTrusted: Bool = true) -> DevshoutViewModels {
        DevshoutViewModels(
            microphone: microphone(),
            accessibility: AccessibilityViewModel(isTrusted: accessibilityTrusted),
            speech: speech(speechStatus),
            claude: claude(account),
            hotkeys: HotkeysViewModel(),
            general: GeneralSettingsViewModel(),
            modes: ModesSettingsViewModel(defaultInstructions: defaultInstructions),
            apps: AppsSettingsViewModel(
                rules: Array(AppModeRule.suggestions.prefix(4)),
                runningApps: {
                    [AppCandidate(bundleID: "com.apple.Safari", name: "Safari"),
                     AppCandidate(bundleID: "com.linear", name: "Linear"),
                     AppCandidate(bundleID: "com.apple.Terminal", name: "Terminal")]
                }),
            glossary: GlossaryViewModel(text: glossaryText, parse: countTerms),
            privacy: PrivacyViewModel(storageUsed: 182_000_000, recordingCount: 64))
    }

    static func onboarding(at step: OnboardingStep, account: ClaudeAccountStatus = .notConnected,
                           speechStatus: SpeechModelStatus = .notDownloaded) -> OnboardingViewModel {
        let onboarding = models(account: account, speechStatus: speechStatus, accessibilityTrusted: false).onboarding
        onboarding.go(to: step)
        return onboarding
    }

    static func pill(_ phase: PillPhase, mode: ModeID = .tidy, liveText: String? = nil) -> RecordingPillViewModel {
        let model = RecordingPillViewModel(levels: AudioLevelViewModel(history: levelHistory))
        model.mode = mode
        model.phase = phase
        model.startedAt = Date().addingTimeInterval(-192)
        model.liveText = liveText
        return model
    }
}
