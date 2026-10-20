import Foundation

struct ClaudeSession: Identifiable, Hashable {
    let id: String          // session UUID (jsonl filename)
    var title: String
    let cwd: String
    /// When Claude last answered here — read from the transcript, not from
    /// the file's mtime, which every open, resume or background pass bumps.
    let lastActivity: Date
    let fileURL: URL

    var resumeCommand: String {
        "cd \(ClaudeSession.shellQuote(cwd)) && claude --resume \(id)"
    }

    /// Everything Claude Code keeps for this session: the transcript, the
    /// sidecar folder next to it (tool results), and the session's env dir.
    /// Deleting a chat should not leave these behind.
    var artifactURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            fileURL,
            fileURL.deletingPathExtension(),                                  // <uuid>/ sidecar
            home.appendingPathComponent(".claude/session-env/\(id)"),
        ]
    }

    /// Where Claude Code keeps the name you gave the chat, next to the
    /// transcript, so the name outlives the transcript's tail moving on.
    var customTitleURL: URL {
        fileURL.deletingPathExtension().appendingPathComponent("custom-title.json")
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct ClaudeProject: Identifiable, Hashable {
    let id: String          // cwd
    let name: String
    let path: String
    var sessions: [ClaudeSession]

    var lastActivity: Date { sessions.map(\.lastActivity).max() ?? .distantPast }
}
