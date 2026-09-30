import AppKit
import Combine
import Foundation

/// Who Claude Code is currently logged in as, per `claude auth status --json`.
struct ClaudeAccount: Equatable {
    let email: String
    let orgID: String?
    let plan: String?          // "pro", "max", …

    var shortEmail: String {
        email.split(separator: "@").first.map(String.init) ?? email
    }

    var planLabel: String? {
        guard let plan, !plan.isEmpty else { return nil }
        return plan.prefix(1).uppercased() + plan.dropFirst()
    }

}

/// Why an account could not be added, phrased for the person adding it.
struct AccountError: Error {
    let message: String
    /// True when the token was kept anyway — we could not reach the API to
    /// judge it, which is not the same as the API refusing it.
    var savedAnyway = false
}

/// What we know about a saved account: whose it is, and whether its token still
/// works. A token that was fine last week is not a token that is fine now, so
/// this is a checked fact with a timestamp, not a setting.
struct ProfileStatus: Equatable {
    /// The organisation the API billed a test request to — the one fact a
    /// setup-token will disclose about whose it is.
    var organizationID: String?
    /// How much of this account's windows is gone, so the menu can answer the
    /// question you actually open it with: which account has room left.
    var session: UsageWindow?
    var week: UsageWindow?
    var limitsAt: Date?
    /// Non-nil means the API refused the token — this account cannot run.
    var problem: String?
    /// Non-nil means we could not reach the API; the token may still be fine.
    var unverified: String?
    /// The token is saved but macOS would not hand it over — a keychain panel
    /// away from working, not a broken account.
    var locked = false
    var checkedAt: Date?
    var isChecking = false

    /// One line for the menu and the tooltip.
    var summary: String {
        if isChecking { return "Checking…" }
        if locked, let problem { return problem }
        if let problem { return "Token rejected — \(problem)" }
        if let unverified { return "Not checked — \(unverified)" }
        return "Token saved"
    }
}

/// Tracks the signed-in account and the accounts you switch between.
///
/// Two mechanisms live here. `claude auth login` changes the one account the
/// CLI is signed in as, machine-wide. A saved token instead rides along in a
/// single session's environment, which is what lets two tabs run as two
/// accounts at once — and, unlike a login, it can be checked without a browser.
final class AccountStore: ObservableObject {
    @Published private(set) var current: ClaudeAccount?
    /// Not logged in, or `claude auth status` could not be read.
    @Published private(set) var statusMessage: String?
    /// Every address seen or added, so you can switch back with one click.
    @Published private(set) var knownEmails: [String] =
        UserDefaults.standard.stringArray(forKey: "knownAccountEmails") ?? []

    /// Accounts with a saved token, ready to run without a browser.
    @Published private(set) var tokenProfiles: [String] = TokenStore.profiles
    /// nil = run as whoever the CLI is signed in as.
    @Published private(set) var activeProfile: String? = TokenStore.activeProfile
    /// Per saved account: whose token it is and whether it still authenticates.
    @Published private(set) var profileStatus: [String: ProfileStatus] = AccountStore.loadStatuses()

    /// Everything ClaudeHub starts from now on runs as this account.
    func setActive(_ profile: String?) {
        TokenStore.activeProfile = profile
        activeProfile = TokenStore.activeProfile
        if let profile, status(of: profile).checkedAt == nil { verify(profile) }
        NotificationCenter.default.post(name: .activeAccountChanged, object: nil)
    }

    private var inFlight = false

    // MARK: - Saved accounts

    /// Saves a token only once it has proved it authenticates, and reports back
    /// whose account it turned out to be — the alternative is a silent Save
    /// that looks identical whether the token works or not.
    ///
    /// `label` may be empty: the account's own e-mail names it instead.
    func addProfile(_ label: String,
                    token: String,
                    completion: @escaping (Result<String, AccountError>) -> Void) {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return completion(.failure(AccountError(message: "No token was entered."))) }

        TokenCheck.run(token: token) { [weak self] result in
            guard let self else { return }
            switch result {
            case .rejected(let why):
                completion(.failure(AccountError(message: why)))
            case .valid(let org):
                let name = self.name(for: label)
                guard TokenStore.save(token: token, for: name) else {
                    return completion(.failure(AccountError(message: "The login keychain refused the item.")))
                }
                self.tokenProfiles = TokenStore.profiles
                self.setStatus(ProfileStatus(organizationID: org, checkedAt: Date()), for: name)
                // Saving an account you cannot switch to is not a feature:
                // sessions started from now on run as it.
                self.setActive(name)
                completion(.success(name))
            case .unreachable(let why):
                // Offline is not proof the token is bad; keep it, flag it.
                let name = self.name(for: label)
                guard TokenStore.save(token: token, for: name) else {
                    return completion(.failure(AccountError(message: "The login keychain refused the item.")))
                }
                self.tokenProfiles = TokenStore.profiles
                self.setStatus(ProfileStatus(unverified: why, checkedAt: Date()), for: name)
                self.setActive(name)
                completion(.failure(AccountError(
                    message: "Saved as \(name) and switched to, but it could not be checked: \(why)",
                    savedAnyway: true)))
            }
        }
    }

    /// The escape hatch: keep a token the check refused. The check is a
    /// courtesy, not a gate — if Anthropic ever answers differently for a token
    /// that works fine in a session, the app must not be the thing standing in
    /// the way.
    @discardableResult
    func saveUnchecked(_ label: String, token: String) -> Bool {
        let name = name(for: label)
        guard TokenStore.save(token: token, for: name) else { return false }
        tokenProfiles = TokenStore.profiles
        setStatus(ProfileStatus(unverified: "Saved without a successful check.",
                                checkedAt: Date()), for: name)
        setActive(name)
        return true
    }

    private func name(for label: String) -> String {
        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "Account \(tokenProfiles.count + 1)" : clean
    }

    func removeProfile(_ label: String) {
        TokenStore.delete(label)
        tokenProfiles = TokenStore.profiles
        activeProfile = TokenStore.activeProfile
        profileStatus[label] = nil
        persistStatuses()
    }

    /// Loads the saved tokens once, off the main thread, and checks each one.
    ///
    /// The keychain panel that an updated build raises blocks the thread that
    /// asked, so this must never be the main one — and doing it up front means
    /// starting a session later never waits on a panel.
    func primeTokens() {
        let profiles = tokenProfiles
        guard !profiles.isEmpty else { return }
        for profile in profiles {
            var status = self.status(of: profile)
            status.isChecking = true
            setStatus(status, for: profile, persist: false)
        }
        TokenStore.prime(profiles) { [weak self] in
            self?.verifyAll()
            self?.refreshLimits(force: true)
        }
    }

    /// Re-asks the API whether a saved token still authenticates.
    func verify(_ profile: String) {
        guard let token = TokenStore.cachedToken(for: profile) else {
            // Not in hand: either macOS blocked the read, or the item is gone.
            let problem = TokenStore.blockedReason(for: profile)
                ?? "The token is no longer in your keychain — paste it again."
            var status = self.status(of: profile)
            status.isChecking = false
            status.problem = problem
            status.locked = true
            setStatus(status, for: profile)
            // No automatic retry: the panel was just answered, and asking again
            // on its own would only put a second one on screen. "Unlock" in the
            // account menu is the deliberate way back.
            return
        }
        var status = profileStatus[profile] ?? ProfileStatus()
        status.isChecking = true
        status.problem = nil
        status.locked = false
        setStatus(status, for: profile, persist: false)

        TokenCheck.run(token: token) { [weak self] result in
            guard let self else { return }
            switch result {
            case .valid(let org):
                self.setStatus(ProfileStatus(organizationID: org ?? status.organizationID,
                                             checkedAt: Date()), for: profile)
            case .rejected(let why):
                self.setStatus(ProfileStatus(organizationID: status.organizationID,
                                             problem: why,
                                             checkedAt: Date()), for: profile)
            case .unreachable(let why):
                self.setStatus(ProfileStatus(organizationID: status.organizationID,
                                             unverified: why,
                                             checkedAt: Date()), for: profile)
            }
        }
    }

    func verifyAll() {
        for profile in tokenProfiles { verify(profile) }
    }

    // MARK: - How much room each account has left

    private var limitsTimer: Timer?
    private var lastLimitsPoll: Date?
    private let limitsInterval: TimeInterval = 180

    /// Keeps every saved account's limits current, so switching is a decision
    /// rather than a guess.
    ///
    /// One small request per account, only while the window is in front —
    /// reading a limit is not free, and numbers nobody is looking at are not
    /// worth paying for.
    func startLimitPolling() {
        guard limitsTimer == nil else { return }
        limitsTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshLimits()
        }
        refreshLimits()
    }

    func refreshLimits(force: Bool = false) {
        guard force || NSApplication.shared.isActive else { return }
        if !force, let last = lastLimitsPoll,
           Date().timeIntervalSince(last) < limitsInterval { return }
        lastLimitsPoll = Date()
        for profile in tokenProfiles where status(of: profile).problem == nil {
            guard let token = TokenStore.cachedToken(for: profile) else { continue }
            TokenCheck.limits(token: token) { [weak self] headers in
                guard let self else { return }
                let windows = UsageStore.windows(from: headers)
                guard windows.session != nil || windows.week != nil else { return }
                var status = self.status(of: profile)
                status.session = windows.session
                status.week = windows.week
                status.limitsAt = Date()
                self.setStatus(status, for: profile, persist: false)
            }
        }
    }

    /// "5h 4%, resets in 4 hr 48 min · week 10%", or nil until it is known.
    func limitsSummary(for profile: String) -> String? {
        let status = self.status(of: profile)
        return AccountStore.summary(session: status.session, week: status.week)
    }

    static func summary(session: UsageWindow?, week: UsageWindow?) -> String? {
        let now = Date()
        var parts: [String] = []
        // Both windows say when they come back: which of the two binds first
        // is the whole question, and it cannot be answered from percentages
        // alone. The panel's own wording stands in when a reset could not be
        // turned into a date, so a row is never left silent about it.
        if let session {
            let left = session.countdown(from: now)
                .map { $0.replacingOccurrences(of: "Resets in ", with: "resets in ") }
                ?? session.resets.nonEmpty.map { "resets \($0)" }
            parts.append("5h \(session.percent)%\(left.map { ", \($0)" } ?? "")")
        }
        if let week {
            let left = week.countdown(from: now)
                .map { $0.replacingOccurrences(of: "Resets in ", with: "") }
                ?? week.resets.nonEmpty
            parts.append("week \(week.percent)%\(left.map { " (\($0))" } ?? "")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// A menu row is scanned, not read: the dot carries the answer and the
    /// numbers back it up. Worst of the two windows, because the one that runs
    /// out first is the one that stops you.
    static func dot(session: UsageWindow?, week: UsageWindow?) -> String {
        let levels = [session?.level, week?.level].compactMap { $0 }
        guard let worst = levels.max() else { return "\u{26AA}" }        // not known yet
        switch worst {
        case 2: return "\u{1F534}"                                       // nearly out
        case 1: return "\u{1F7E1}"                                       // getting there
        default: return "\u{1F7E2}"                                      // room to work
        }
    }

    func dot(for profile: String) -> String {
        let status = self.status(of: profile)
        return AccountStore.dot(session: status.session, week: status.week)
    }

    /// Which account to go to next.
    enum RoomiestAccount: Equatable {
        case signedIn
        case saved(String)
    }

    /// The account with the most room, judged against the clock rather than on
    /// the percentages alone.
    ///
    /// A raw percentage is the wrong comparison. 80% of a five-hour window that
    /// resets in ten minutes is nearly free again; 55% of a weekly window with
    /// six days still to run is not. So each window is scored as what is left
    /// of the budget over what is left of the window: above 1 means the budget
    /// is outlasting the clock, below 1 means it is running out first. An
    /// account is worth no more than its tightest window, so the two are
    /// combined by taking the worse — which is the one that will stop you.
    func roomiest(signedIn: (session: UsageWindow?, week: UsageWindow?)) -> RoomiestAccount? {
        var scored: [(account: RoomiestAccount, room: Double)] = []
        if let room = Self.headroom(session: signedIn.session, week: signedIn.week) {
            scored.append((.signedIn, room))
        }
        for profile in tokenProfiles {
            let status = self.status(of: profile)
            guard status.problem == nil,
                  let room = Self.headroom(session: status.session, week: status.week) else { continue }
            scored.append((.saved(profile), room))
        }
        // Nothing to point at when there is nothing to compare it with.
        guard scored.count > 1 else { return nil }
        return scored.max { $0.room < $1.room }?.account
    }

    /// The tighter of the two windows, or nil when neither has been read.
    static func headroom(session: UsageWindow?, week: UsageWindow?) -> Double? {
        let rooms = [headroom(session, length: 5 * 3600),
                     headroom(week, length: 7 * 86_400)].compactMap { $0 }
        return rooms.min()
    }

    /// Budget left ÷ window left. A window about to reset scores high however
    /// spent it is, which is the point: it is about to hand the budget back.
    private static func headroom(_ window: UsageWindow?,
                                 length: TimeInterval,
                                 now: Date = Date()) -> Double? {
        guard let window else { return nil }
        let budgetLeft = Double(100 - window.percent) / 100
        guard let resetsAt = window.resetsAt else { return budgetLeft }
        let timeLeft = max(0, resetsAt.timeIntervalSince(now))
        // Clamped so a reset seconds away scores high but not infinitely so.
        let windowLeft = min(max(timeLeft / length, 0.01), 1)
        return budgetLeft / windowLeft
    }

    /// Asks macOS for the token again, which is what raises the keychain panel
    /// where Always Allow lives.
    func unlock(_ profile: String) {
        TokenStore.prime([profile]) { [weak self] in
            self?.verify(profile)
        }
    }

    /// Accounts that are saved but unreadable right now.
    var lockedProfiles: [String] {
        tokenProfiles.filter { status(of: $0).locked }
    }

    func status(of profile: String) -> ProfileStatus {
        profileStatus[profile] ?? ProfileStatus()
    }

    /// Whether a saved token really is a different account from the one the
    /// CLI is signed in as — checked, not assumed from the label you typed.
    ///
    /// Returns nil when the API did not name an organisation, because "we do
    /// not know" must not be dressed up as either answer.
    func isDistinctAccount(_ profile: String) -> Bool? {
        guard let token = status(of: profile).organizationID,
              let signedIn = current?.orgID else { return nil }
        return token.caseInsensitiveCompare(signedIn) != .orderedSame
    }

    /// A saved account that is checked to be the signed-in account itself, and
    /// can run — the menu lists it in place of the signed-in row instead of
    /// showing the same account twice.
    ///
    /// A locked or rejected twin does not count: hiding the signed-in row
    /// behind it would leave no working way onto that account.
    var signedInTwin: String? {
        tokenProfiles.first { profile in
            let status = self.status(of: profile)
            return isDistinctAccount(profile) == false && !status.locked && status.problem == nil
        }
    }

    /// One sentence on whose account a saved token turned out to be.
    func identity(of profile: String) -> String {
        switch isDistinctAccount(profile) {
        case true:
            return """
                Checked: a different account from \(current?.email ?? "the signed-in one") \
                — the API billed the test request to another organisation.
                """
        case false:
            return """
                Careful: this token bills to the same organisation as \
                \(current?.email ?? "the signed-in account"), so it is that account, \
                not a second one.
                """
        default:
            return "The API did not say whose account this token is."
        }
    }

    /// The account a tab actually runs as, spelled out for menus and tooltips.
    func describe(profile: String?) -> String {
        guard let profile else {
            return current.map { "\($0.email) (signed in)" } ?? "the signed-in account"
        }
        return profile
    }

    private func setStatus(_ status: ProfileStatus, for profile: String, persist: Bool = true) {
        profileStatus[profile] = status
        if persist { persistStatuses() }
    }

    /// What the sidebar chip shows: the account sessions actually run as.
    var effectiveLabel: String {
        activeProfile ?? current?.shortEmail ?? "Sign in"
    }

    /// The active account cannot authenticate — sessions started now will fail.
    var activeProfileIsBroken: Bool {
        guard let activeProfile else { return false }
        return status(of: activeProfile).problem != nil
    }

    // MARK: - The signed-in account

    func refresh() {
        guard !inFlight else { return }
        inFlight = true

        let claude = TerminalManager.shared.claudePath
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.readStatus(claude: claude)
            DispatchQueue.main.async {
                self.inFlight = false
                switch result {
                case .success(let account):
                    self.current = account
                    self.statusMessage = nil
                    self.remember(account.email)
                case .failure(let message):
                    self.current = nil
                    self.statusMessage = message
                }
            }
        }
    }

    /// `claude auth login` finishes in a terminal tab; give the CLI a moment
    /// to write the new credentials before asking who we are now.
    func refreshSoon(after seconds: TimeInterval = 3) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.refresh()
        }
    }

    func remember(_ email: String) {
        let clean = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard clean.contains("@"), !knownEmails.contains(clean) else { return }
        knownEmails.append(clean)
        knownEmails.sort()
        persist()
    }

    func forget(_ email: String) {
        knownEmails.removeAll { $0 == email }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(knownEmails, forKey: "knownAccountEmails")
    }

    // MARK: - Remembering what each token turned out to be

    private static let statusKey = "profileStatuses"

    private func persistStatuses() {
        let stored = profileStatus.mapValues { status -> [String: String] in
            var fields: [String: String] = [:]
            if let org = status.organizationID { fields["org"] = org }
            // A locked token is this launch's problem, not next launch's: the
            // panel may well be answered with Always Allow before then.
            if let problem = status.problem, !status.locked { fields["problem"] = problem }
            return fields
        }
        UserDefaults.standard.set(stored, forKey: Self.statusKey)
    }

    private static func loadStatuses() -> [String: ProfileStatus] {
        let stored = UserDefaults.standard.dictionary(forKey: statusKey) as? [String: [String: String]]
        return (stored ?? [:]).mapValues {
            ProfileStatus(organizationID: $0["org"], problem: $0["problem"])
        }
    }

    // MARK: - Reading `claude auth status`

    private enum StatusResult {
        case success(ClaudeAccount)
        case failure(String)
    }

    private static func readStatus(claude: String) -> StatusResult {
        // A login shell so node/nvm-style installs resolve the same way they do
        // in the user's own terminal.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "\(ClaudeSession.shellQuote(claude)) auth status --json"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return .failure("Could not run `claude auth status`.")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("`claude auth status` returned no readable status.")
        }
        guard json["loggedIn"] as? Bool == true, let email = json["email"] as? String else {
            return .failure("Not signed in — use Switch Account to log in.")
        }
        return .success(ClaudeAccount(
            email: email,
            orgID: json["orgId"] as? String,
            plan: json["subscriptionType"] as? String
        ))
    }
}
