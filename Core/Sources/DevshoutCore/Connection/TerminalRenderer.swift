import Foundation

/// What a stream of raw terminal output amounts to.
public struct RenderedTerminal: Sendable, Hashable {
    /// What the screen shows once every cursor movement and erase has been applied, top to bottom,
    /// with trailing spaces trimmed. Text that was erased or overwritten is gone.
    public var screenLines: [String]
    /// Everything that was ever printed, in order, with escape sequences removed. A carriage return or a
    /// cursor jump to another row starts a new line; a jump within the row (Ink spaces words with `ESC [ n G`)
    /// becomes a space. Nothing is ever erased, so a token that was shown and then cleared is still here.
    public var plainLines: [String]
    /// Targets of OSC 8 hyperlinks (`ESC ] 8 ; params ; URI ST`), in the order they appeared.
    public var hyperlinks: [String]

    public var screenText: String { screenLines.joined(separator: "\n") }
    public var plainText: String { plainLines.joined(separator: "\n") }
}

/// A deliberately small terminal emulator: enough of VT100/xterm to follow what a non-full-screen TUI
/// (Claude Code's Ink interface) draws. The screen has no width limit and keeps every line it ever had
/// (no scrolling), which is what we want when the PTY is 4,000 columns wide.
///
/// It is stateless: render the whole output so far each time (it is only a few kilobytes), so escape
/// sequences split across reads never matter.
public enum TerminalRenderer {
    public static func render(_ raw: String) -> RenderedTerminal {
        var state = State()
        let scalars = Array(raw.unicodeScalars)
        var i = 0
        let n = scalars.count

        while i < n {
            let s = scalars[i]
            switch s.value {
            case 0x1B:  // ESC
                guard i + 1 < n else { i = n; break }  // incomplete: wait for more output
                let next = scalars[i + 1]
                switch next {
                case "[":
                    i = state.handleCSI(scalars, from: i + 2)
                case "]":
                    i = state.handleOSC(scalars, from: i + 2)
                case "P", "X", "^", "_":
                    i = skipString(scalars, from: i + 2)  // DCS, SOS, PM, APC: ignored
                case "(", ")", "*", "+", "-", ".", "/", "#", "%", " ":
                    i = min(n, i + 3)  // charset designation and friends: one more byte
                case "7":
                    state.saveCursor(); i += 2
                case "8":
                    state.restoreCursor(); i += 2
                case "c":
                    state.reset(); i += 2
                case "M":
                    state.moveRows(-1); i += 2
                case "D":
                    state.moveRows(1); i += 2
                case "E":
                    state.moveRows(1); state.col = 0; state.plainRowChange(); i += 2
                default:
                    i += 2
                }
            case 0x9B:  // C1 CSI
                i = state.handleCSI(scalars, from: i + 1)
            case 0x0D:  // CR
                state.carriageReturn(); i += 1
            case 0x0A, 0x0B, 0x0C:  // LF, VT, FF
                state.lineFeed(); i += 1
            case 0x08:  // BS
                state.col = max(0, state.col - 1); i += 1
            case 0x09:  // TAB
                state.col = (state.col / 8 + 1) * 8
                state.plainSpace()
                i += 1
            case 0x00..<0x20, 0x7F, 0x80..<0xA0:
                i += 1  // other control characters (BEL, SO, SI, …): nothing to show
            default:
                state.put(s); i += 1
            }
        }
        return state.finish()
    }

    /// Skips a control string up to BEL or ST (`ESC \`), returning the index after it.
    static func skipString(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var j = start
        while j < scalars.count {
            if scalars[j].value == 0x07 { return j + 1 }
            if scalars[j].value == 0x9C { return j + 1 }
            if scalars[j].value == 0x1B, j + 1 < scalars.count, scalars[j + 1] == "\\" { return j + 2 }
            j += 1
        }
        return scalars.count
    }

    private struct State {
        var lines: [[Unicode.Scalar]] = [[]]
        var row = 0
        var col = 0
        var screenTop = 0
        var saved: (row: Int, col: Int)?

        var plainLines: [String] = []
        var plainCurrent = String.UnicodeScalarView()
        /// The current plain line was just ended by a CR, so a following LF must not end another one.
        var endedByCR = false
        var hyperlinks: [String] = []

        // MARK: Screen

        mutating func ensureRow(_ r: Int) {
            while lines.count <= r { lines.append([]) }
        }

        mutating func put(_ s: Unicode.Scalar) {
            ensureRow(row)
            var line = lines[row]
            if col > line.count { line.append(contentsOf: Array(repeating: " ", count: col - line.count)) }
            if col < line.count { line[col] = s } else { line.append(s) }
            lines[row] = line
            col += 1
            plainCurrent.append(s)
            endedByCR = false
        }

        mutating func moveRows(_ delta: Int) {
            row = max(0, row + delta)
        }

        mutating func saveCursor() { saved = (row, col) }

        mutating func restoreCursor() {
            if let saved { row = saved.row; col = saved.col }
        }

        mutating func reset() {
            lines = [[]]; row = 0; col = 0; screenTop = 0; saved = nil
            lineBreak()
        }

        mutating func eraseInLine(_ mode: Int) {
            ensureRow(row)
            switch mode {
            case 0:
                if col < lines[row].count { lines[row].removeSubrange(col...) }
            case 1:
                let upTo = min(col + 1, lines[row].count)
                for k in 0..<upTo { lines[row][k] = " " }
            default:
                lines[row] = []
            }
        }

        mutating func eraseInDisplay(_ mode: Int) {
            ensureRow(row)
            switch mode {
            case 0:
                eraseInLine(0)
                if row + 1 < lines.count { lines.removeSubrange((row + 1)...) }
            case 1:
                for r in screenTop..<row where r < lines.count { lines[r] = [] }
                eraseInLine(1)
            default:
                lines = [[]]
                screenTop = 0
            }
        }

        // MARK: Plain transcript

        mutating func lineBreak() {
            plainLines.append(String(plainCurrent))
            plainCurrent = String.UnicodeScalarView()
        }

        mutating func plainSpace() {
            if let last = plainCurrent.last, last != " " { plainCurrent.append(" ") }
        }

        mutating func carriageReturn() {
            col = 0
            if !plainCurrent.isEmpty {
                lineBreak()
                endedByCR = true
            }
        }

        mutating func lineFeed() {
            row += 1
            col = 0  // a PTY's ONLCR turns LF into CR LF anyway
            if endedByCR {
                endedByCR = false
            } else {
                lineBreak()
            }
        }

        /// A cursor jump to another row ends the plain line, like a line feed would.
        mutating func plainRowChange() {
            if !plainCurrent.isEmpty { lineBreak() }
            endedByCR = false
        }

        // MARK: Escape sequences

        mutating func handleCSI(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
            var j = start
            var paramText = ""
            var privateMarker = false
            while j < scalars.count {
                let v = scalars[j].value
                if (0x30...0x3F).contains(v) {
                    if v == 0x3C || v == 0x3D || v == 0x3E || v == 0x3F { privateMarker = true }  // < = > ?
                    paramText.unicodeScalars.append(scalars[j])
                    j += 1
                } else if (0x20...0x2F).contains(v) {
                    privateMarker = true  // intermediate bytes: nothing we act on
                    j += 1
                } else {
                    break
                }
            }
            guard j < scalars.count else { return scalars.count }  // incomplete
            let final = scalars[j]
            let next = j + 1
            guard (0x40...0x7E).contains(final.value), !privateMarker else { return next }

            let params = paramText.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) }
            func p(_ k: Int, _ def: Int) -> Int {
                guard k < params.count, let v = params[k] else { return def }
                return v
            }
            func count(_ k: Int) -> Int { max(1, p(k, 1)) }

            switch final {
            case "A": moveRows(-count(0)); plainRowChange()
            case "B", "e": moveRows(count(0)); plainRowChange()
            case "C", "a": col += count(0); plainSpace()
            case "D": col = max(0, col - count(0)); plainSpace()
            case "E": moveRows(count(0)); col = 0; plainRowChange()
            case "F": moveRows(-count(0)); col = 0; plainRowChange()
            case "G", "`": col = max(0, count(0) - 1); plainSpace()
            case "d": row = screenTop + max(0, count(0) - 1); plainRowChange()
            case "H", "f":
                row = screenTop + max(0, count(0) - 1)
                col = max(0, count(1) - 1)
                plainRowChange()
            case "K": eraseInLine(p(0, 0))
            case "J": eraseInDisplay(p(0, 0)); if p(0, 0) >= 2 { plainRowChange() }
            case "s": saveCursor()
            case "u": restoreCursor()
            default: break  // SGR (m), scroll regions (r), modes and the rest: no effect on the text
            }
            return next
        }

        mutating func handleOSC(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
            let end = TerminalRenderer.skipString(scalars, from: start)
            // Payload: from start up to the terminator (BEL, ST or ESC \).
            var payloadEnd = end
            if payloadEnd > start {
                if scalars[payloadEnd - 1].value == 0x07 || scalars[payloadEnd - 1].value == 0x9C {
                    payloadEnd -= 1
                } else if payloadEnd - start >= 2, scalars[payloadEnd - 1] == "\\", scalars[payloadEnd - 2].value == 0x1B {
                    payloadEnd -= 2
                } else {
                    return end  // unterminated: wait for more output
                }
            }
            var payload = String.UnicodeScalarView()
            payload.append(contentsOf: scalars[start..<payloadEnd])
            let text = String(payload)
            // OSC 8 ; params ; URI
            if text.hasPrefix("8;") {
                let parts = text.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
                if parts.count == 3, !parts[2].isEmpty { hyperlinks.append(String(parts[2])) }
            }
            return end
        }

        mutating func finish() -> RenderedTerminal {
            var plain = plainLines
            plain.append(String(plainCurrent))
            let screen = lines.map { line -> String in
                var s = String.UnicodeScalarView()
                s.append(contentsOf: line)
                return String(String(s).trimmingTrailingWhitespace())
            }
            return RenderedTerminal(screenLines: screen, plainLines: plain, hyperlinks: hyperlinks)
        }
    }
}

extension String {
    func trimmingTrailingWhitespace() -> Substring {
        var end = endIndex
        while end > startIndex {
            let before = index(before: end)
            if self[before].isWhitespace { end = before } else { break }
        }
        return self[startIndex..<end]
    }
}
