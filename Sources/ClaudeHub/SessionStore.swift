import Foundation
import Combine

final class SessionStore: ObservableObject {
    /// The sessions open in a tab, kept by `TabsModel`. Used to decide whether
    /// a transcript that holds no messages is a live session or a leftover.
    static var openSessionIDs: Set<String> = []

    @Published var projects: [ClaudeProject] = []
    @Published var isLoading = false

    private let projectsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        let root = projectsRoot
        DispatchQueue.global(qos: .userInitiated).async {
            let projects = Self.scan(root: root)
            DispatchQueue.main.async {
                self.projects = projects
                self.isLoading = false
            }
        }
    }

    /// A brand-new session only lands on disk once Claude has written its
    /// first lines — give it a moment, then pick it up in the sidebar.
    func refreshSoon(after seconds: TimeInterval = 6) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.refresh()
        }
    }

    /// Hidden sessions stay on disk (still resumable), they just leave the list.
    @Published var hiddenSessionIDs: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "hiddenSessionIDs") ?? [])

    func setHidden(_ session: ClaudeSession, _ hidden: Bool) {
        if hidden {
            hiddenSessionIDs.insert(session.id)
        } else {
            hiddenSessionIDs.remove(session.id)
        }
        persistHidden()
    }

    private func persistHidden() {
        UserDefaults.standard.set(Array(hiddenSessionIDs), forKey: "hiddenSessionIDs")
    }

    // MARK: - Pinning

    /// Pinned chats sit at the top of their project, above everything the last
    /// hour of work pushed up there. Nothing else about them changes: the pin
    /// is ours, the transcript on disk knows nothing about it.
    @Published var pinnedSessionIDs: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "pinnedSessionIDs") ?? [])

    func setPinned(_ session: ClaudeSession, _ pinned: Bool) {
        if pinned {
            pinnedSessionIDs.insert(session.id)
        } else {
            pinnedSessionIDs.remove(session.id)
        }
        persistPinned()
    }

    /// Pinned first, and within each half the order they already had — the most
    /// recently active first.
    func ordered(_ sessions: [ClaudeSession]) -> [ClaudeSession] {
        guard !pinnedSessionIDs.isEmpty else { return sessions }
        let pinned = sessions.filter { pinnedSessionIDs.contains($0.id) }
        guard !pinned.isEmpty else { return sessions }
        return pinned + sessions.filter { !pinnedSessionIDs.contains($0.id) }
    }

    private func persistPinned() {
        UserDefaults.standard.set(Array(pinnedSessionIDs), forKey: "pinnedSessionIDs")
    }

    // MARK: - Deleting

    /// Deletes sessions for real: the transcript and its sidecar files go to
    /// the Trash, so a mis-click stays recoverable in Finder.
    /// Returns the sessions that could not be deleted.
    @discardableResult
    func delete(_ sessions: [ClaudeSession]) -> [ClaudeSession] {
        var deleted: Set<String> = []
        var failed: [ClaudeSession] = []

        for session in sessions {
            if Self.trashArtifacts(of: session) {
                deleted.insert(session.id)
            } else {
                failed.append(session)
            }
        }

        guard !deleted.isEmpty else { return failed }

        projects = projects.compactMap { project in
            var copy = project
            copy.sessions.removeAll { deleted.contains($0.id) }
            return copy.sessions.isEmpty ? nil : copy
        }
        if !hiddenSessionIDs.isDisjoint(with: deleted) {
            hiddenSessionIDs.subtract(deleted)
            persistHidden()
        }
        if !pinnedSessionIDs.isDisjoint(with: deleted) {
            pinnedSessionIDs.subtract(deleted)
            persistPinned()
        }
        return failed
    }

    /// The transcript is what makes a session resumable — if that fails to
    /// move, the delete failed. The sidecars are best-effort cleanup.
    private static func trashArtifacts(of session: ClaudeSession) -> Bool {
        let fm = FileManager.default
        do {
            try fm.trashItem(at: session.fileURL, resultingItemURL: nil)
        } catch {
            return false
        }
        for url in session.artifactURLs.dropFirst() where fm.fileExists(atPath: url.path) {
            try? fm.trashItem(at: url, resultingItemURL: nil)
        }
        return true
    }

    private static func scan(root: URL) -> [ClaudeProject] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }

        var byCwd: [String: [ClaudeSession]] = [:]
        for dir in dirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
            ) else { continue }

            // Two passes. A session that has only just started, or whose
            // messages are held elsewhere by a bridge, writes a transcript with
            // its state and no messages — and so no `cwd`, which is what a
            // session is filed under. Dropping those is why a brand-new session
            // could sit in a tab, running, and never appear in this list. Its
            // neighbours in the same folder know the cwd, so the second pass
            // borrows it.
            var found: [ClaudeSession] = []
            var withoutFolder: [URL] = []
            for file in files where file.pathExtension == "jsonl" {
                if let session = parseSession(file: file) {
                    found.append(session)
                } else {
                    withoutFolder.append(file)
                }
            }
            // Only for a session you have open right now. A transcript with no
            // messages is either a session whose messages are held elsewhere —
            // worth showing, because it is running in front of you — or the
            // husk of one that is gone, which `--resume` cannot open and which
            // has no business coming back into the list after you deleted it.
            if let cwd = found.first?.cwd {
                for file in withoutFolder {
                    let id = file.deletingPathExtension().lastPathComponent
                    guard openSessionIDs.contains(id),
                          let session = parseSession(file: file, fallbackCwd: cwd) else { continue }
                    found.append(session)
                }
            }
            for session in found {
                byCwd[session.cwd, default: []].append(session)
            }
        }

        return byCwd.map { cwd, sessions in
            ClaudeProject(
                id: cwd,
                name: projectName(for: cwd),
                path: cwd,
                sessions: sessions.sorted { $0.lastActivity > $1.lastActivity }
            )
        }
        .sorted { $0.lastActivity > $1.lastActivity }
    }

    private static func projectName(for cwd: String) -> String {
        let comps = cwd.split(separator: "/").map(String.init)
        guard let last = comps.last else { return cwd }
        // Prefix with parent folder when the last component is generic-ish or for context
        if comps.count >= 2 {
            let parent = comps[comps.count - 2]
            if ["frontend", "backend", "src", "app", "web", "api", "portal"].contains(last.lowercased()) {
                return "\(parent)/\(last)"
            }
        }
        return last
    }

    // MARK: - JSONL parsing

    /// Enough of the start of a transcript to read its opening state, and
    /// enough of the end to read where the conversation got to.
    private static let headLength = 256 * 1024
    private static let tailLength = 64 * 1024
    /// How far past the head `findCwd` keeps looking before giving up. Well
    /// past any run of pasted images, and far short of reading a whole
    /// multi-gigabyte transcript.
    private static let cwdScanLimit = 32 * 1024 * 1024

    private static func parseSession(file: URL, fallbackCwd: String? = nil) -> ClaudeSession? {
        let id = file.deletingPathExtension().lastPathComponent
        // Session transcripts are named by UUID; skip anything else (e.g. agent sidechains)
        guard UUID(uuidString: id) != nil else { return nil }

        guard let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let mtime = attrs.contentModificationDate,
              let size = attrs.fileSize, size > 0 else { return nil }

        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        let headData = (try? handle.read(upToCount: headLength)) ?? Data()
        let head = String(decoding: headData, as: UTF8.self)

        var tail = ""
        if size > headLength {
            try? handle.seek(toOffset: UInt64(max(0, size - tailLength)))
            if let tailData = try? handle.readToEnd() {
                tail = String(decoding: tailData, as: UTF8.self)
            }
        }

        // Below the head limit, `head` already is the whole file. Above it,
        // only `tail` reaches the end — and it starts mid-line.
        let body = tail.isEmpty ? head : tail
        let partial = !tail.isEmpty

        // Sidechain (subagent) transcripts live alongside main sessions in old versions — skip them.
        if firstJSONValue(in: head, key: "isSidechain") == "true" { return nil }

        // cwd is what a session is filed under. Without one in the file, the
        // folder it sits in speaks for it — but only for a session that has
        // something to show for itself.
        let named = findCwd(in: handle, head: head, size: size)
        guard let cwd = named ?? fallbackCwd else { return nil }

        let title = lastJSONString(in: tail, key: "aiTitle")
            ?? lastJSONString(in: head, key: "aiTitle")
            ?? firstUserPrompt(in: head)
        guard let title = title ?? (named != nil ? "Session \(id.prefix(8))" : nil) else {
            // No folder of its own and nothing to call it: an empty shell.
            return nil
        }

        // The mtime says when the file was last *touched*, which is not the
        // same question: opening or resuming a session rewrites its transcript,
        // and a housekeeping pass can stamp a dozen of them within one second.
        // A week-old chat then climbs to the top of the list looking minutes
        // old. The transcript timestamps every line it writes, so the honest
        // answer is already inside the bytes we are holding — no second read.
        let lastActivity = lastTimestamp(in: body, partial: partial, answersOnly: true)
            ?? lastTimestamp(in: body, partial: partial, answersOnly: false)
            ?? mtime

        return ClaudeSession(
            id: id,
            title: title,
            cwd: cwd,
            lastActivity: lastActivity,
            fileURL: file
        )
    }

    /// The last line the model actually wrote. Scanning backwards stops at the
    /// first hit, so this costs a handful of string compares over a slice that
    /// is already in memory.
    ///
    /// `answersOnly` is the strict reading — a transcript can pick up trailing
    /// bookkeeping lines long after the conversation ended, and those are not
    /// an answer. It falls back to any timestamped line for the rare session
    /// whose last answer sits further back than the tail we read.
    ///
    /// Sidechain lines are a subagent talking to itself, never to the user.
    private static func lastTimestamp(in text: String,
                                      partial: Bool,
                                      answersOnly: Bool) -> Date? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        // A slice taken from the middle of the file opens on half a line.
        if partial, !lines.isEmpty { lines.removeFirst() }

        for line in lines.reversed() {
            if line.contains("\"isSidechain\":true") { continue }
            if answersOnly, !line.contains("\"type\":\"assistant\"") { continue }
            guard let stamp = firstJSONString(in: String(line), key: "timestamp"),
                  let date = isoDate(stamp) else { continue }
            return date
        }
        return nil
    }

    private static let isoWithMilliseconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoWholeSeconds = ISO8601DateFormatter()

    private static func isoDate(_ text: String) -> Date? {
        isoWithMilliseconds.date(from: text) ?? isoWholeSeconds.date(from: text)
    }

    /// The folder a session started in: the `cwd` on the first line that names
    /// one.
    ///
    /// Usually that line sits within the first few kilobytes. But a chat that
    /// opens with a pasted screenshot writes the image inline — one line of
    /// base64 that can run to hundreds of kilobytes and carries the folder past
    /// the head we read. A session filed under nothing drops out of the sidebar
    /// completely, transcript and all, so when the head comes up empty, keep
    /// reading rather than give up on it.
    ///
    /// It has to be the *first* one. Later lines carry a `cwd` too, but that is
    /// wherever the session had walked to by then — a subfolder, or a scratch
    /// directory outside the project altogether — and filing a session there
    /// would only move it out of sight a second way.
    private static func findCwd(in handle: FileHandle, head: String, size: Int) -> String? {
        if let cwd = completeJSONString(in: head, key: "cwd") { return cwd }
        guard size > headLength else { return nil }

        var offset = UInt64(headLength)
        let limit = UInt64(min(size, cwdScanLimit))
        // A chunk boundary can fall inside the key, or inside the path itself,
        // so every read starts again a little before the last one ended.
        var carry = ""
        while offset < limit {
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.read(upToCount: headLength),
                  !data.isEmpty else { return nil }
            let chunk = carry + String(decoding: data, as: UTF8.self)
            if let cwd = completeJSONString(in: chunk, key: "cwd") { return cwd }
            carry = String(chunk.suffix(4096))
            offset += UInt64(data.count)
        }
        return nil
    }

    /// `firstJSONString`, minus the values that run off the end of the text they
    /// were found in: a path cut in half by a chunk boundary is not a path.
    private static func completeJSONString(in text: String, key: String) -> String? {
        guard let range = text.range(of: "\"\(key)\":\""),
              text[range.upperBound...].contains("\"") else { return nil }
        return firstJSONString(in: text, key: key).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Extracts the raw token following `"key":` (for booleans/numbers).
    private static func firstJSONValue(in text: String, key: String) -> String? {
        guard let range = text.range(of: "\"\(key)\":") else { return nil }
        let rest = text[range.upperBound...].prefix(8)
        if rest.hasPrefix("true") { return "true" }
        if rest.hasPrefix("false") { return "false" }
        return nil
    }

    private static func firstJSONString(in text: String, key: String) -> String? {
        extractString(in: text, key: key, fromEnd: false)
    }

    private static func lastJSONString(in text: String, key: String) -> String? {
        extractString(in: text, key: key, fromEnd: true)
    }

    private static func extractString(in text: String, key: String, fromEnd: Bool) -> String? {
        let needle = "\"\(key)\":\""
        let range = fromEnd
            ? text.range(of: needle, options: .backwards)
            : text.range(of: needle)
        guard let range else { return nil }

        var raw = ""
        var escaped = false
        for ch in text[range.upperBound...] {
            if escaped {
                raw.append("\\")
                raw.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" { escaped = true; continue }
            if ch == "\"" { break }
            raw.append(ch)
        }
        // Decode JSON string escapes by round-tripping through JSONSerialization
        if let data = "[\"\(raw)\"]".data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String],
           let decoded = arr.first {
            return decoded.isEmpty ? nil : decoded
        }
        return raw.isEmpty ? nil : raw
    }

    private static func firstUserPrompt(in head: String) -> String? {
        for line in head.split(separator: "\n") {
            guard line.contains("\"type\":\"user\""),
                  !line.contains("\"isMeta\":true"),
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = obj["message"] as? [String: Any] else { continue }

            var text: String?
            if let s = message["content"] as? String {
                text = s
            } else if let parts = message["content"] as? [[String: Any]] {
                text = parts.first { $0["type"] as? String == "text" }?["text"] as? String
            }
            guard var t = text else { continue }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip slash-command noise and system-injected content
            if t.isEmpty || t.hasPrefix("<") { continue }
            let firstLine = t.split(separator: "\n").first.map(String.init) ?? t
            return firstLine.count > 80 ? String(firstLine.prefix(77)) + "…" : firstLine
        }
        return nil
    }
}
