// The onboarding window (PLAN §7.2 as amended by §0: no team glossary step). About 640×480, a step indicator at
// the top, one step at a time, and a footer with Back / skip / the primary button. Steps move on by themselves
// when their condition is met (OnboardingViewModel decides; the view only shows it).
//
// Host it in a `Window("Welcome to devshout", id: "onboarding")` scene or an NSWindow with
// `.windowResizability(.contentSize)`; the view fixes its own size.
//
// Unsure on macOS (not compiled here): `AnyTransition.push(from:)` (macOS 13+).

import DevshoutCore
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: OnboardingViewModel

    static let size = CGSize(width: 640, height: 480)

    var body: some View {
        VStack(spacing: 0) {
            OnboardingStepIndicator(steps: model.steps, current: model.step) { model.go(to: $0) }
                .padding(.top, 18)
                .padding(.horizontal, 24)

            ZStack {
                stepView
                    .id(model.step)
                    .transition(.push(from: .trailing))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 48)
            .clipped()
            .animation(.easeInOut(duration: 0.3), value: model.step)

            Divider()

            OnboardingFooter(model: model)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .onAppear { model.windowDidAppear() }
        .onDisappear { model.windowDidDisappear() }
    }

    @ViewBuilder
    private var stepView: some View {
        switch model.step {
        case .welcome: WelcomeStepView()
        case .microphone: MicrophoneStepView(model: model.microphone)
        case .accessibility: AccessibilityStepView(model: model.accessibility)
        case .speechModel: SpeechModelStepView(model: model.speech)
        case .claude: ClaudeStepView(model: model.claude)
        case .hotkeys: HotkeysStepView(hotkeys: model.hotkeys)
        case .tryIt: TryItStepView(model: model)
        }
    }
}

// MARK: - Step indicator

struct OnboardingStepIndicator: View {
    let steps: [OnboardingStep]
    let current: OnboardingStep
    let select: (OnboardingStep) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(steps) { step in
                Button {
                    select(step)
                } label: {
                    VStack(spacing: 5) {
                        ZStack {
                            Circle()
                                .fill(fill(for: step))
                                .frame(width: 20, height: 20)
                            if step < current {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                            } else {
                                Text("\(step.rawValue + 1)")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundStyle(step == current ? Color.white : Color.secondary)
                            }
                        }
                        Text(step.title)
                            .font(.caption)
                            .foregroundStyle(step == current ? Color.primary : Color.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Step \(step.rawValue + 1) of \(steps.count): \(step.title)")
                .accessibilityAddTraits(step == current ? .isSelected : [])
            }
        }
    }

    private func fill(for step: OnboardingStep) -> Color {
        if step == current { return .accentColor }
        if step < current { return .accentColor.opacity(0.55) }
        return Color.primary.opacity(0.1)
    }
}

// MARK: - Footer

private struct OnboardingFooter: View {
    @ObservedObject var model: OnboardingViewModel

    var body: some View {
        HStack(spacing: 12) {
            if !model.isFirstStep {
                Button("Back") { model.goBack() }
                    .controlSize(.large)
            }
            Spacer()
            if let skip = model.skipTitle {
                Button(skip) { model.skip() }
                    .buttonStyle(.link)
            }
            Button(model.primaryButtonTitle) { model.goForward() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canContinue)
        }
    }
}

// MARK: - Page layout

/// The shared layout of a step: a symbol tile, a title, one sentence of why, then the step's content.
struct OnboardingPage<Content: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    let content: Content

    init(symbol: String, tint: Color, title: String, message: String, @ViewBuilder content: () -> Content) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.message = message
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 14) {
            SymbolTile(systemName: symbol, tint: tint)
            Text(title)
                .font(.title.bold())
            Text(message)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
            content
                .padding(.top, 6)
            Spacer(minLength: 0)
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity)
    }
}

#Preview("Onboarding: welcome") {
    OnboardingView(model: PreviewData.models().onboarding)
}

#Preview("Onboarding: Claude") {
    OnboardingView(model: PreviewData.onboarding(at: .claude, account: .notConnected))
}
