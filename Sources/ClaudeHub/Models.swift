import Foundation

/// Which command-line agent a conversation belongs to.
enum ChatAgent: Hashable {
    case claude
    case cursor
}

struct ClaudeSession: Identifiable, Hashable {
    let id: String          // session UUID (jsonl filename)
    var title: String
    let cwd: String
    /// When Claude last answered here — read from the transcript, not from
    /// the file's mtime, which every open, resume or background pass bumps.
    let lastActivity: Date
    /// Claude's transcript. For a Cursor chat, the chat's own folder: that is
    /// what `--resume` opens, and the readable transcript lives elsewhere.
    let fileURL: URL
    var agent: ChatAgent = .claude
    /// Where the Cursor agent writes this chat's conversation out, if it has.
    var cursorTranscript: URL? = nil

    var isCursor: Bool { agent == .cursor }

    /// The conversation as text, for searching it.
    var transcriptURL: URL? { isCursor ? cursorTranscript : fileURL }

    var resumeCommand: String {
        "cd \(ClaudeSession.shellQuote(cwd)) && claude --resume \(id)"
    }

    /// Everything Claude Code keeps for this session: the transcript, the
    /// sidecar folder next to it (tool results), and the session's env dir.
    /// Deleting a chat should not leave these behind.
    var artifactURLs: [URL] {
        // A Cursor chat is its folder, which holds what resuming needs, and
        // the transcript folder the agent writes beside the project.
        if isCursor {
            return [fileURL] + [cursorTranscript?.deletingLastPathComponent()].compactMap { $0 }
        }
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
