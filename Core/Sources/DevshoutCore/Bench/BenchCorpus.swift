import Foundation

/// One thing to transcribe: a jargon sentence or the ramble, with the files that belong to it.
public struct BenchSample: Sendable, Hashable {
    public static let rambleID = "ramble"

    /// "s01" … "s10", or "ramble".
    public var id: String
    /// The sentence to read aloud (nil for the ramble).
    public var sentence: String?
    /// `audio/<id>.wav`, when it exists.
    public var audioURL: URL?
    /// `references/<id>.txt`, when it exists.
    public var referenceURL: URL?
    /// `superwhisper/<id>.txt`, when it exists.
    public var superwhisperURL: URL?

    public var isRamble: Bool { id == Self.rambleID }

    public init(id: String, sentence: String?, audioURL: URL? = nil, referenceURL: URL? = nil,
                superwhisperURL: URL? = nil) {
        self.id = id
        self.sentence = sentence
        self.audioURL = audioURL
        self.referenceURL = referenceURL
        self.superwhisperURL = superwhisperURL
    }
}

/// The bench folder, read from disk. Layout (see `bench/README.md`):
///
/// ```
/// sentences.md  ramble-outline.md  glossary.sample.md  (glossary.md wins when present)
/// audio/<id>.wav   references/<id>.txt   superwhisper/<id>.txt   results/
/// ```
public struct BenchCorpus: Sendable {
    public var directory: URL
    public var sentences: [BenchSentence]
    public var ramblePoints: [RamblePoint]
    /// The glossary file used (`glossary.md` if there is one, else `glossary.sample.md`), if any.
    public var glossaryURL: URL?
    public var glossaryTerms: [String]
    /// s01 … s10 then the ramble.
    public var samples: [BenchSample]

    public static func load(directory: URL, fileManager: FileManager = .default) throws -> BenchCorpus {
        func read(_ name: String) throws -> String {
            try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        }
        func existing(_ folder: String, _ id: String, _ ext: String) -> URL? {
            let url = directory.appendingPathComponent(folder).appendingPathComponent("\(id).\(ext)")
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }

        let sentences = try SentenceCorpusParser.parse(try read("sentences.md"))
        let points = try RambleOutlineParser.parse(try read("ramble-outline.md"))

        var glossaryURL: URL?
        for name in ["glossary.md", "glossary.sample.md"] {
            let url = directory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) {
                glossaryURL = url
                break
            }
        }
        let terms = try glossaryURL.map { BenchGlossaryTerms.terms(fromMarkdown: try String(contentsOf: $0, encoding: .utf8)) } ?? []

        var samples = sentences.map { BenchSample(id: $0.id, sentence: $0.text) }
        samples.append(BenchSample(id: BenchSample.rambleID, sentence: nil))
        samples = samples.map { sample in
            var sample = sample
            sample.audioURL = existing("audio", sample.id, "wav")
            sample.referenceURL = existing("references", sample.id, "txt")
            sample.superwhisperURL = existing("superwhisper", sample.id, "txt")
            return sample
        }
        return BenchCorpus(directory: directory, sentences: sentences, ramblePoints: points, glossaryURL: glossaryURL,
                           glossaryTerms: terms, samples: samples)
    }

    /// The reference text for a sample, trimmed, when its file exists.
    public func reference(for sample: BenchSample) throws -> String? {
        guard let url = sample.referenceURL else { return nil }
        return try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// superwhisper's saved output for a sample, trimmed, when its file exists.
    public func superwhisperText(for sample: BenchSample) throws -> String? {
        guard let url = sample.superwhisperURL else { return nil }
        return try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Points to check for a sample: the ramble's, nil for sentences.
    public func points(for sample: BenchSample) -> [RamblePoint]? { sample.isRamble ? ramblePoints : nil }
}
