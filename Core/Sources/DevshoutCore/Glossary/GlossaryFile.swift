import Foundation

/// The one `glossary.md` the user edits in Settings → Glossary (PLAN §0 item 4).
public struct GlossaryFile: Sendable, Hashable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `<Application Support>/devshout/glossary.md`, given the Application Support folder.
    public static func defaultURL(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("devshout", isDirectory: true)
            .appendingPathComponent("glossary.md", isDirectory: false)
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The file's text, or the starter template when there is no file yet (nothing is written).
    /// Text that isn't valid UTF-8 is read with replacement characters rather than failing; a BOM is dropped.
    /// Throws only when the file exists but can't be read.
    public func loadText() throws -> String {
        guard exists else { return GlossaryFile.starterTemplate }
        let data = try Data(contentsOf: url)
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    /// The parsed glossary (the starter template, which has no active entries, when there is no file).
    public func load() throws -> Glossary {
        GlossaryParser.parse(try loadText())
    }

    /// Writes the text as typed, as UTF-8, atomically, creating the folder if needed.
    public func save(text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: [.atomic])
    }

    /// Writes a glossary built in code, in the canonical form (`GlossaryWriter`).
    public func save(_ glossary: Glossary) throws {
        try save(text: GlossaryWriter.markdown(glossary))
    }

    /// What a new glossary starts as: the format explained, with commented-out examples. Everything in
    /// `<!-- … -->` is ignored, so this template on its own changes nothing.
    public static let starterTemplate: String = """
    # Glossary
    <!--
    devshout uses this file to get your jargon, names and ticket IDs right.
    Claude sees all of it when it tidies or structures a dictation. Whisper is given the
    correct spellings of the first entries (pinned ones first, then People, then Terms), so put
    the most important ones near the top. Known mishearings are fixed in every mode, Raw included.

    How to write entries:
    - **Term** — what it means
      - heard: how speech-to-text tends to get it wrong, separated by commas
    - !**Term** — a "!" pins an entry to the top of Whisper's list
    In Patterns, {n} stands for a number, so AB-{n} also fixes "AB 1234" and "a b one two three four".
    Style is plain text passed straight to Claude. Other ## sections are passed to Claude as they are.

    Anything between these comment markers is ignored. To use an example below, move it out of its
    comment, or delete the markers around it.
    -->

    ## Terms
    <!--
    - **CORSIA** — Carbon Offsetting and Reduction Scheme for International Aviation
      - heard: core sea, corsair
    - **NDC** — Nationally Determined Contribution
      - heard: N D C, endy see
    - **My Supply** — the product area for a buyer's supply of credits
      - heard: my supplies
    - **procurement** — buying carbon credits
    - **proponent** — the developer of a carbon project
    -->

    ## People
    <!--
    - **Siobhán Murphy** — heard: shiv on, chevonne
    -->

    ## Patterns
    <!--
    - **AB-{n}** — Linear ticket IDs
      - heard: a b {n}, ABE {n}
    -->

    ## Style
    <!--
    Write "My Supply" with both words capitalised.
    -->

    """
}
