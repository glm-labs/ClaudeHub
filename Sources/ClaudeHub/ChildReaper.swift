import Foundation
import SwiftTerm

/// Ends a terminal's child process and collects its exit status.
///
/// SwiftTerm's `terminate()` sends SIGTERM and then cancels the monitor that
/// would have reaped the child, so nothing is left to call `waitpid` and the
/// dead process keeps its slot in the process table. A closed tab leaves one;
/// the hidden `/usage` session, restarted every minute while it could not read
/// the panel, left fourteen hundred a day. At the 6,000-process limit nothing
/// on the Mac can start a process any more, not even `/bin/sh`.
///
/// Every terminal ClaudeHub ends goes through here. The collecting runs on its
/// own queue and clock, so it does not wait on any one caller to poll.
enum ChildReaper {
    private static let queue = DispatchQueue(label: "be.optimize.claudehub.reaper")
    /// Children sent SIGTERM and not collected yet, with when they were sent it.
    private static var pending: [pid_t: Date] = [:]
    private static var timer: DispatchSourceTimer?
    /// A child still there this long after SIGTERM gets SIGKILL.
    private static let grace: TimeInterval = 10

    static func terminate(_ view: LocalProcessTerminalView) {
        // Read both before terminate(), which marks the process stopped. A
        // child that already exited was collected by SwiftTerm's own monitor,
        // and its pid may by now belong to another child of ours.
        let pid = view.process.shellPid
        let live = view.process.running
        view.terminate()
        guard live, pid > 0 else { return }
        collect(pid)
    }

    /// Collects `pid` once it has exited. It must be a child of this process
    /// that nothing else will wait for.
    static func collect(_ pid: pid_t) {
        queue.async {
            pending[pid] = Date()
            sweep()
        }
    }

    /// Non-blocking: a child still on its way out waits for the next beat.
    /// Anything but 0 — collected now, or not ours to collect — is done with.
    private static func sweep() {
        var status: Int32 = 0
        let now = Date()
        for (pid, since) in pending {
            if waitpid(pid, &status, WNOHANG) != 0 {
                pending[pid] = nil
            } else if now.timeIntervalSince(since) > grace {
                kill(pid, SIGKILL)
            }
        }
        if pending.isEmpty {
            timer?.cancel()
            timer = nil
        } else if timer == nil {
            let beat = DispatchSource.makeTimerSource(queue: queue)
            beat.schedule(deadline: .now() + 0.5, repeating: 0.5)
            beat.setEventHandler { sweep() }
            beat.resume()
            timer = beat
        }
    }
}
