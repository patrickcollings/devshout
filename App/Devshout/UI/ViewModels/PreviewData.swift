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
