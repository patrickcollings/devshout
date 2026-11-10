// The strip at the top of the Settings window: what devshout is doing now and anything that needs attention, so
// "why won't it dictate?" has an answer without hunting through the tabs.

import DevshoutCore
import SwiftUI

struct StatusStrip: View {
    @ObservedObject var menuBar: MenuBarViewModel
    @ObservedObject var speech: SpeechEngineViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            activity
            modelLine
            ForEach(otherLines) { line in
                StatusLabel(text: line.text, tone: line.tone, symbolName: line.symbolName)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.04))
    }

    @ViewBuilder
    private var activity: some View {
        if menuBar.isRecording {
            StatusLabel(text: "Recording…", tone: .critical, symbolName: "record.circle")
        } else if menuBar.isWorking {
            StatusLabel(text: "Transcribing or tidying the last dictation…", tone: .neutral, symbolName: "hourglass")
        } else if canDictate {
            StatusLabel(text: "Ready to dictate", tone: .positive)
        } else {
            StatusLabel(text: "Can't dictate yet", tone: .warning)
        }
    }

    private var canDictate: Bool {
        speech.selectedStatus.isReady && !menuBar.statusLines.contains { $0.tone == .critical }
    }

    @ViewBuilder
    private var modelLine: some View {
        let engine = speech.selectedEngine
        HStack(alignment: .top, spacing: 6) {
            Text("\(engine.displayName):").foregroundStyle(.secondary)
            ModelProgressView(status: speech.status(for: engine), since: speech.preparingSince[engine])
        }
    }

    /// Microphone, Accessibility and Claude. The model has its own line above.
    private var otherLines: [MenuStatusLine] {
        let modelLine = speech.selectedStatus.menuLine
        return menuBar.statusLines.filter { $0 != modelLine }
    }
}

#Preview("Status strip") {
    let models = PreviewData.models()
    return StatusStrip(menuBar: models.menuBar, speech: models.speech)
        .frame(width: 600)
}
