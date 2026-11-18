import Foundation

/// Finds the path or URL a ⌘-click landed on, including one that Claude Code
/// broke over several rows.
///
/// Claude Code wraps its own output. A path longer than the room left on a row
/// is cut at the edge and carried on at the start of the next row, behind the
/// same indentation. For the terminal those are two separate lines: nothing
/// marks the second as the rest of the first. Reading only the row under the
/// pointer then gives half a path, `…/app_overzi` or `cht.png`, and neither
/// exists.
///
/// So a piece is followed onto the next row when it runs to the edge with
/// nothing after it, and onto the previous row when it is the first thing on
/// its own row and the row above ends at the edge. That guess can be wrong: a
/// short path can end at the edge with an ordinary word under it. The joined
/// link therefore comes first and the piece under the pointer second, and the
/// caller passes over one that does not exist.
enum WrappedLink {
    /// How close to the last column a piece must end to count as cut off.
    /// Claude Code may leave the last column or two empty.
    static let slack = 2
    /// A path over more rows than this is not a path.
    private static let maxRows = 8

    private static let pathCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "_-./~:@+%#?=&"))
    private static let scheme = try! NSRegularExpression(pattern: "^[A-Za-z][A-Za-z0-9+.-]*://")

    /// A run of path characters on one row, by character index.
    private struct Piece {
        let start: Int
        let end: Int
        let text: String
    }

    /// The links a click at `col` on `row` may mean, most likely first.
    /// `line` gives a row's text, or nil past the top or bottom of the screen.
    static func candidates(row: Int, col: Int, width: Int, line: (Int) -> String?) -> [String] {
        guard let text = line(row) else { return [] }
        let chars = Array(text)
        guard !chars.isEmpty,
              let here = piece(in: chars, around: min(max(col, 0), chars.count - 1)) else { return [] }
        var joined = here.text

        // On down, while each piece reaches the edge.
        var below = (row: row, chars: chars, piece: here)
        while below.row - row < maxRows,
              endsAtEdge(below.piece, in: below.chars, width: width),
              let next = line(below.row + 1).map(Array.init),
              let first = firstNonSpace(next),
              let piece = piece(in: next, around: first),
              !startsWithScheme(piece.text) {
            joined += piece.text
            below = (below.row + 1, next, piece)
        }

        // On up, while each piece is the first thing on its row. A URL starts
        // at its scheme: nothing comes before it.
        var above = (row: row, chars: chars, piece: here)
        while row - above.row < maxRows,
              !startsWithScheme(joined),
              firstNonSpace(above.chars) == above.piece.start,
              let previous = line(above.row - 1).map(Array.init),
              let last = lastNonSpace(previous),
              let piece = piece(in: previous, around: last),
              endsAtEdge(piece, in: previous, width: width) {
            joined = piece.text + joined
            above = (above.row - 1, previous, piece)
        }

        var result: [String] = []
        for candidate in [joined, here.text].compactMap(tidy) where !result.contains(candidate) {
            result.append(candidate)
        }
        return result
    }

    /// The run of path characters around `col`, or nil when `col` is not on one.
    private static func piece(in chars: [Character], around col: Int) -> Piece? {
        guard col >= 0, col < chars.count, isPathCharacter(chars[col]) else { return nil }
        var start = col
        var end = col
        while start > 0, isPathCharacter(chars[start - 1]) { start -= 1 }
        while end + 1 < chars.count, isPathCharacter(chars[end + 1]) { end += 1 }
        return Piece(start: start, end: end, text: String(chars[start...end]))
    }

    /// The last thing on its row, and close enough to the edge to have been
    /// cut there.
    private static func endsAtEdge(_ piece: Piece, in chars: [Character], width: Int) -> Bool {
        lastNonSpace(chars) == piece.end && piece.end >= width - 1 - slack
    }

    /// With the punctuation a sentence hangs on it taken off. Nil unless it
    /// looks like a path or URL.
    private static func tidy(_ text: String) -> String? {
        var token = text
        while let last = token.last, ".,;:)]}'\"".contains(last) { token.removeLast() }
        guard token.contains("/") || token.contains(".") else { return nil }
        return token
    }

    static func startsWithScheme(_ text: String) -> Bool {
        scheme.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func isPathCharacter(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { pathCharacters.contains($0) }
    }

    private static func firstNonSpace(_ chars: [Character]) -> Int? {
        chars.firstIndex { !$0.isWhitespace }
    }

    private static func lastNonSpace(_ chars: [Character]) -> Int? {
        chars.lastIndex { !$0.isWhitespace }
    }
}
