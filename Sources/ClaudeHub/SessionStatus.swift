import Foundation

/// What Claude Code itself says a session is doing.
///
/// Every running `claude` keeps a small record in `~/.claude/sessions/<pid>.json`
/// and rewrites its `status` the moment that changes: `busy` while it answers,
/// and for as long as agents it sent off are still out; `waiting` while a
/// question, a permission prompt or another dialog waits for you; `shell` once
/// the answer is done but a command it left running in the background is not;
/// `idle` when there is nothing at all.
///
/// The screen is a poor witness to the same thing. "esc to interrupt" is not on
/// it while you have scrolled back to read, nor while Esc would go to the agent
/// list under the prompt, nor in a frame caught halfway through being redrawn.
/// Each of those passed for a quiet session, and an account switch waiting for
/// one restarted it in the middle of an answer.
///
/// The record is not a documented interface, so it is only ever used to keep a
/// session where it is, never to move one: no record, or a status this code
/// does not know, leaves the decision to the screen as before.
enum SessionStatus: Equatable {
    case busy
    /// What it waits for, in Claude Code's words: "permission prompt",
    /// "input needed", "dialog open", …
    case waiting(String?)
    case shell
    case idle

    /// The record of the `claude` process `pid`, if it wrote one and it is
    /// that process's own — not one left behind by an earlier process that had
    /// the same pid, which is why it must not predate `launched`.
    static func read(pid: pid_t, launched: Date?) -> SessionStatus? {
        guard pid > 0 else { return nil }
        let file = directory.appendingPathComponent("\(pid).json")
        guard let data = try? Data(contentsOf: file),
              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (record["pid"] as? NSNumber)?.int32Value == pid else { return nil }
        if let launched, let started = (record["startedAt"] as? NSNumber)?.doubleValue,
           Date(timeIntervalSince1970: started / 1000) < launched.addingTimeInterval(-5) {
            return nil
        }
        switch record["status"] as? String {
        case "busy": return .busy
        case "waiting": return .waiting(record["waitingFor"] as? String)
        case "shell": return .shell
        case "idle": return .idle
        default: return nil
        }
    }

    private static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/sessions", isDirectory: true)
}
