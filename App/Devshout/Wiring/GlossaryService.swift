// The one glossary.md (PLAN §0 item 4): loaded at launch, edited in Settings → Glossary, and re-parsed on every save
// for its three consumers: TextFixer (every mode), Claude's system prompt and Whisper's vocabulary prompt.

import AppKit
import DevshoutCore
import Foundation

/// What the pipeline reads from the glossary. Thread-safe: the dictation session calls it from its own actor.
final class GlossaryState: @unchecked Sendable {
    private let lock = NSLock()
    private var glossary: Glossary = .empty
    private var fixer = TextFixer(glossary: .empty)
    private var claudeText = ""
    private var tokenCounter: any TokenCounter = ApproximateTokenCounter()

    func update(_ newGlossary: Glossary) {
        let newFixer = TextFixer(glossary: newGlossary)
        let rendered = GlossaryRenderer.forClaude(newGlossary)
        lock.lock()
        glossary = newGlossary
        fixer = newFixer
        claudeText = rendered
        lock.unlock()
    }

    /// The counter Whisper's prompt is measured with (WhisperKit's tokenizer when Whisper is the engine).
    func setTokenCounter(_ counter: any TokenCounter) {
        lock.lock()
        tokenCounter = counter
        lock.unlock()
    }

    func fix(_ text: String) -> String {
        lock.lock()
        let current = fixer
        lock.unlock()
        return current.fix(text).text
    }

    var forClaude: String {
        lock.lock()
        defer { lock.unlock() }
        return claudeText
    }

    /// Built when asked, so it uses the tokenizer as soon as Whisper has loaded it.
    func whisperPrompt() -> String? {
        lock.lock()
        let current = glossary
        let counter = tokenCounter
        lock.unlock()
        let vocabulary = WhisperPromptBuilder(tokenCounter: counter).vocabulary(for: current)
        return vocabulary.prompt.isEmpty ? nil : vocabulary.prompt
    }

    static func counts(for text: String) -> GlossaryTermCounts {
        let glossary = GlossaryParser.parse(text)
        let entries = glossary.allEntries.map(\.entry)
        return GlossaryTermCounts(terms: glossary.terms.filter { !$0.isPattern }.count,
                                  people: glossary.people.count,
                                  patterns: glossary.patterns.count,
                                  mishearings: entries.reduce(0) { $0 + $1.heard.count })
    }
}

/// Connects `GlossaryViewModel` to glossary.md and `GlossaryState`.
@MainActor
final class GlossaryController {
    let file: GlossaryFile
    let state = GlossaryState()
    private let model: GlossaryViewModel

    init(url: URL, model: GlossaryViewModel) {
        file = GlossaryFile(url: url)
        self.model = model
        model.fileURL = url
        model.parse = { GlossaryState.counts(for: $0) }
        model.save = { [weak self] text in
            guard let self else { return }
            try self.file.save(text: text)
            self.state.update(GlossaryParser.parse(text))
        }
        model.revealInFinder = { [weak self] url in
            guard let self else { return }
            // Nothing to show until the file exists: write the (all-comments) starter so Finder has something.
            if !self.file.exists { try? self.file.save(text: self.model.savedText) }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Reads glossary.md (or the starter template when there is none) into the editor and the pipeline.
    func load() {
        do {
            let text = try file.loadText()
            model.load(text)
            state.update(GlossaryParser.parse(text))
        } catch {
            model.load(GlossaryFile.starterTemplate)
            model.errorMessage = "Couldn't read glossary.md: \(ErrorText.describe(error))"
            state.update(.empty)
        }
    }
}
