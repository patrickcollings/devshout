// Small reusable views and view-side helpers.
//
// Unsure on macOS (not compiled here):
// - `KeyEquivalent.space` exists (it does in the macOS 14 SDK docs); unknown keys fall back to no menu shortcut.
// - `NSWorkspace.shared.icon(forFile:)` / `urlForApplication(withBundleIdentifier:)` for app icons.

import AppKit
import DevshoutCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Colours and symbols

extension StatusTone {
    var color: Color {
        switch self {
        case .neutral: .secondary
        case .positive: .green
        case .warning: .orange
        case .critical: .red
        }
    }

    var symbolName: String {
        switch self {
        case .neutral: "circle.dotted"
        case .positive: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .critical: "exclamationmark.triangle.fill"
        }
    }
}

extension ModeID {
    var tint: Color {
        switch self {
        case .raw: .gray
        case .tidy: .blue
        case .structure: .purple
        }
    }

    var symbolName: String {
        switch self {
        case .raw: "text.alignleft"
        case .tidy: "sparkles"
        case .structure: "list.bullet.rectangle"
        }
    }

    var summary: String {
        switch self {
        case .raw: "Exactly what you said, with glossary fixes. Never uses Claude."
        case .tidy: "Punctuation, paragraphs and fillers fixed. Your words, your order."
        case .structure: "A clear, ordered brief for a coding agent. Drops nothing."
        }
    }
}

// MARK: - Hotkeys

extension HotkeyDisplay {
    /// The menu key equivalent for this hotkey, when SwiftUI can express it.
    var keyboardShortcut: KeyboardShortcut? {
        let equivalent: KeyEquivalent
        switch key.lowercased() {
        case "space": equivalent = .space
        case "return", "enter": equivalent = .return
        case "tab": equivalent = .tab
        case "esc", "escape": equivalent = .escape
        default:
            guard key.count == 1, let character = key.lowercased().first else { return nil }
            equivalent = KeyEquivalent(character)
        }
        var eventModifiers: EventModifiers = []
        if modifiers.contains(.control) { eventModifiers.insert(.control) }
        if modifiers.contains(.option) { eventModifiers.insert(.option) }
        if modifiers.contains(.shift) { eventModifiers.insert(.shift) }
        if modifiers.contains(.command) { eventModifiers.insert(.command) }
        return KeyboardShortcut(equivalent, modifiers: eventModifiers)
    }
}

/// "⌥ ⇧ Space" drawn as keycaps.
struct KeyCaps: View {
    let hotkey: HotkeyDisplay

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array((hotkey.modifierSymbols + [hotkey.key]).enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(.callout, design: .rounded).weight(.medium))
                    .padding(.horizontal, key.count > 1 ? 8 : 6)
                    .frame(minWidth: 24, minHeight: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.08), radius: 0, x: 0, y: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hotkey.text)
    }
}

/// The recorder from wiring when there is one, else the hotkey as keycaps (or "Not set").
struct HotkeyField: View {
    @ObservedObject var hotkeys: HotkeysViewModel
    let slot: HotkeySlot

    var body: some View {
        if let recorder = hotkeys.recorder {
            recorder(slot)
        } else if let hotkey = hotkeys.hotkey(for: slot) {
            KeyCaps(hotkey: hotkey)
        } else {
            Text("Not set").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Status

/// A tinted symbol and a line of text.
struct StatusLabel: View {
    let text: String
    let tone: StatusTone
    var symbolName: String? = nil

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbolName ?? tone.symbolName)
                .foregroundStyle(tone.color)
        }
    }
}

/// The coloured rounded tile at the top of each onboarding step.
struct SymbolTile: View {
    let systemName: String
    var tint: Color = .accentColor
    var size: CGFloat = 56

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(tint.gradient)
            )
            .shadow(color: tint.opacity(0.3), radius: 6, y: 3)
            .accessibilityHidden(true)
    }
}

/// A mode name in a tinted capsule.
struct ModeChip: View {
    let mode: ModeID
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: mode.symbolName)
                .imageScale(.small)
            Text(mode.displayName)
        }
        .font(compact ? Font.caption.weight(.semibold) : Font.callout.weight(.semibold))
        .padding(.horizontal, compact ? 7 : 9)
        .padding(.vertical, compact ? 3 : 4)
        .foregroundStyle(mode.tint)
        .background(Capsule().fill(mode.tint.opacity(0.18)))
    }
}

// MARK: - Levels

/// A horizontal segmented level meter, like the one in System Settings → Sound.
struct LevelMeter: View {
    @ObservedObject var level: AudioLevelViewModel
    var segments: Int = 24

    var body: some View {
        let lit = Int((Double(level.level) * Double(segments)).rounded())
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(index < lit ? color(for: index) : Color.primary.opacity(0.1))
            }
        }
        .frame(height: 10)
        .animation(.linear(duration: 0.08), value: lit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(level.level * 100)) per cent")
    }

    private func color(for index: Int) -> Color {
        let position = Double(index) / Double(segments)
        if position > 0.85 { return .red }
        if position > 0.7 { return .orange }
        return .green
    }
}

/// Bars for the last few seconds of input level, newest on the right.
struct WaveformView: View {
    @ObservedObject var level: AudioLevelViewModel
    var barCount: Int = 28
    var color: Color = .primary

    var body: some View {
        let values = Array(level.history.suffix(barCount))
        GeometryReader { proxy in
            let spacing: CGFloat = 2
            let barWidth = max(1.5, (proxy.size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Capsule()
                        .fill(color)
                        .frame(width: barWidth, height: max(2, CGFloat(value) * proxy.size.height))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .trailing)
        }
        .animation(.linear(duration: 0.08), value: values)
        .accessibilityHidden(true)
    }
}

// MARK: - Commands

/// A shell command in a monospaced box with a Copy button.
struct CopyableCommand: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                UIClipboard.copy(command)
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .controlSize(.small)
            .help("Copy the command")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}

enum UIClipboard {
    /// Plain copy for UI helpers (the one-liner). Dictation output goes through the Deliverer, not this.
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - App icons

/// The icon of an app, found by bundle identifier or URL; a generic app icon otherwise.
struct AppIconView: View {
    let bundleID: String
    var url: URL? = nil
    var size: CGFloat = 18

    var body: some View {
        Image(nsImage: Self.icon(bundleID: bundleID, url: url))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    static func icon(bundleID: String, url: URL?) -> NSImage {
        let workspace = NSWorkspace.shared
        if let appURL = url ?? workspace.urlForApplication(withBundleIdentifier: bundleID) {
            return workspace.icon(forFile: appURL.path)
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    }
}

// MARK: - Open panels

enum OpenPanels {
    /// Pick the `claude` binary. Hidden folders are shown, since it usually lives in ~/.local/bin.
    @MainActor
    static func chooseClaudeBinary() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose the claude program"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Pick an app from /Applications.
    @MainActor
    static func chooseApplication() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose an app"
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}

// MARK: - Visual effect

/// An `NSVisualEffectView` for HUD-style backgrounds in transparent panels, where SwiftUI materials can't blur
/// what is behind the window.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    /// Rounds the view's own layer too, in case SwiftUI's clipShape doesn't clip the AppKit view.
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.wantsLayer = true
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = cornerRadius > 0
    }
}
