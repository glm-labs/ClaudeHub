import AppKit
import CryptoKit
import Foundation

/// Cursor's command-line agent, and what ClaudeHub reads from Cursor around it.
///
/// The agent keeps each chat in `~/.cursor/chats/<md5 of the folder>/<id>/`,
/// with a `meta.json` that names it, and writes the conversation itself out to
/// `~/.cursor/projects/<folder>/agent-transcripts/<id>/<id>.jsonl`. Both are
/// read, never written: the only thing ClaudeHub does to Cursor's files is a
/// delete you asked for, and a name you give a chat here stays here.
enum CursorAgent {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static var chatsRoot: URL { home.appendingPathComponent(".cursor/chats") }
    static var projectsRoot: URL { home.appendingPathComponent(".cursor/projects") }

    /// The Cursor editor's own sign-in, which the agent and the usage numbers
    /// both run on.
    static var stateDatabase: URL {
        home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    /// Where the editor keeps the agent it runs for itself.
    private static var editorAgent: URL {
        home.appendingPathComponent(
            "Library/Application Support/Cursor/User/globalStorage/anysphere.cursor-agent-worker/agent-cli/.local")
    }

    /// The agent: a standalone install first (`curl https://cursor.com/install
    /// | bash`), because that one updates itself, else the copy the Cursor
    /// editor keeps. Looked up every time, since the editor swaps its copy out
    /// for a newer version folder when it updates.
    static var binary: String? {
        let fm = FileManager.default
        let candidates = [
            home.appendingPathComponent(".local/bin/cursor-agent").path,
            "/opt/homebrew/bin/cursor-agent",
            "/usr/local/bin/cursor-agent",
            editorAgent.appendingPathComponent("bin/cursor-agent").path,
        ]
        if let found = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return found }
        let versions = editorAgent.appendingPathComponent("share/cursor-agent/versions")
        let dirs = (try? fm.contentsOfDirectory(atPath: versions.path)) ?? []
        return dirs.sorted(by: >)
            .map { versions.appendingPathComponent($0).appendingPathComponent("cursor-agent").path }
            .first { fm.isExecutableFile(atPath: $0) }
    }

    /// Whether the menus offer Cursor at all. Settled once per launch.
    static let isInstalled = binary != nil

    /// The Cursor editor, for "Open in Cursor".
    static let editorURL: URL? =
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92")

    static func openInEditor(_ path: String) {
        guard let editorURL else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)],
                                withApplicationAt: editorURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Signing in

    private static let tokenLock = NSLock()
    private static var token: String?

    /// The token last read, for starting a chat. Never read here: a `sqlite3`
    /// call in the middle of laying out a tab is a stall you can see.
    static var cachedToken: String? {
        tokenLock.lock()
        defer { tokenLock.unlock() }
        return token
    }

    /// Reads the editor's access token, and keeps it for the next chat that
    /// starts. Off the main thread: it runs `sqlite3`. The editor renews the
    /// token as it goes, so this is asked again with every usage reading
    /// rather than once.
    @discardableResult
    static func readToken() -> String? {
        let db = stateDatabase.path
        guard FileManager.default.fileExists(atPath: db) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", db,
                             "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken';"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        let found = value.isEmpty ? nil : value
        tokenLock.lock()
        token = found
        tokenLock.unlock()
        return found
    }

    // MARK: - Starting

    /// What a Cursor tab runs: the agent in the tab's folder. `--trust` skips
    /// the "trust this folder?" question and `--auto-review` is Cursor's auto
    /// mode — safe actions run by themselves, so the prompt is for typing
    /// rather than for pressing Accept. No `--model`: the agent remembers what
    /// `/model` last chose, as Claude Code does, and a flag here would
    /// override that every time.
    static func command(chat: String?) -> String? {
        guard let binary else { return nil }
        var command = "exec \(ClaudeSession.shellQuote(binary)) --trust --auto-review"
        if let chat { command += " --resume \(ClaudeSession.shellQuote(chat))" }
        return command
    }

    // MARK: - Chats on disk

    /// One chat as the agent describes it in its `meta.json`.
    struct Chat {
        let id: String
        let title: String?
        let cwd: String
        let created: Date
        let updated: Date
        /// False for an agent that was started and left without a message.
        let hasConversation: Bool
        let folder: URL
    }

    /// The agent files a folder's chats under the MD5 of its path.
    static func folderKey(_ path: String) -> String {
        Insecure.MD5.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func chats(in cwd: String? = nil) -> [Chat] {
        let fm = FileManager.default
        let groups = cwd.map { [chatsRoot.appendingPathComponent(folderKey($0))] }
            ?? ((try? fm.contentsOfDirectory(at: chatsRoot, includingPropertiesForKeys: nil)) ?? [])
        var found: [Chat] = []
        for group in groups {
            guard let ids = try? fm.contentsOfDirectory(at: group, includingPropertiesForKeys: nil) else { continue }
            for folder in ids {
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
                      let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let path = meta["cwd"] as? String, !path.isEmpty else { continue }
                let created = (meta["createdAtMs"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                let updated = (meta["updatedAtMs"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                found.append(Chat(
                    id: folder.lastPathComponent,
                    title: (meta["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                    cwd: path,
                    created: created ?? updated ?? .distantPast,
                    updated: updated ?? created ?? .distantPast,
                    hasConversation: meta["hasConversation"] as? Bool ?? false,
                    folder: folder
                ))
            }
        }
        return found
    }

    /// The chat a freshly started agent made for itself.
    ///
    /// The agent picks its chat's id and creates the folder a moment after it
    /// starts, and says nothing about it on screen. So a new Cursor tab watches
    /// its folder for a chat that appeared after it launched and no other tab
    /// has claimed — which is what lets the sidebar row and the tab be the same
    /// chat, rather than a click on the row resuming it a second time.
    static func newChat(in cwd: String, since: Date, excluding taken: Set<String>) -> String? {
        chats(in: cwd)
            .filter { $0.created >= since.addingTimeInterval(-2) && !taken.contains($0.id) }
            .min { $0.created < $1.created }?
            .id
    }

    /// Every Cursor chat with something in it, as sidebar rows.
    static func sessions() -> [ClaudeSession] {
        let transcripts = transcriptIndex()
        let named = Self.names
        return chats().compactMap { chat in
            guard chat.hasConversation else { return nil }
            let transcript = transcripts[chat.id]
            let title = named[chat.id]
                ?? chat.title
                ?? transcript.flatMap(firstQuery(in:))
                ?? "Cursor chat \(chat.id.prefix(8))"
            return ClaudeSession(id: chat.id,
                                 title: title,
                                 cwd: chat.cwd,
                                 lastActivity: chat.updated,
                                 fileURL: chat.folder,
                                 agent: .cursor,
                                 cursorTranscript: transcript)
        }
    }

    /// Chat id → transcript, across every folder the agent has written to.
    private static func transcriptIndex() -> [String: URL] {
        let fm = FileManager.default
        var index: [String: URL] = [:]
        let projects = (try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil)) ?? []
        for project in projects {
            let root = project.appendingPathComponent("agent-transcripts")
            guard let ids = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            for id in ids {
                let file = root.appendingPathComponent(id).appendingPathComponent("\(id).jsonl")
                if fm.fileExists(atPath: file.path) { index[id] = file }
            }
        }
        return index
    }

    /// The first thing you asked, for a chat Cursor has not named yet.
    private static func firstQuery(in transcript: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 64 * 1024)) ?? Data(), as: UTF8.self)
        for line in head.split(separator: "\n") where line.contains("\"role\":\"user\"") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  let text = spokenText(of: message["content"]) else { continue }
            let first = text.split(separator: "\n").first.map(String.init) ?? text
            return first.count > 80 ? String(first.prefix(77)) + "…" : first
        }
        return nil
    }

    /// What was actually said in a message: its text blocks, with the
    /// `<timestamp>` and `<user_query>` wrapping the agent puts around yours
    /// taken off.
    static func spokenText(of content: Any?) -> String? {
        var text: String
        if let plain = content as? String {
            text = plain
        } else if let blocks = content as? [[String: Any]] {
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
        } else {
            return nil
        }
        if let start = text.range(of: "<user_query>"),
           let end = text.range(of: "</user_query>", range: start.upperBound..<text.endIndex) {
            text = String(text[start.upperBound..<end.lowerBound])
        }
        text = text.replacingOccurrences(of: #"<timestamp>.*?</timestamp>"#, with: "",
                                         options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    // MARK: - Names

    /// Names given to Cursor chats here. The agent rewrites its `meta.json` as
    /// the chat goes on, so a name written into it would last until the next
    /// answer; this one lasts. Cursor's own list keeps the name it chose.
    static var names: [String: String] {
        UserDefaults.standard.dictionary(forKey: "cursorChatNames") as? [String: String] ?? [:]
    }

    static func setName(_ name: String, for id: String) {
        var all = names
        all[id] = name.isEmpty ? nil : name
        UserDefaults.standard.set(all, forKey: "cursorChatNames")
    }

    static func forgetNames(_ ids: Set<String>) {
        let all = names
        guard !all.keys.allSatisfy({ !ids.contains($0) }) else { return }
        UserDefaults.standard.set(all.filter { !ids.contains($0.key) }, forKey: "cursorChatNames")
    }
}

extension Notification.Name {
    /// A Cursor chat came into being or answered: worth a rescan, since the
    /// agent names its chats only once there is something to name.
    static let cursorChatsChanged = Notification.Name("ClaudeHub.cursorChatsChanged")
    static let newCursorChatInFolder = Notification.Name("ClaudeHub.newCursorChatInFolder")
}
