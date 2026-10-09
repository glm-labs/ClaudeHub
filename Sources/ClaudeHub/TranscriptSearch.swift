import Foundation

/// One line of the conversation that matched.
struct TranscriptMatch: Identifiable, Equatable {
    let id: Int
    /// "You" or "Claude" — who wrote it.
    let role: String
    let date: Date?
    /// The line the term is on, for the result list.
    let line: String
    /// The whole message, for when the line alone is not enough.
    let full: String
}

/// Searches a session's transcript rather than its screen.
///
/// The terminal only holds what is still on screen and in its scrollback, and a
/// session that has been running all evening has scrolled most of itself away —
/// searching it finds the last few screens and nothing else. Claude Code writes
/// every message to a `.jsonl` file as it goes, so that is where the
/// conversation actually is, all of it, including what came before this tab was
/// even opened.
enum TranscriptSearch {
    /// Memory stays flat however large the transcript is: the file is mapped
    /// rather than loaded, a line is only JSON-parsed when its raw text already
    /// contains the term, and each line's objects are released before the next.
    /// Loading and parsing everything up front held hundreds of megabytes per
    /// search on a 100 MB transcript, and searches typed in quick succession
    /// stacked those up into gigabytes.
    static func search(_ term: String, in url: URL, limit: Int = 300,
                       isCancelled: () -> Bool = { false }) -> [TranscriptMatch] {
        guard !term.isEmpty,
              let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return [] }
        var matches: [TranscriptMatch] = []
        var index = 0
        var start = data.startIndex
        let newline = UInt8(ascii: "\n")

        while start < data.endIndex, matches.count < limit {
            if isCancelled() { return [] }
            let end = data[start...].firstIndex(of: newline) ?? data.endIndex
            defer { start = end + 1 }
            guard end > start else { continue }

            autoreleasepool {
                let raw = data[start..<end]
                // Cheap test first: the vast majority of lines never get parsed.
                let text = String(decoding: raw, as: UTF8.self)
                guard text.localizedCaseInsensitiveContains(term),
                      let entry = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
                else { return }

                let kind = entry["type"] as? String
                guard kind == "user" || kind == "assistant" else { return }
                // A sidechain is a subagent talking to itself, never to you.
                guard entry["isSidechain"] as? Bool != true else { return }
                guard let message = entry["message"] as? [String: Any],
                      let body = Self.text(of: message["content"]), !body.isEmpty,
                      body.localizedCaseInsensitiveContains(term) else { return }

                let date = (entry["timestamp"] as? String).flatMap(Self.date)
                let role = kind == "user" ? "You" : "Claude"
                for line in body.split(separator: "\n", omittingEmptySubsequences: true)
                where line.localizedCaseInsensitiveContains(term) {
                    matches.append(TranscriptMatch(id: index,
                                                   role: role,
                                                   date: date,
                                                   line: line.trimmingCharacters(in: .whitespaces),
                                                   full: body))
                    index += 1
                    if matches.count >= limit { break }
                }
            }
        }
        return matches
    }

    /// A user message is a string; an assistant message is a list of blocks,
    /// of which only the spoken ones are worth searching — thinking and tool
    /// calls are the session's working out, not what it said.
    private static func text(of content: Any?) -> String? {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let spoken = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
        return spoken.isEmpty ? nil : spoken.joined(separator: "\n")
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func date(_ text: String) -> Date? {
        formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
