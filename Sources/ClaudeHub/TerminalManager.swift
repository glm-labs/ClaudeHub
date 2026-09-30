import AppKit
import SwiftTerm
import UniformTypeIdentifiers
import UserNotifications

/// Keeps one live terminal per tab so switching in the sidebar
/// doesn't kill running Claude processes.
final class TerminalManager: NSObject, ObservableObject {
    static let shared = TerminalManager()

    /// Bumped when a process ends/restarts so views and status dots update.
    @Published private(set) var generation = 0

    /// What each tab's terminal is doing right now, refreshed on a timer by
    /// reading the visible screen — see `TerminalActivity`.
    @Published private(set) var activity: [String: TerminalActivity] = [:]
    /// Drives every pulsing dot from one clock: they breathe in step, and no
    /// row has to mutate its own state while the table is laying it out.
    @Published private(set) var pulse = false
    private var activityTimer: Timer?

    private var terminals: [String: LocalProcessTerminalView] = [:]
    /// The saved account each live terminal was actually launched with (nil =
    /// the signed-in one). A tab keeps the account it started on, so this is
    /// the only honest answer to "what am I burning limits on in this tab".
    private var launchedProfile: [String: String] = [:]
    /// Tabs that wanted a saved account but had to start on the signed-in one
    /// because its token could not be read. Silent fallback is what makes
    /// account switching look broken, so it is remembered and shown.
    private var fellBack: [String: String] = [:]
    /// What was in a tab's prompt when it was restarted, and how far putting
    /// it back has got.
    private var pendingRestores: [String: Restore] = [:]

    /// A prompt being rebuilt in a restarted session, one move at a time.
    private struct Restore {
        var steps: [PasteMemory.Step]
        var index = 0
        /// Set while an image sits on the clipboard and ⌃V has gone in: Claude
        /// Code reads the clipboard itself, so the answer comes back on screen
        /// rather than from the call.
        var pastedImageAt: Date?
        var clipboard: PasteMemory.Clipboard?
        var imagesBefore = 0
    }

    /// How long an image gets to arrive before the file path is typed instead.
    private static let imageWait: TimeInterval = 5

    /// Why a tab has not moved to the new account yet.
    private enum SwitchHold {
        /// Mid-answer, or waiting on a permission prompt.
        case busy
        /// The prompt holds something neither the screen nor `PasteMemory` can
        /// give back — an image from Claude in Chrome, say, or a paste from
        /// before this app was watching.
        case attachment
    }

    /// Tabs that could not move when the account changed: they move as soon as
    /// the reason is gone. Nothing is interrupted, and nothing is lost.
    private var deferredSwitches: [String: (tab: TerminalTab, account: String, hold: SwitchHold)] = [:]
    /// Sessions that answered while you were elsewhere. Cleared by looking at
    /// them, which is the only thing that should clear it.
    @Published private(set) var unread: Set<String> = []
    /// Tabs whose account has run out, with what the session said about it.
    /// The limit belongs to the account that tab started with, which is not
    /// necessarily the one you are about to start a session on.
    @Published private(set) var limitNotices: [String: String] = [:]
    private var finishedAt: [String: Date] = [:]
    private var busySince: [String: Date] = [:]
    /// Tab titles, kept by TabsModel, so a notification can name the session
    /// rather than its identifier.
    var tabTitles: [String: String] = [:]
    /// The tabs on screen right now, so an answer you watched arrive is not
    /// then reported as something you missed.
    var visibleTabs: Set<String> = []
    /// Tabs whose process has exited; their view stays (showing the exit
    /// message) until the tab is closed or explicitly restarted.
    private var deadTabs: Set<String> = []
    private(set) var claudePath: String = "claude"

    /// The bundled zoetrope binary (Resources/bin/zoe) — the session flow
    /// graph, https://github.com/furkankly/zoetrope — or one the user
    /// installed themselves. Nil in source builds that skipped bundling.
    private(set) lazy var zoePath: String? = {
        let fm = FileManager.default
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/zoe").path,
           fm.isExecutableFile(atPath: bundled) {
            return bundled
        }
        let home = fm.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin/zoe", "/usr/local/bin/zoe",
                "\(home)/.cargo/bin/zoe", "\(home)/.local/bin/zoe"]
            .first { fm.isExecutableFile(atPath: $0) }
    }()
    private var appearanceObservation: NSKeyValueObservation?

    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    /// The folder each live terminal started in, for resolving relative paths
    /// Claude prints — `src/Foo.swift:42` means that file in that folder.
    private var folders: [String: String] = [:]

    /// Terminal text size, shared by every tab and remembered across launches.
    @Published private(set) var fontSize: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: "terminalFontSize")
        return (8.0...32.0).contains(stored) ? CGFloat(stored) : 12
    }()

    override private init() {
        super.init()
        resolveClaudePath()
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshThemes() }
        }
        // Shift+Enter → ESC+CR (the Meta+Enter sequence), which Claude Code
        // treats as "insert newline" instead of "submit" — matching VS Code's
        // integrated-terminal behavior. Plain terminals can't distinguish
        // Shift+Enter from Enter, so this is intercepted at the event level.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 36,  // Return
               event.modifierFlags.contains(.shift),
               let terminal = NSApp.keyWindow?.firstResponder as? TerminalView {
                terminal.send(txt: "\u{1b}\r")
                return nil
            }
            // ⌃V is Claude Code's own image paste: the keystroke is all the
            // session gets — it goes and reads the clipboard itself — so this
            // is the one moment a copy of the image can be kept, which is what
            // lets the tab move to another account later without losing it.
            // SwiftTerm's keyDown is not open to overriding, hence here.
            if event.modifierFlags.contains(.control),
               !event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "v",
               let terminal = NSApp.keyWindow?.firstResponder as? DroppableTerminalView,
               terminal.takesImagePastes,
               let tabID = terminal.tabID,
               PasteMemory.clipboardHasImage(),
               let file = PasteMemory.shared.keepClipboardImage() {
                PasteMemory.shared.note(.image(file), pastedInto: terminal, tab: tabID)
                return event
            }
            // ⌘= is what most keyboards give for "bigger" without reaching for
            // shift; the menu item binds ⌘+ for the same action.
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers == "=" {
                self?.changeFontSize(by: 1)
                return nil
            }
            // ⌘⌫ is Delete Session in the menu, which means the menu was
            // taking it from under the cursor while you were typing: one
            // keystroke away from deleting the conversation instead of the
            // line you meant. In a terminal it is the line — Ctrl-U, what the
            // prompt already understands as "clear what I typed" — and the
            // menu only gets it when the sidebar has the focus.
            if event.keyCode == 51,                     // Delete / Backspace
               event.modifierFlags.contains(.command),
               let terminal = NSApp.keyWindow?.firstResponder as? TerminalView {
                terminal.send(txt: "\u{15}")
                return nil
            }
            // Option+Arrow / Option+Delete — word-left, word-right, and
            // delete-word in the prompt. SwiftTerm sends plain arrows for
            // these, so the readline meta sequences (ESC+b / ESC+f / ESC+DEL)
            // are supplied here, the way Terminal.app's option bindings do.
            if event.modifierFlags.contains(.option),
               !event.modifierFlags.contains(.command),
               let terminal = NSApp.keyWindow?.firstResponder as? TerminalView {
                switch event.keyCode {
                case 123: terminal.send(txt: "\u{1b}b"); return nil   // ⌥←
                case 124: terminal.send(txt: "\u{1b}f"); return nil   // ⌥→
                case 51:  terminal.send(txt: "\u{1b}\u{7f}"); return nil  // ⌥⌫
                default: break
                }
            }
            return event
        }
        // ⌘-click on a file path opens it in VS Code at that line — Claude
        // prints `src/Foo.swift:42` all day long. URLs open in the browser.
        // A monitor rather than an override: SwiftTerm's mouseDown is not
        // open to subclasses, same as its keyDown.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.modifierFlags.contains(.command),
                  let window = event.window,
                  var view = window.contentView?.hitTest(event.locationInWindow) else { return event }
            while !(view is LocalProcessTerminalView), let parent = view.superview { view = parent }
            guard let terminalView = view as? LocalProcessTerminalView,
                  let tabID = self.terminals.first(where: { $0.value === terminalView })?.key,
                  self.openLink(at: event, in: terminalView, tabID: tabID) else { return event }
            return nil
        }
        activityTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            self?.pollActivity()
        }
    }

    // MARK: - ⌘-click on paths and links

    /// Reads the row under the pointer, finds the path or URL the click landed
    /// on, and opens it. False when there was nothing to open, so the click
    /// falls through to the terminal.
    private func openLink(at event: NSEvent, in view: LocalProcessTerminalView, tabID: String) -> Bool {
        let terminal = view.getTerminal()
        let point = view.convert(event.locationInWindow, from: nil)
        let fromTop = view.isFlipped ? point.y : view.bounds.height - point.y
        let cellHeight = view.bounds.height / CGFloat(max(terminal.rows, 1))
        let cellWidth = view.bounds.width / CGFloat(max(terminal.cols, 1))
        let row = Int(fromTop / cellHeight)
        let col = Int(point.x / cellWidth)
        guard row >= 0, row < terminal.rows, let line = terminal.getLine(row: row) else { return false }
        let text = Self.readable(line.translateToString(trimRight: false))
        guard let token = Self.linkToken(in: text, at: col) else { return false }

        if token.contains("://"), let url = URL(string: token) {
            NSWorkspace.shared.open(url)
            return true
        }
        return openFile(token, from: folders[tabID] ?? FileManager.default.homeDirectoryForCurrentUser.path)
    }

    /// The run of path characters around `col`, with the punctuation a
    /// sentence hangs on it taken off. Nil unless it looks like a path or URL.
    private static func linkToken(in text: String, at col: Int) -> String? {
        let chars = Array(text)
        guard !chars.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-./~:@+%#?=&"))
        func ok(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { allowed.contains($0) } }
        var start = min(max(col, 0), chars.count - 1)
        guard ok(chars[start]) else { return nil }
        var end = start
        while start > 0, ok(chars[start - 1]) { start -= 1 }
        while end + 1 < chars.count, ok(chars[end + 1]) { end += 1 }
        var token = String(chars[start...end])
        while let last = token.last, ".,;:)]}'\"".contains(last) { token.removeLast() }
        guard token.contains("/") || token.contains(".") else { return nil }
        return token
    }

    /// `path`, `path:line`, or `path:line:col` — relative to the tab's folder
    /// — in VS Code when it is installed, else whatever opens that file.
    /// Anything a text editor has nothing to say about goes to its own app.
    private func openFile(_ token: String, from folder: String) -> Bool {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var path = parts[0]
        let line = parts.count > 1 ? Int(parts[1]) : nil
        let column = parts.count > 2 ? Int(parts[2]) : nil
        if path.hasPrefix("~") {
            path = FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst()
        } else if !path.hasPrefix("/") {
            path = (folder as NSString).appendingPathComponent(path)
        }
        path = (path as NSString).standardizingPath
        guard FileManager.default.fileExists(atPath: path) else { return false }

        let fileURL = URL(fileURLWithPath: path)
        if showsInItsOwnApp(fileURL) {
            NSWorkspace.shared.open(fileURL)
            return true
        }
        if let vsCode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") {
            if let line,
               let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
               let url = URL(string: "vscode://file\(encoded):\(line)\(column.map { ":\($0)" } ?? "")") {
                NSWorkspace.shared.open(url)
            } else {
                NSWorkspace.shared.open([fileURL], withApplicationAt: vsCode,
                                        configuration: NSWorkspace.OpenConfiguration())
            }
        } else {
            NSWorkspace.shared.open(fileURL)
        }
        return true
    }

    /// An image, a PDF, a recording, an archive: files a text editor has
    /// nothing to say about. Claude writes a screenshot and prints its path as
    /// readily as it prints a source file, and clicking that should show the
    /// picture — in Preview, or in whatever the Finder would use — not open a
    /// window full of PNG bytes.
    ///
    /// SVG is the exception on purpose: it is an image by type and markup in
    /// practice, and the reason to click one is usually to read it.
    private func showsInItsOwnApp(_ url: URL) -> Bool {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
              !type.conforms(to: .svg) else { return false }
        return [UTType.image, .movie, .audio, .pdf, .archive, .spreadsheet, .presentation]
            .contains { type.conforms(to: $0) }
    }

    /// Terminals whose process is still alive (used by quit protection).
    var runningCount: Int {
        terminals.keys.filter { !deadTabs.contains($0) }.count
    }

    private func resolveClaudePath() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        if let found = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
            claudePath = found
            return
        }
        // Fall back to asking a login shell (covers nvm/volta/etc. installs)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "command -v claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        if let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
            let path = output.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { $0.hasPrefix("/") && $0.hasSuffix("claude") }
            if let path { claudePath = path }
        }
    }

    func isRunning(_ tabID: String) -> Bool {
        terminals[tabID] != nil && !deadTabs.contains(tabID)
    }

    func isDead(_ tabID: String) -> Bool {
        deadTabs.contains(tabID)
    }

    func terminal(for tab: TerminalTab) -> LocalProcessTerminalView {
        if let existing = terminals[tab.id] { return existing }

        let view = DroppableTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.tabID = tab.id
        view.takesImagePastes = tab.isConversation
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        applyTheme(to: view)

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        // A profile tab runs as its own account: the CLI reads this instead of
        // the signed-in credentials, which is what lets two tabs use two
        // accounts at the same time.
        launchedProfile[tab.id] = nil
        fellBack[tab.id] = nil
        // Deliberately the cached token only: a keychain panel here would
        // freeze the app mid-layout, and a session that quietly starts on the
        // wrong account is worse than one that starts late.
        if !tab.pinnedToSignedIn,
           let profile = tab.profile ?? TokenStore.activeProfile,
           let token = TokenStore.cachedToken(for: profile) {
            env["CLAUDE_CODE_OAUTH_TOKEN"] = token
            launchedProfile[tab.id] = profile
        } else if !tab.pinnedToSignedIn,
                  let wanted = tab.profile ?? TokenStore.activeProfile {
            fellBack[tab.id] = wanted
        }
        let envArray = env.map { "\($0.key)=\($0.value)" }

        switch tab.kind {
        case .resume(let sessionID):
            start(view, envArray, "exec \(ClaudeSession.shellQuote(claudePath)) --resume \(ClaudeSession.shellQuote(sessionID))", in: tab.cwd)
        case .newSession(let sessionID):
            // ⌘N — a fresh Claude session in the tab's folder, under the id the
            // tab was opened with, so the sidebar row and this tab are the same
            // session from the start. Restarting a tab that already has a
            // transcript resumes it: --session-id refuses an id that is taken.
            let flag = Self.transcriptExists(sessionID) ? "--resume" : "--session-id"
            start(view, envArray,
                  "exec \(ClaudeSession.shellQuote(claudePath)) \(flag) \(ClaudeSession.shellQuote(sessionID))",
                  in: tab.cwd)
        case .command(let args):
            // `claude auth login`, `auth logout` — the shell stays afterwards so
            // the result is still readable instead of the tab dropping dead.
            let command = ([claudePath] + args).map(ClaudeSession.shellQuote).joined(separator: " ")
            start(view, envArray, "\(command); echo; exec /bin/zsh -i -l", in: tab.cwd)
        case .script(let command):
            // The shell stays afterwards, so the output can be scrolled and
            // the command run again.
            start(view, envArray, "\(command); echo; exec /bin/zsh -i -l", in: tab.cwd)
        case .shell, .diff:
            // A diff tab has no process; it never asks for a terminal, and the
            // case is here only because the switch must cover it.
            // Plain interactive shell in the tab's folder (⌘T)
            view.startProcess(
                executable: "/bin/zsh",
                args: ["-i", "-l"],
                environment: envArray,
                execName: nil,
                currentDirectory: tab.cwd
            )
        }

        deadTabs.remove(tab.id)
        terminals[tab.id] = view
        folders[tab.id] = tab.cwd
        return view
    }

    /// Whether Claude Code has already written a transcript for this session.
    /// The project folder is derived from the cwd by a scheme we would rather
    /// not reimplement, so this just looks for the file across all of them.
    private static func transcriptExists(_ sessionID: String) -> Bool {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return false
        }
        return dirs.contains {
            fm.fileExists(atPath: $0.appendingPathComponent("\(sessionID).jsonl").path)
        }
    }

    /// A login shell gives `claude` the same PATH the user's terminal has.
    private func start(_ view: LocalProcessTerminalView, _ env: [String], _ command: String, in cwd: String) {
        view.startProcess(
            executable: "/bin/zsh",
            args: ["-l", "-c", "cd \(ClaudeSession.shellQuote(cwd)) && \(command)"],
            environment: env,
            execName: nil
        )
    }

    /// The account this tab runs as: the one it launched with once it is
    /// running, the one it would launch with before that.
    func profile(of tab: TerminalTab) -> String? {
        if terminals[tab.id] != nil { return launchedProfile[tab.id] }
        if tab.pinnedToSignedIn { return nil }
        return tab.profile ?? TokenStore.activeProfile
    }

    /// Whether the tab is already running, so its account is settled rather
    /// than a prediction.
    func hasLaunched(_ tabID: String) -> Bool { terminals[tabID] != nil }

    /// The saved account this tab was meant to run as but could not.
    func fallbackAccount(of tabID: String) -> String? { fellBack[tabID] }

    /// Restart a tab, whether its process ended or is still running.
    ///
    /// A live process is stopped first: dropping the reference would leave it
    /// running on the old account, still holding that token, invisible.
    func relaunch(_ tab: TerminalTab) {
        if let view = terminals.removeValue(forKey: tab.id), !deadTabs.contains(tab.id) {
            // Switching account restarts the session; what you were halfway
            // through typing should survive that — including the pastes in it,
            // which are replayed from what went in rather than read off the
            // screen, where they are only a stand-in.
            let plan = Self.draft(of: view).flatMap { PasteMemory.shared.plan(for: $0, tab: tab.id) }
            pendingRestores[tab.id] = plan.map { Restore(steps: $0) }
            // The stand-ins were numbered by the session that is ending; the
            // replay binds the new ones. The image files stay: the plan holds
            // them.
            PasteMemory.shared.forget(tab: tab.id, deletingImages: false)
            view.terminate()
        }
        launchedProfile[tab.id] = nil
        fellBack[tab.id] = nil
        deadTabs.remove(tab.id)
        generation += 1
    }

    /// Moves every open conversation onto the account that is active now.
    ///
    /// Switching account used to apply only to what you opened next, which
    /// meant the window could show four tabs under one account label while
    /// three of them ran as somebody else. A conversation survives this: it
    /// resumes from its transcript, on the new account. Shells and one-shot
    /// `claude auth` tabs are left alone — restarting those would throw away
    /// what you were doing in them, and they are not conversations.
    ///
    /// Only the visible tab starts again immediately; the rest start as you
    /// come back to them, which is also when they would have cost anything.
    @discardableResult
    func restartConversations(_ tabs: [TerminalTab]) -> Int {
        let target = TokenStore.activeProfile ?? "the signed-in account"
        var moved = 0
        for tab in tabs where tab.isConversation {
            if let hold = hold(on: tab) {
                deferredSwitches[tab.id] = (tab, target, hold)
            } else {
                relaunch(tab)
                moved += 1
            }
        }
        return moved
    }

    /// What stands in the way of moving this tab right now, if anything.
    ///
    /// A session that is working, or waiting for you to answer a permission
    /// prompt, is not something to kill. A prompt holding a paste used to be
    /// just as untouchable — the content lives in Claude Code's memory and the
    /// screen shows only a stand-in for it — but a paste this app saw go in is
    /// remembered and can be put back, so only what `PasteMemory` cannot
    /// reproduce still holds the tab where it is.
    private func hold(on tab: TerminalTab) -> SwitchHold? {
        guard let view = terminals[tab.id], !deadTabs.contains(tab.id) else { return nil }
        if let draft = Self.draft(of: view), PasteMemory.shared.plan(for: draft, tab: tab.id) == nil {
            return .attachment
        }
        switch activity(of: tab.id) {
        case .idle, .finished, .stopped, .dead: return nil
        case .busy, .needsInput: return .busy
        }
    }

    /// The account a tab will move to once it can, and why it has not yet.
    func pendingSwitch(of tabID: String) -> (account: String, waitingOnPaste: Bool)? {
        guard let pending = deferredSwitches[tabID] else { return nil }
        return (pending.account, pending.hold == .attachment)
    }

    /// Moves the tabs that were busy when the account changed, now that they
    /// are not.
    private func applyDeferredSwitches() {
        guard !deferredSwitches.isEmpty else { return }
        for (id, pending) in deferredSwitches {
            guard terminals[id] != nil else {
                deferredSwitches[id] = nil
                continue
            }
            // The same test that held it back, asked again: sent the paste, or
            // finished the answer, and it can move.
            guard hold(on: pending.tab) == nil else { continue }
            deferredSwitches[id] = nil
            relaunch(pending.tab)
        }
    }

    func closeTerminal(for tabID: String) {
        folders[tabID] = nil
        if let view = terminals.removeValue(forKey: tabID), !deadTabs.contains(tabID) {
            view.terminate()
        }
        launchedProfile[tabID] = nil
        fellBack[tabID] = nil
        pendingRestores[tabID] = nil
        PasteMemory.shared.forget(tab: tabID, deletingImages: true)
        finishedAt[tabID] = nil
        markRead(tabID)
        deferredSwitches[tabID] = nil
        deadTabs.remove(tabID)
        generation += 1
    }

    // MARK: - Activity

    func activity(of tabID: String) -> TerminalActivity {
        if deadTabs.contains(tabID) { return .dead }
        guard terminals[tabID] != nil else { return .stopped }
        let state = activity[tabID] ?? .idle
        // Unread only colours a session that is otherwise sitting quiet: a
        // question or a new answer coming in outranks it.
        if state == .idle, unread.contains(tabID) { return .finished }
        return state
    }

    /// When a session last stopped working, for "finished 3 min ago".
    func finishedAt(_ tabID: String) -> Date? { finishedAt[tabID] }

    /// Tells you an answer arrived while you were in another app.
    ///
    /// Only for work that took long enough to walk away from — a reply that
    /// lands in ten seconds is one you are still watching, and a banner for it
    /// is noise. No sound: it is an answer, not an alarm.
    private func announce(_ tabID: String, after seconds: TimeInterval) {
        guard seconds >= 60 else { return }
        let content = UNMutableNotificationContent()
        content.title = tabTitles[tabID] ?? "Claude session"
        content.body = "Finished after \(Self.spell(seconds))."
        content.userInfo = ["tab": tabID]
        let request = UNNotificationRequest(identifier: "finished-\(tabID)-\(Date().timeIntervalSince1970)",
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static func spell(_ seconds: TimeInterval) -> String {
        let value = Int(seconds)
        if value >= 3_600 { return "\(value / 3_600) hr \((value % 3_600) / 60) min" }
        if value >= 60 { return "\(value / 60) min" }
        return "\(value) sec"
    }

    /// Looking at a session is what marks it read.
    func markRead(_ tabID: String) {
        guard unread.contains(tabID) else { return }
        unread.remove(tabID)
        updateDockBadge()
    }

    func markRead(_ tabIDs: some Sequence<String>) {
        let seen = unread.intersection(tabIDs)
        guard !seen.isEmpty else { return }
        unread.subtract(seen)
        updateDockBadge()
    }

    /// The count on the app icon: the whole point is to be readable with
    /// ClaudeHub in the background, which is exactly when it matters.
    private func updateDockBadge() {
        NSApp.dockTile.badgeLabel = unread.isEmpty ? nil : String(unread.count)
    }

    /// Claude Code has no machine-readable "am I busy" channel, so this reads
    /// what the session is showing: while it works it prints an
    /// "esc to interrupt" hint, and permission prompts ask "Do you want to …".
    private func pollActivity() {
        guard !terminals.isEmpty else {
            if !activity.isEmpty { activity = [:] }
            return
        }
        var next: [String: TerminalActivity] = [:]
        var finished: [String] = []
        for (id, view) in terminals where !deadTabs.contains(id) {
            let state = Self.classify(Self.visibleText(of: view))
            if state == .busy, activity[id] != .busy { busySince[id] = Date() }

            // The moment an answer lands: working a second ago, quiet now.
            if activity[id] == .busy, state == .idle {
                finishedAt[id] = Date()
                let watched = visibleTabs.contains(id) && NSApp.isActive
                if !watched { finished.append(id) }
                let worked = busySince[id].map { Date().timeIntervalSince($0) } ?? 0
                busySince[id] = nil
                if !NSApp.isActive { announce(id, after: worked) }
            }
            next[id] = state

            // "You've hit your session limit · resets 2:40am" — the one message
            // that explains a session that has gone quiet and will not answer.
            //
            // It is read off the screen, and the screen keeps it long after the
            // window has reset, so it counts only while the reset it names is
            // still ahead and the session is not plainly working.
            let notice = state == .busy ? nil : Self.limitNotice(in: Self.visibleText(of: view))
            if limitNotices[id] != notice { limitNotices[id] = notice }
        }
        if next != activity { activity = next }
        if !finished.isEmpty {
            unread.formUnion(finished)
            updateDockBadge()
        }
        applyDeferredSwitches()
        restoreDrafts()
        if next.values.contains(where: \.pulses) {
            pulse.toggle()
        } else if pulse {
            pulse = false
        }
    }

    /// Puts a kept prompt back, once the new session has an empty prompt to
    /// take it — sending it earlier is how a keystroke gets swallowed by a
    /// session that is still starting.
    private func restoreDrafts() {
        guard !pendingRestores.isEmpty else { return }
        for id in Array(pendingRestores.keys) {
            guard let view = terminals[id], !deadTabs.contains(id) else {
                pendingRestores[id]?.clipboard?.giveBack()
                pendingRestores[id] = nil
                continue
            }
            advanceRestore(id, in: view)
        }
    }

    /// Runs the plan until it is done or has to wait.
    ///
    /// Typing and pasting go straight in — the order they arrive in is the
    /// order the session reads them. An image cannot: it goes on the clipboard
    /// and Claude Code fetches it in its own time, so that step ends the pass
    /// and the next one picks it up when the prompt says the image landed.
    private func advanceRestore(_ id: String, in view: LocalProcessTerminalView) {
        guard var restore = pendingRestores[id] else { return }
        if restore.index == 0, restore.pastedImageAt == nil,
           !Self.promptIsEmpty(Self.visibleText(of: view)) { return }

        while restore.index < restore.steps.count {
            switch restore.steps[restore.index] {
            case .text(let text):
                view.send(txt: text)
                restore.index += 1

            case .paste(let text):
                PasteMemory.shared.note(.text(text), pastedInto: view, tab: id)
                Self.paste(text, into: view)
                restore.index += 1

            case .image(let file):
                guard let since = restore.pastedImageAt else {
                    restore.imagesBefore = PasteMemory.imageCount(of: view)
                    restore.clipboard = PasteMemory.Clipboard.lend(file)
                    PasteMemory.shared.note(.image(file), pastedInto: view, tab: id)
                    view.send(txt: "\u{16}")     // ⌃V — Claude Code reads the image itself
                    restore.pastedImageAt = Date()
                    pendingRestores[id] = restore
                    return
                }
                let arrived = PasteMemory.imageCount(of: view) > restore.imagesBefore
                guard arrived || Date().timeIntervalSince(since) > Self.imageWait else {
                    pendingRestores[id] = restore
                    return
                }
                restore.clipboard?.giveBack()
                restore.clipboard = nil
                restore.pastedImageAt = nil
                // It never landed: the path is the honest second best, and the
                // session can still read the file from it.
                if !arrived { view.send(txt: file.path) }
                restore.index += 1
            }
        }
        pendingRestores[id] = nil
    }

    /// Gives the clipboard back if a restore is holding it, for the one moment
    /// there will be no next poll to do it: quitting.
    func releaseBorrowedClipboard() {
        for id in Array(pendingRestores.keys) {
            pendingRestores[id]?.clipboard?.giveBack()
            pendingRestores[id]?.clipboard = nil
        }
    }

    /// Sends text the way ⌘V does, so Claude Code takes it as a paste — which
    /// is what turns a long one back into `[Pasted text #1 +36 lines]` instead
    /// of thirty lines of typing, each one sending the prompt.
    private static func paste(_ text: String, into view: LocalProcessTerminalView) {
        guard view.getTerminal().bracketedPasteMode else {
            // No bracketed paste means every newline would send the prompt, so
            // they go in as the Meta+Enter the prompt reads as a line break.
            return view.send(txt: text.replacingOccurrences(of: "\n", with: "\u{1b}\r"))
        }
        view.send(data: EscapeSequences.bracketedPasteStart[0...])
        view.send(txt: text)
        view.send(data: EscapeSequences.bracketedPasteEnd[0...])
    }

    /// What the session says about being out of quota, in its own words.
    private static func limitNotice(in screen: String) -> String? {
        let markers = ["hit your session limit", "hit your usage limit",
                       "hit your weekly limit", "usage limit reached"]
        guard let line = screen.split(separator: "\n").last(where: { line in
            markers.contains { line.contains($0) }
        }) else { return nil }
        let notice = line.trimmingCharacters(in: .whitespaces)
        // A reset that has already happened is a message about this morning,
        // not about now.
        if let reset = resetTime(in: notice), let at = resetDate(reset), at < Date() {
            return nil
        }
        return notice
    }

    /// "2:40am" as a moment today, or tomorrow when that hour has passed and
    /// the message is fresh enough to mean the coming one.
    private static func resetDate(_ text: String, now: Date = Date()) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let normalised = text.uppercased()
        for format in ["h:mma", "ha"] {
            formatter.dateFormat = format
            guard let time = formatter.date(from: normalised) else { continue }
            let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
            guard let today = Calendar.current.date(bySettingHour: parts.hour ?? 0,
                                                    minute: parts.minute ?? 0,
                                                    second: 0,
                                                    of: now) else { continue }
            // Within the last few hours it is behind us; further back than that
            // and the session means the same hour tomorrow.
            return today > now || now.timeIntervalSince(today) < 6 * 3600
                ? today
                : Calendar.current.date(byAdding: .day, value: 1, to: today)
        }
        return nil
    }

    /// "resets 2:40am" out of the whole sentence, for a badge with no room.
    static func resetTime(in notice: String) -> String? {
        guard let range = notice.range(of: "resets ", options: .caseInsensitive) else { return nil }
        let rest = notice[range.upperBound...]
        let time = rest.prefix { !$0.isWhitespace }
        return time.isEmpty ? nil : String(time)
    }

    private static func classify(_ screen: String) -> TerminalActivity {
        if screen.contains("esc to interrupt") { return .busy }
        if screen.contains("Do you want to") { return .needsInput }
        return .idle
    }

    /// The rows currently on screen, lowest-cost snapshot SwiftTerm offers.
    private static func visibleText(of view: LocalProcessTerminalView) -> String {
        let terminal = view.getTerminal()
        var lines: [String] = []
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else { continue }
            lines.append(readable(line.translateToString(trimRight: true)))
        }
        return lines.joined(separator: "\n")
    }

    /// A cell that was never written comes back as NUL, not as a space —
    /// SwiftTerm hands you `Character(Unicode.Scalar(0))` for an empty cell.
    /// On screen that gap is a space, and everything that reads the screen
    /// means the space: a prompt read as text otherwise loses every gap
    /// between words, and typing it back sends NULs the terminal drops.
    private static func readable(_ text: String) -> String {
        text.replacingOccurrences(of: "\0", with: " ")
    }

    /// The login URL a `claude auth` tab prints, rejoined.
    ///
    /// The terminal hard-wraps it across three lines with no hyphen, and
    /// cmd-clicking it just opens the browser — so this stitches the pieces
    /// back together for the clipboard. Continuation lines are the ones with
    /// no spaces in them.
    func signInURL(in tabID: String) -> String? {
        guard let view = terminals[tabID] else { return nil }
        let lines = Self.visibleText(of: view)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let index = lines.lastIndex(where: { $0.contains("https://") }),
              let start = lines[index].range(of: "https://") else { return nil }

        var url = String(lines[index][start.lowerBound...]).trimmingCharacters(in: .whitespaces)
        var next = index + 1
        while next < lines.count {
            let line = lines[next].trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.contains(" ") else { break }
            url += line
            next += 1
        }
        return url.count > 30 ? url : nil
    }

    // MARK: - Find

    /// Searches the tab's scrollback, selects the match and scrolls to it.
    /// Returns "3 of 12" for the field's counter.
    @discardableResult
    func find(_ term: String, in tabID: String, forward: Bool = true) -> (index: Int, total: Int) {
        guard let view = terminals[tabID], !term.isEmpty else { return (0, 0) }
        if forward {
            view.findNext(term)
        } else {
            view.findPrevious(term)
        }
        return view.searchMatchSummary(term)
    }

    /// Typing in the field searches from the top again, rather than walking
    /// forward from wherever the last keystroke happened to land.
    @discardableResult
    func findFromStart(_ term: String, in tabID: String) -> (index: Int, total: Int) {
        terminals[tabID]?.clearSearch()
        return find(term, in: tabID, forward: true)
    }

    func clearFind(in tabID: String) {
        terminals[tabID]?.clearSearch()
    }

    /// True while the tab's program runs on the alternate screen — Claude Code
    /// in fullscreen mode, say — where the terminal holds only the visible rows
    /// and nothing scrolled away.
    func isOnAlternateScreen(_ tabID: String) -> Bool {
        terminals[tabID]?.getTerminal().isCurrentBufferAlternate ?? false
    }

    // MARK: - Slash commands

    /// Types a slash command into a session. Only presses Return when the
    /// prompt is provably empty — appending to half-typed text and submitting
    /// it would send the user's own words to Claude by accident.
    /// Returns whether it was submitted.
    @discardableResult
    func sendSlashCommand(_ command: String, to tabID: String) -> Bool {
        guard let view = terminals[tabID], !deadTabs.contains(tabID) else { return false }
        let submit = activity(of: tabID) == .idle
            && Self.promptIsEmpty(Self.visibleText(of: view))
        view.send(txt: submit ? command + "\r" : command)
        view.window?.makeFirstResponder(view)
        return submit
    }

    /// The prompt renders as `❯ …`, or as `│ > …` inside a box in older
    /// versions. Returns where it is and what is on it.
    private static func promptLine(_ screen: String) -> (index: Int, text: String, lines: [String])? {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for index in lines.indices.reversed() {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            let unboxed = trimmed.hasPrefix("\u{2502}")     // │
                ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                : trimmed
            guard unboxed.hasPrefix("\u{276F}") || unboxed.hasPrefix(">") else { continue }  // ❯
            let text = unboxed.dropFirst()
                .trimmingCharacters(in: CharacterSet(charactersIn: " \u{2502}"))
            return (index, text, lines)
        }
        return nil
    }

    /// The hint an empty prompt shows — `Try "write a test for <filepath>"` —
    /// which is on screen but is not something anybody typed.
    private static func isPlaceholder(_ text: String) -> Bool {
        text.hasPrefix("Try \"") || text.hasPrefix("Try \u{201C}")
    }

    /// An empty prompt has nothing on it but the hint. Anything we cannot read
    /// confidently counts as "not empty".
    private static func promptIsEmpty(_ screen: String) -> Bool {
        guard let prompt = promptLine(screen) else { return false }
        return prompt.text.isEmpty || isPlaceholder(prompt.text)
    }

    /// What has been typed into the prompt but not sent yet, exactly as typed.
    ///
    /// Long input wraps onto the rows under the caret, and the terminal knows
    /// which of those are a continuation of the row above rather than a line of
    /// their own. Using that, a wrapped sentence is rejoined with nothing in
    /// between — no invented spaces — and a real newline is put back as the
    /// Meta+Enter the prompt takes for one.
    static func draft(of view: LocalProcessTerminalView) -> String? {
        let terminal = view.getTerminal()
        var rows: [(text: String, wrapped: Bool)] = []
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else {
                rows.append(("", false))
                continue
            }
            // Not trimmed: at a wrap, a trailing space is content, and dropping
            // it is how "hello world" comes back as "helloworld".
            rows.append((readable(line.translateToString(trimRight: false)), line.isWrapped))
        }

        guard let start = rows.indices.reversed().first(where: { isPromptRow(rows[$0].text) }),
              let head = promptText(rows[start].text) else { return nil }

        var lines = [head]
        for row in (start + 1)..<rows.count {
            let trimmed = rows[row].text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || isFrame(trimmed) { break }
            if rows[row].wrapped {
                lines[lines.count - 1] += rows[row].text
            } else {
                lines.append(rows[row].text)
            }
        }

        let text = lines
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .joined(separator: "\u{1b}\r")     // Meta+Enter: a newline, not a send
        guard !text.isEmpty, !isPlaceholder(text) else { return nil }
        return text
    }

    private static func isPromptRow(_ row: String) -> Bool {
        let trimmed = row.trimmingCharacters(in: .whitespaces)
        let unboxed = trimmed.hasPrefix("\u{2502}")
            ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            : trimmed
        return unboxed.hasPrefix("\u{276F}") || unboxed.hasPrefix(">")
    }

    /// The row's content with the caret taken off the front, right-hand padding
    /// left alone.
    private static func promptText(_ row: String) -> String? {
        var text = Substring(row).drop { $0 == " " }
        if text.first == "\u{2502}" { text = text.dropFirst().drop { $0 == " " } }
        guard let caret = text.first, caret == "\u{276F}" || caret == ">" else { return nil }
        text = text.dropFirst()
        if text.first == " " { text = text.dropFirst() }
        return String(text)
    }

    /// The rules, status line and hints drawn under the input box.
    private static func isFrame(_ line: String) -> Bool {
        guard let first = line.first else { return true }
        return "\u{2500}\u{256D}\u{2570}\u{23F5}\u{26A0}?".contains(first)   // ─ ╭ ╰ ⏵ ⚠ ?
    }

    // MARK: - Text size

    func changeFontSize(by delta: CGFloat) { setFontSize(fontSize + delta) }

    func resetFontSize() { setFontSize(12) }

    private func setFontSize(_ size: CGFloat) {
        let clamped = min(max(size, 8), 32)
        guard clamped != fontSize else { return }
        fontSize = clamped
        UserDefaults.standard.set(Double(clamped), forKey: "terminalFontSize")

        let font = NSFont.monospacedSystemFont(ofSize: clamped, weight: .regular)
        for view in terminals.values {
            view.font = font
            view.needsLayout = true
            view.needsDisplay = true
        }
        generation += 1
    }

    // MARK: - Theme (follows system appearance)

    static var isDarkMode: Bool {
        NSApplication.shared.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Matches the dark terminal background (#1E1E1E) / plain white in light mode.
    static var terminalBackground: NSColor {
        isDarkMode ? NSColor(calibratedRed: 0.118, green: 0.118, blue: 0.118, alpha: 1) : .white
    }

    private func applyTheme(to view: LocalProcessTerminalView) {
        let dark = Self.isDarkMode
        view.nativeBackgroundColor = Self.terminalBackground
        view.nativeForegroundColor = dark
            ? NSColor(calibratedWhite: 0.87, alpha: 1)
            : NSColor(calibratedWhite: 0.13, alpha: 1)
        view.caretColor = NSColor(calibratedRed: 0.85, green: 0.35, blue: 0.16, alpha: 1)
        view.selectedTextBackgroundColor = NSColor.selectedTextBackgroundColor
        view.installColors(dark ? Self.darkAnsiPalette : Self.lightAnsiPalette)
    }

    /// Re-theme cached terminals when the system appearance flips.
    private func refreshThemes() {
        for view in terminals.values {
            applyTheme(to: view)
            view.needsDisplay = true
        }
        generation += 1
    }

    /// ANSI 16-color palette tuned for a white background
    /// (dim enough to stay readable on white, based on Tango/Terminal.app light).
    private static let lightAnsiPalette: [SwiftTerm.Color] = [
        rgb(0x00, 0x00, 0x00), // black
        rgb(0xC2, 0x36, 0x21), // red
        rgb(0x1A, 0x92, 0x1C), // green
        rgb(0xA1, 0x6A, 0x00), // yellow -> dark amber
        rgb(0x20, 0x53, 0xB3), // blue
        rgb(0xA6, 0x38, 0xA6), // magenta
        rgb(0x0E, 0x84, 0x8A), // cyan
        rgb(0x8E, 0x8E, 0x93), // white -> light grey
        rgb(0x5A, 0x5A, 0x5A), // bright black
        rgb(0xE3, 0x4F, 0x3B), // bright red
        rgb(0x2E, 0xA4, 0x30), // bright green
        rgb(0xB8, 0x86, 0x0B), // bright yellow
        rgb(0x3B, 0x74, 0xD9), // bright blue
        rgb(0xC5, 0x4F, 0xC5), // bright magenta
        rgb(0x17, 0xA2, 0xA9), // bright cyan
        rgb(0x3C, 0x3C, 0x3C), // bright white -> near black (bold text on white)
    ]

    /// ANSI 16-color palette for the dark background (VS Code dark terminal).
    private static let darkAnsiPalette: [SwiftTerm.Color] = [
        rgb(0x3C, 0x3C, 0x3C), // black (visible on #1E1E1E)
        rgb(0xCD, 0x31, 0x31), // red
        rgb(0x0D, 0xBC, 0x79), // green
        rgb(0xE5, 0xE5, 0x10), // yellow
        rgb(0x24, 0x72, 0xC8), // blue
        rgb(0xBC, 0x3F, 0xBC), // magenta
        rgb(0x11, 0xA8, 0xCD), // cyan
        rgb(0xE5, 0xE5, 0xE5), // white
        rgb(0x66, 0x66, 0x66), // bright black
        rgb(0xF1, 0x4C, 0x4C), // bright red
        rgb(0x23, 0xD1, 0x8B), // bright green
        rgb(0xF5, 0xF5, 0x43), // bright yellow
        rgb(0x3B, 0x8E, 0xEA), // bright blue
        rgb(0xD6, 0x70, 0xD6), // bright magenta
        rgb(0x29, 0xB8, 0xDB), // bright cyan
        rgb(0xFF, 0xFF, 0xFF), // bright white
    ]

    private static func rgb(_ r: UInt16, _ g: UInt16, _ b: UInt16) -> SwiftTerm.Color {
        Color(red: r * 257, green: g * 257, blue: b * 257)
    }
}

extension TerminalManager: LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            source.getTerminal().feed(
                text: "\r\n\u{1b}[90m── session ended (exit \(exitCode.map(String.init) ?? "?")) — ↻ on the tab restarts it ──\u{1b}[0m\r\n"
            )
            if let key = self.terminals.first(where: { $0.value === source })?.key {
                self.deadTabs.insert(key)
                self.generation += 1
            }
        }
    }
}
