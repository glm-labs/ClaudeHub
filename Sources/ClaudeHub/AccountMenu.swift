import SwiftUI

/// The things the Claude menu and the sidebar account chip can do.
///
/// Browser logins go through the `claude auth` CLI in a visible terminal tab,
/// so the real login flow (browser, SSO, 2FA) happens exactly as it normally
/// would. Saved accounts are `claude setup-token` tokens you paste, checked
/// against the API before they are kept and every time you switch to one.
enum ClaudeCommands {

    // MARK: Slash commands in the current session

    static func canSend(_ tabs: TabsModel) -> Bool {
        guard let tab = tabs.activeTab, tab.isConversation else { return false }
        return TerminalManager.shared.activity(of: tab.id) != .dead
    }

    static func send(_ command: String, tabs: TabsModel) {
        guard let tab = tabs.activeTab, tab.isConversation else { return }
        TerminalManager.shared.sendSlashCommand(command, to: tab.id)
    }

    // MARK: Accounts

    /// `email == nil` opens the plain login picker, same as `/login`.
    static func logIn(as email: String?, accounts: AccountStore, tabs: TabsModel) {
        var args = ["auth", "login"]
        if let email, !email.isEmpty {
            args += ["--email", email]
            accounts.remember(email)
        }
        tabs.openCommand(args, title: email.map { "Login · \($0)" } ?? "Login")
        // The browser round trip takes a while; the window regaining focus
        // refreshes too, this just catches a login that finished in the tab.
        accounts.refreshSoon(after: 15)
        accounts.refreshSoon(after: 45)
    }

    static func promptForNewAccount(accounts: AccountStore, tabs: TabsModel) {
        let alert = NSAlert()
        alert.messageText = "Sign in to another account"
        alert.informativeText = """
            ClaudeHub only remembers the address, so you can switch back with one \
            click later. The login itself runs `claude auth login` in a tab.
            """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "you@example.com"
        alert.accessoryView = field
        alert.addButton(withTitle: "Log In")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let email = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        logIn(as: email.isEmpty ? nil : email, accounts: accounts, tabs: tabs)
    }

    // MARK: Saved accounts (instant, no browser)

    /// Mints a token for whichever account you log in as, in a visible tab.
    static func runSetupToken(tabs: TabsModel) {
        tabs.openCommand(["setup-token"], title: "Setup token")
    }

    static func addProfile(accounts: AccountStore, tabs: TabsModel) {
        let alert = NSAlert()
        alert.messageText = "Add an account you can switch to instantly"
        alert.informativeText = """
            Run `claude setup-token` while signed in as that account, then paste \
            the token it prints. ClaudeHub checks it with Anthropic, keeps it in \
            your login keychain, and runs the sessions you start as that account \
            — no browser, and other tabs keep running on their own account.
            """
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: 56))
        let label = NSTextField(frame: NSRect(x: 0, y: 30, width: 330, height: 22))
        label.placeholderString = "Name (optional — the account's e-mail by default)"
        let token = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 330, height: 22))
        token.placeholderString = "Token from claude setup-token"
        container.addSubview(label)
        container.addSubview(token)
        alert.accessoryView = container
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Run setup-token…")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = token

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let name = label.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let secret = token.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !secret.isEmpty else {
                return report(AccountError(message: "No token was entered."),
                              name: name, token: nil, accounts: accounts, tabs: tabs)
            }
            accounts.addProfile(name, token: secret) { result in
                switch result {
                case .success(let saved):
                    let done = NSAlert()
                    done.messageText = "Now running as \(saved)"
                    // A setup-token never names its account, so what the check
                    // did establish is said plainly instead of implying more.
                    let checked = accounts.identity(of: saved)
                    done.informativeText = """
                        \(checked) Every open conversation moves to this account and \
                        resumes where it was — one that is mid-answer moves when it \
                        finishes, never interrupted. Shell tabs are left alone.
                        """
                    done.runModal()
                case .failure(let error):
                    report(error, name: name, token: secret, accounts: accounts, tabs: tabs)
                }
            }
        case .alertSecondButtonReturn:
            runSetupToken(tabs: tabs)
        default:
            break
        }
    }

    /// A token that does not authenticate is the common case worth explaining:
    /// `setup-token` output is easy to truncate, and tokens expire.
    private static func report(_ error: AccountError,
                               name: String,
                               token: String?,
                               accounts: AccountStore,
                               tabs: TabsModel) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if error.savedAnyway {
            alert.messageText = "Saved, but not verified"
            alert.informativeText = """
                \(error.message)

                Sessions you start will use it; if it turns out to be expired \
                they will say so on their first message.
                """
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        alert.messageText = "That token was not accepted"
        alert.informativeText = """
            \(error.message)

            Tokens come from `claude setup-token`, run while signed in as the \
            other account — copy the whole `sk-ant-oat…` line it prints.
            """
        alert.addButton(withTitle: "Run setup-token…")
        alert.addButton(withTitle: "Try Again…")
        if token != nil { alert.addButton(withTitle: "Save Anyway") }
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            runSetupToken(tabs: tabs)
        case .alertSecondButtonReturn:
            addProfile(accounts: accounts, tabs: tabs)
        case .alertThirdButtonReturn:
            guard let token else { return }
            accounts.saveUnchecked(name, token: token)
        default:
            break
        }
    }

    static func removeProfile(_ label: String, accounts: AccountStore) {
        let alert = NSAlert()
        alert.messageText = "Forget \(label)?"
        alert.informativeText = """
            The token is deleted from your keychain. Sessions already running as \
            this account keep going. Revoke the token itself at claude.ai if you \
            no longer want it to work at all.
            """
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        accounts.removeProfile(label)
    }

    static func logOut(accounts: AccountStore, tabs: TabsModel) {
        let alert = NSAlert()
        alert.messageText = "Log out of Claude Code?"
        alert.informativeText = """
            This signs out the `claude` CLI everywhere, not just in ClaudeHub. \
            Sessions that are already running keep going until they need to \
            authenticate again.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Log Out")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        tabs.openCommand(["auth", "logout"], title: "Logout")
        accounts.refreshSoon(after: 4)
    }
}

/// Account items, shared by the menu-bar Claude menu and the sidebar chip.
///
/// One switch, not a per-session choice: picking an account here is what every
/// session, resume and terminal ClaudeHub starts from then on runs as.
struct AccountItems: View {
    @ObservedObject var accounts: AccountStore
    @ObservedObject var tabs: TabsModel
    /// Passed in rather than taken from the environment: this view also builds
    /// the menu-bar items, and a Commands scene has no environment to take it
    /// from.
    @ObservedObject var usage: UsageStore

    private var withoutToken: [String] {
        accounts.knownEmails.filter {
            $0 != accounts.current?.email && !accounts.tokenProfiles.contains($0)
        }
    }

    var body: some View {
        if let active = accounts.activeProfile {
            Section("This is what was checked") {
                Text(accounts.identity(of: active))
            }
        }

        Section("Sessions run as") {
            if accounts.signedInTwin == nil {
                item(label: signedInLabel, profile: nil)
            }
            ForEach(accounts.tokenProfiles, id: \.self) { profile in
                item(label: menuLabel(for: profile), profile: profile)
            }
        }

        if let locked = accounts.lockedProfiles.first {
            Divider()
            Text("\(locked)'s token is locked in your keychain")
            Button("Unlock \(locked)…") { accounts.unlock(locked) }
        } else if let broken = brokenProfile {
            Divider()
            Text("\(broken) cannot sign in — its token was rejected")
            Button("Replace \(broken)'s Token…") {
                ClaudeCommands.addProfile(accounts: accounts, tabs: tabs)
            }
        }

        Divider()

        Button("Add Account…") {
            ClaudeCommands.addProfile(accounts: accounts, tabs: tabs)
        }

        Menu("More") {
            Button("Sign In with Browser…") {
                ClaudeCommands.logIn(as: nil, accounts: accounts, tabs: tabs)
            }
            ForEach(withoutToken, id: \.self) { email in
                Button("Sign In as \(email)…") {
                    ClaudeCommands.logIn(as: email, accounts: accounts, tabs: tabs)
                }
            }

            Divider()

            Button("Re-check Accounts") {
                accounts.refresh()
                accounts.primeTokens()
            }
            Button("Log Out…") { ClaudeCommands.logOut(accounts: accounts, tabs: tabs) }

            if !accounts.tokenProfiles.isEmpty || !withoutToken.isEmpty {
                Divider()
                Menu("Forget") {
                    ForEach(accounts.tokenProfiles, id: \.self) { profile in
                        Button("\(profile) (saved account)") {
                            ClaudeCommands.removeProfile(profile, accounts: accounts)
                        }
                    }
                    ForEach(withoutToken, id: \.self) { email in
                        Button(email) { accounts.forget(email) }
                    }
                }
            }
        }
    }

    private var signedInLabel: String {
        guard let current = accounts.current else { return "Signed-in account" }
        let name = "\(current.email) (signed in)"
        guard let limits = usage.signedInSummary else { return "\u{26AA}  \(name)" }
        let dot = AccountStore.dot(session: usage.signedInSession, week: usage.signedInWeek)
        let best = roomiest == .signedIn ? "   \u{2190} most room" : ""
        return "\(dot)  \(name) — \(limits)\(best)"
    }

    /// The name you gave it, plus what the token turned out to be — so a saved
    /// account is never just a label you have to take on faith.
    private func menuLabel(for profile: String) -> String {
        let status = accounts.status(of: profile)
        if status.locked { return "\u{1F512}  \(profile) — locked in the keychain" }
        if status.problem != nil { return "\u{26D4}  \(profile) — token rejected" }
        if status.isChecking { return "\u{26AA}  \(profile) — checking…" }

        // What you open this menu to find out: which account still has room.
        // The dot answers it before the sentence does.
        let name = accounts.isDistinctAccount(profile) == false
            ? "\(profile) (same account as signed in)"
            : profile
        guard let limits = accounts.limitsSummary(for: profile) else {
            return "\(accounts.dot(for: profile))  \(name)"
        }
        // Marked even when it is the account you are already on: an absent
        // arrow then means one thing only — not enough is known yet — instead
        // of standing for both "you are on the best one" and "no idea".
        let best = roomiest == .saved(profile) ? "   \u{2190} most room" : ""
        return "\(accounts.dot(for: profile))  \(name) — \(limits)\(best)"
    }

    /// Worked out once per menu build, not once per row.
    ///
    /// With the signed-in row hidden behind its twin, the arrow must land on a
    /// row that is actually there, so the signed-in account is left out.
    private var roomiest: AccountStore.RoomiestAccount? {
        guard accounts.signedInTwin == nil else { return accounts.roomiest(signedIn: (nil, nil)) }
        return accounts.roomiest(signedIn: (usage.signedInSession, usage.signedInWeek))
    }

    private var brokenProfile: String? {
        accounts.tokenProfiles.first { accounts.status(of: $0).problem != nil }
    }

    /// Running as the signed-in account checks its twin, since that is the row
    /// standing in for it.
    private func isChecked(_ profile: String?) -> Bool {
        if accounts.activeProfile == profile { return true }
        return accounts.activeProfile == nil && profile != nil && profile == accounts.signedInTwin
    }

    @ViewBuilder
    private func item(label: String, profile: String?) -> some View {
        Button {
            // Picking an account restarts every conversation on it; the one
            // you are already on has nothing to move to.
            guard !isChecked(profile) else { return }
            accounts.setActive(profile)
        } label: {
            if isChecked(profile) {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }
}

/// Sidebar footer chip — which account am I burning limits on right now.
struct AccountChip: View {
    @ObservedObject var accounts: AccountStore
    @ObservedObject var tabs: TabsModel
    @ObservedObject var usage: UsageStore

    private var helpText: String {
        if let active = accounts.activeProfile {
            return """
                Sessions run as \(accounts.describe(profile: active)).
                \(accounts.identity(of: active))
                Picking an account moves every open conversation to it; one
                that is busy moves as soon as it is done.
                """
        }
        return accounts.current.map { "Sessions run as \($0.email), the signed-in account" }
            ?? "Not signed in — click to log in"
    }

    /// Broken beats signed-out: a rejected token is the one state where every
    /// session you start from here will fail on its first message.
    private var icon: String {
        if accounts.activeProfileIsBroken { return "exclamationmark.triangle.fill" }
        if accounts.activeProfile != nil { return "person.crop.circle.fill" }
        return accounts.current == nil
            ? "person.crop.circle.badge.exclamationmark"
            : "person.crop.circle"
    }

    @State private var hovering = false

    var body: some View {
        Menu {
            AccountItems(accounts: accounts, tabs: tabs, usage: usage)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundStyle(accounts.activeProfileIsBroken ? Color.orange : Color.secondary)
                Text(accounts.effectiveLabel)
                    .lineLimit(1)
                if let plan = accounts.activeProfile == nil ? accounts.current?.planLabel : nil {
                    Text(plan)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                }
                // The popup chevron every macOS picker wears — without it this
                // read as a caption, not a control.
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // Chrome on the menu, not in the label: label styling gets flattened
        // by the borderless menu button and never reaches the screen.
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(hovering ? 0.10 : 0.05))
        )
        .onHover { value in
            DispatchQueue.main.async { hovering = value }
        }
        .clickable()
        .help(helpText)
    }
}
