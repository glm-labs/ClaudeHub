import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var tabs: TabsModel
    @EnvironmentObject var accounts: AccountStore
    @EnvironmentObject var usage: UsageStore
    @EnvironmentObject var git: GitStore
    @ObservedObject var terminalManager = TerminalManager.shared
    @ObservedObject var updates = UpdateChecker.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedSessionID: String?
    @State private var searchText = ""
    @State private var showMCPManager = false
    @State private var showHiddenSessions = false
    @State private var pendingDeletion: [ClaudeSession] = []
    @State private var deletionScope = ""
    @State private var deleteError: String?

    /// Matches the SwiftTerm palette background in TerminalManager.
    private var terminalBackground: SwiftUI.Color {
        colorScheme == .dark ? Color(red: 0.118, green: 0.118, blue: 0.118) : .white
    }

    private var filteredProjects: [ClaudeProject] {
        let visible: [ClaudeProject] = store.projects.compactMap { project in
            var copy = project
            copy.sessions = project.sessions.filter {
                showHiddenSessions || !store.hiddenSessionIDs.contains($0.id)
            }
            return copy.sessions.isEmpty ? nil : copy
        }
        guard !searchText.isEmpty else { return visible }
        let query = searchText.lowercased()
        return visible.compactMap { project in
            if project.name.lowercased().contains(query) { return project }
            let sessions = project.sessions.filter { $0.title.lowercased().contains(query) }
            guard !sessions.isEmpty else { return nil }
            var copy = project
            copy.sessions = sessions
            return copy
        }
    }

    /// A session's dot comes from the tab running it — which may be the tab it
    /// was started in (⌘N) or one opened under another account, so the tab id
    /// is not always the session id.
    private func activity(of session: ClaudeSession) -> TerminalActivity {
        guard let tab = tabs.tab(forSessionID: session.id) else { return .stopped }
        return terminalManager.activity(of: tab.id)
    }

    /// Where the conversation of the tab in front of you is written down.
    private var activeTranscript: URL? {
        guard let sessionID = tabs.activeTab?.sessionID else { return nil }
        return session(withID: sessionID)?.fileURL
    }

    private func step(forward: Bool) {
        guard let id = tabs.activeTabID, !findTerm.isEmpty else { return }
        findShown = true

        // A conversation is searched in its transcript, so stepping walks the
        // results rather than the handful of screens the terminal still holds.
        guard findResults.isEmpty else {
            let next = (findSelected ?? (forward ? -1 : 0)) + (forward ? 1 : -1)
            findSelected = min(max(next, 0), findResults.count - 1)
            return
        }
        findMatches = terminalManager.find(findTerm, in: id, forward: forward)
    }

    private func searchFromStart() {
        guard let id = tabs.activeTabID else { return }
        guard !findTerm.isEmpty else {
            terminalManager.clearFind(in: id)
            findMatches = (0, 0)
            findResults = []
            findSelected = nil
            return
        }
        guard let transcript = activeTranscript else {
            findResults = []
            findMatches = terminalManager.findFromStart(findTerm, in: id)
            return
        }
        let term = findTerm
        // A short pause after the last keystroke: searching on every
        // character rebuilt the result list four times to type "they".
        findWork?.cancel()
        let work = DispatchWorkItem {
            let found = TranscriptSearch.search(term, in: transcript)
            DispatchQueue.main.async {
                // The field may have moved on while the file was being read.
                guard term == findTerm else { return }
                findResults = found
                findSelected = found.isEmpty ? nil : 0
                findMatches = (found.isEmpty ? 0 : 1, found.count)
            }
        }
        findWork = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func closeFind() {
        if let id = tabs.activeTabID { terminalManager.clearFind(in: id) }
        findShown = false
        findTerm = ""
        findMatches = (0, 0)
        findResults = []
        findSelected = nil
        jumpNote = nil
    }

    /// Scrolls the terminal to a transcript result, when it is still in the
    /// scrollback. Claude Code only redraws the recent tail of a conversation
    /// on resume, so an older message has nowhere to jump to — the result row
    /// shows the whole message instead and says so.
    private func jump(toResult index: Int?) {
        jumpNote = nil
        guard let index, findResults.indices.contains(index),
              let id = tabs.activeTabID else { return }
        // The transcript holds markdown; the terminal shows it rendered — no
        // asterisks, bullets redrawn, so the snippet is taken from a plain
        // version of the line, and tried at three lengths: long enough to be
        // unique first, short enough to survive a wrapped row last.
        let line = Self.plainText(findResults[index].line)
        let start = line.range(of: findTerm, options: .caseInsensitive)?.lowerBound ?? line.startIndex
        let rest = String(line[start...])
        for length in [40, 22, 12] {
            let snippet = String(rest.prefix(length)).trimmingCharacters(in: .whitespaces)
            guard snippet.count >= min(length, findTerm.count) else { continue }
            if terminalManager.findFromStart(snippet, in: id).total > 0 { return }
        }
        // Fullscreen Claude Code draws on the alternate screen, which has no
        // scrollback: only what is on screen exists in the terminal at all.
        jumpNote = terminalManager.isOnAlternateScreen(id)
            ? "Not on screen right now (fullscreen Claude Code keeps only the visible part in the terminal) — shown here instead"
            : "Older than the terminal's scrollback — shown here instead"
    }

    /// A transcript line with its markdown taken off, the way Claude Code
    /// draws it.
    private static func plainText(_ text: String) -> String {
        var plain = text
        for token in ["**", "__", "`", "~~"] {
            plain = plain.replacingOccurrences(of: token, with: "")
        }
        plain = plain.replacingOccurrences(of: #"^\s*(?:[-*•>]|\d+\.|#+)\s+"#, with: "",
                                           options: .regularExpression)
        return plain.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// The limits of the account the tab you are looking at is running as.
    ///
    /// Not the active account: a session keeps the account it started with, so
    /// after switching you can be reading a tab on one account while new
    /// sessions would start on another. Showing the second account's bars over
    /// the first account's conversation is how a session that has run out sits
    /// under a bar reading 1%.
    private var usageReadout: UsageReadout {
        if let account = tabs.activeTab.flatMap({ terminalManager.profile(of: $0) }) {
            let status = accounts.status(of: account)
            return UsageReadout(session: status.session,
                                week: status.week,
                                account: account,
                                problem: status.problem ?? status.unverified,
                                isBusy: status.isChecking,
                                updated: status.limitsAt)
        }
        return UsageReadout(session: usage.signedInSession,
                            week: usage.signedInWeek,
                            account: accounts.current?.email ?? "the signed-in account",
                            problem: usage.signedInError,
                            isBusy: usage.isProbing,
                            updated: usage.signedInAt)
    }

    /// What is on screen, and therefore what counts as read. Only while the
    /// app is in front: a session that finished behind another window is
    /// precisely the one you need told about.
    private func syncVisibleTabs() {
        let visible = Set(tabs.visiblePanes)
        terminalManager.visibleTabs = visible
        if NSApplication.shared.isActive { terminalManager.markRead(visible) }
    }

    private func session(withID id: String) -> ClaudeSession? {
        for project in store.projects {
            if let session = project.sessions.first(where: { $0.id == id }) {
                return session
            }
        }
        return nil
    }

    var body: some View {
        // Split in two on purpose: one chain carrying every observer defeats
        // the type-checker, and the error it gives says nothing about why.
        window
        .confirmationDialog(deleteTitle, isPresented: deleteConfirmationBinding, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { confirmDeletion() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { pendingDeletion = [] }
        } message: {
            Text(deleteMessage)
        }
        .alert("Could not delete", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    private var window: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .toolbar { detailToolbar }
        }
        .onAppear {
            store.refresh()
            accounts.refresh()
            // Loads the saved tokens (one keychain panel at most, off the main
            // thread) and checks each one: a token revoked since it was saved
            // should be visible on the chip, not on your first message.
            accounts.primeTokens()
            // Every saved account's limits, not just the active one: the menu
            // is where you decide which account to go to next.
            accounts.startLimitPolling()
            git.startPolling()
            syncVisibleTabs()
            updates.check()
            // The probe needs a folder Claude Code already trusts, so it waits
            // for the first scan — off the sidebar's own update cycle.
            usage.startPolling { store.projects.first?.path }
        }

        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refresh()
            // Coming back to the window is when what is on screen counts as seen.
            syncVisibleTabs()
            git.scan()
            // Coming back from the login page in the browser lands here.
            accounts.refresh()
            // The limits are not polled behind a window nobody is watching, so
            // coming back to it is when they are worth re-reading.
            usage.refresh()
        }
        .onChange(of: store.projects) { _, projects in
            // A ⌘N tab is titled after its folder until the transcript exists.
            tabs.adoptSessionTitles(from: projects)
            git.track(projects: projects.map(\.path))
        }
        .onChange(of: selectedSessionID) { _, id in
            guard let id, let session = session(withID: id) else { return }
            tabs.openSession(session)
        }
        .onChange(of: tabs.activeTabID) { previous, _ in
            // Keep the sidebar in sync with the active tab (nil for fresh-session
            // tabs) — but never from inside the update that brought us here.
            //
            // Clicking a row is a round trip: the list writes the selection, that
            // opens the session, and the tab arriving lands right back here.
            // Writing the selection again at that point re-enters the update
            // SwiftUI is still applying, and the sidebar's table ends up walking
            // rows it has already let go of. Both crashes it takes the app down
            // with name that pass — `withSelectionUpdateGuard`, and an exception
            // thrown mid-layout — so the write waits for the next turn of the
            // loop, and only happens if it would change anything at all.
            let wanted = tabs.activeTab?.sessionID
            if wanted != selectedSessionID {
                DispatchQueue.main.async { selectedSessionID = wanted }
            }
            syncVisibleTabs()
            // A search belongs to the terminal it was run in.
            if let previous { terminalManager.clearFind(in: previous) }
            findMatches = (0, 0)
        }
        .onChange(of: tabs.panes) { _, panes in
            syncVisibleTabs()
            // A new pane arriving or leaving invalidates the old proportions.
            if paneFractions.count != panes.count { paneFractions = [] }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newClaudeSessionInFolder)) { _ in
            newSessionInChosenFolder()
        }
        .onReceive(NotificationCenter.default.publisher(for: .deleteSelectedSession)) { _ in
            requestDeletionOfSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showMCPManager)) { _ in
            showMCPManager = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .findInTab)) { _ in
            findShown = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusTab)) { note in
            guard let id = note.object as? String else { return }
            tabs.show(id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .findNextMatch)) { _ in
            step(forward: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .findPreviousMatch)) { _ in
            step(forward: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .splitActiveTab)) { _ in
            // ⌘\ puts the next tab along beside this one, which is what you
            // want it for: a session and the terminal you are running against
            // it, side by side.
            guard let next = tabs.tabs.first(where: { !tabs.panes.contains($0.id) }) else { return }
            tabs.splitOff(next.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .activeAccountChanged)) { _ in
            // Switching account switches the whole window, not just what you
            // open next: every conversation restarts on the new account and
            // resumes where it was.
            terminalManager.restartConversations(tabs.tabs)
            usage.accountChanged()
        }
    }

    private var sidebar: some View {
        List(selection: $selectedSessionID) {
            ForEach(filteredProjects) { project in
                Section {
                    ForEach(project.sessions) { session in
                        SessionRow(session: session,
                                   activity: activity(of: session),
                                   isHidden: store.hiddenSessionIDs.contains(session.id))
                            .clickable()
                            .tag(session.id)
                            .contextMenu { sessionMenu(session) }
                    }
                } header: {
                    ProjectHeader(
                        project: project,
                        repos: git.repos(forProjectAt: project.path),
                        newSession: { tabs.openNewSession(cwd: project.path); store.refreshSoon() },
                        menu: { projectMenu(project) }
                    )
                }
                .textCase(nil)
            }

            if !git.dirtyRepos.isEmpty {
                // Not selectable: the sidebar's selection is a session, and a
                // repository row painted in selection blue turns a list of file
                // names into something you cannot read.
                Section("Changes") {
                    ForEach(git.dirtyRepos) { repo in
                        RepoRow(
                            repo: repo,
                            newSession: {
                                tabs.openNewSession(cwd: repo.root)
                                store.refreshSoon()
                            },
                            openInEditor: { openInVSCode(repo.root) },
                            openFile: { path in
                                openInVSCode((repo.root as NSString).appendingPathComponent(path))
                            },
                            showDiff: { tabs.openDiff(root: repo.root) },
                            showRawDiff: {
                                tabs.openScript(
                                    "git -c color.ui=always status --short; echo; git -c color.ui=always diff HEAD",
                                    title: "git diff · \(repo.name)",
                                    cwd: repo.root
                                )
                            },
                            reveal: {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: repo.root)
                            },
                            canOpenInEditor: Self.vsCodeURL != nil
                        )
                    }
                }
                .selectionDisabled()
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand { requestDeletionOfSelection() }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search sessions")
        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                UsageBars(readout: usageReadout,
                          showsAccount: usageReadout.account
                              != (accounts.activeProfile ?? accounts.current?.email),
                          refresh: {
                    usage.refreshByHand()
                    accounts.refreshLimits(force: true)
                })
                HStack {
                    AccountChip(accounts: accounts, tabs: tabs, usage: usage)
                Spacer()
                Text("\(store.projects.map(\.sessions.count).reduce(0, +)) sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("\(store.projects.count) projects · ClaudeHub v\(UpdateChecker.currentVersion)")
                if store.isLoading { ProgressView().controlSize(.small) }
                if updates.updateAvailable, let version = updates.latestVersion {
                    Button {
                        updates.downloadAndInstall()
                    } label: {
                        if updates.isInstalling {
                            ProgressView().controlSize(.mini)
                        } else {
                            Label("v\(version)", systemImage: "arrow.down.circle.fill")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                    .help(updates.errorMessage
                          ?? "Update to ClaudeHub \(version) — downloads, installs, and relaunches")
                }
                if !store.hiddenSessionIDs.isEmpty {
                    Button {
                        showHiddenSessions.toggle()
                    } label: {
                        Image(systemName: showHiddenSessions ? "eye" : "eye.slash")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help(showHiddenSessions
                          ? "Hide the \(store.hiddenSessionIDs.count) hidden sessions again"
                          : "Show \(store.hiddenSessionIDs.count) hidden sessions")
                }
            }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(.bar)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    store.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Rescan ~/.claude/projects")
            }
        }
        .sheet(isPresented: $showMCPManager) {
            MCPManagerView()
                .environmentObject(store)
                .environmentObject(tabs)
        }
    }

    /// The panes, side by side, with a handle between them you can drag.
    ///
    /// Widths are kept as fractions rather than points, so the split holds its
    /// proportions when the window is resized instead of one pane swallowing
    /// every extra pixel.
    private var paneStack: some View {
        GeometryReader { geometry in
            let ids = tabs.visiblePanes
            let available = max(1, geometry.size.width
                                - Self.handleWidth * CGFloat(max(0, ids.count - 1)))
            let widths = paneWidths(count: ids.count, available: available)
            HStack(spacing: 0) {
                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    if let paneTab = tabs.tab(withID: id) {
                        pane(paneTab, at: index)
                            .frame(width: widths[index])
                        if index < ids.count - 1 {
                            PaneDivider(
                                width: Self.handleWidth,
                                onChange: { resizePanes(at: index, by: $0, available: available) },
                                onEnd: { paneDragBaseline = nil }
                            )
                        }
                    }
                }
            }
            // The split target only exists while a drag is over it — an
            // always-visible strip is dead space the rest of the time.
            .overlay(alignment: .trailing) { splitDropStrip }
        }
    }

    private static let handleWidth: CGFloat = 6

    private func paneWidths(count: Int, available: CGFloat) -> [CGFloat] {
        paneShares(count).map { available * CGFloat($0) }
    }

    /// Always sums to one, whatever state the stored fractions are in.
    private func paneShares(_ count: Int) -> [Double] {
        let equal = Array(repeating: 1.0 / Double(max(count, 1)), count: count)
        guard paneFractions.count == count else { return equal }
        let total = paneFractions.reduce(0, +)
        guard total > 0 else { return equal }
        return paneFractions.map { $0 / total }
    }

    /// Drag translation is measured from where the drag began, so the widths at
    /// that moment are the ones to add it to — using the live ones would apply
    /// the same movement again on every update.
    private func resizePanes(at index: Int, by dx: CGFloat, available: CGFloat) {
        let count = tabs.visiblePanes.count
        let base = paneDragBaseline ?? paneShares(count)
        if paneDragBaseline == nil { paneDragBaseline = base }
        guard base.indices.contains(index + 1), available > 0 else { return }

        // A pane narrower than this is a column of broken lines, not a view.
        let minimum = min(0.2, 260 / Double(available))
        var delta = Double(dx) / Double(available)
        delta = max(delta, minimum - base[index])
        delta = min(delta, base[index + 1] - minimum)

        var next = base
        next[index] += delta
        next[index + 1] -= delta
        paneFractions = next
    }

    /// One terminal, with a header when it is sharing the window.
    @ViewBuilder
    private func pane(_ tab: TerminalTab, at index: Int) -> some View {
        let isFocused = tab.id == tabs.activeTabID
        VStack(spacing: 0) {
            if tabs.panes.count > 1 {
                HStack(spacing: 6) {
                    TabStrip(pane: index, accounts: accounts)
                    Spacer(minLength: 4)
                    Button { tabs.maximisePane(index) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 8, weight: .bold))
                            .frame(width: 16, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Give this tab the whole window again — the other tabs stay open and keep running")
                    Button { tabs.closePane(index) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .frame(width: 16, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Close this pane — the tab stays open")
                }
                .opacity(isFocused ? 1 : 0.6)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.bar)
                .contentShape(Rectangle())
                .clickable()
                .onTapGesture(count: 2) { tabs.maximisePane(index) }
                .onTapGesture { tabs.activeTabID = tab.id }
                // Dropping a tab on a pane's header puts it in that pane.
                .dropDestination(for: String.self) { ids, _ in
                    guard let id = ids.first else { return false }
                    tabs.show(id, inPane: index)
                    return true
                }
                Divider()
            }
            if case .diff(let root) = tab.kind {
                DiffView(root: root,
                         openInEditor: { file in
                             openInVSCode((root as NSString).appendingPathComponent(file))
                         },
                         close: { tabs.close(tab.id) })
            } else {
                TerminalHostView(tab: tab,
                                 generation: terminalManager.generation,
                                 isFocused: isFocused)
                    .background(terminalBackground)
            }
        }
    }

    /// The edge you drag a tab to when you want it beside what is already
    /// there rather than instead of it.
    @State private var splitTargeted = false
    @State private var paneFractions: [Double] = []
    @State private var findTerm = ""
    @State private var findShown = false
    @State private var findMatches = (index: 0, total: 0)
    @State private var findResults: [TranscriptMatch] = []
    @State private var findSelected: Int?
    /// Why the selected result could not be jumped to, when it could not.
    @State private var jumpNote: String?
    @State private var findWork: DispatchWorkItem?
    @State private var paneDragBaseline: [Double]?

    private var splitDropStrip: some View {
        Rectangle()
            .fill(splitTargeted ? Color.accentColor.opacity(0.22) : Color.clear)
            .frame(width: 18)
            .overlay {
                if splitTargeted {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.15), value: splitTargeted)
            .dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first else { return false }
                tabs.splitOff(id)
                return true
            } isTargeted: { splitTargeted = $0 }
    }

    /// The session the graph button would draw: the active tab's conversation.
    private var activeGraphSession: ClaudeSession? {
        tabs.activeTab?.sessionID.flatMap(session(withID:))
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if Self.vsCodeURL != nil {
                Button {
                    openInVSCode(tabs.currentFolder)
                } label: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                }
                .help("Open \(TabsModel.folderName(tabs.currentFolder)) in VS Code")
            }

            Button {
                if let session = activeGraphSession {
                    openGraph(session, alongside: true)
                }
            } label: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
            }
            .disabled(activeGraphSession == nil)
            .help("Watch this session as a flow graph, beside the conversation")

            Menu {
                Section("Open beside this one") {
                    ForEach(tabs.tabs.filter { !tabs.panes.contains($0.id) }) { tab in
                        Button(tab.title) { tabs.splitOff(tab.id) }
                    }
                }
                if tabs.groups.count > 1 {
                    Divider()
                    Button("Close Other Panes") { tabs.maximisePane(tabs.focusedPane) }
                }
            } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .disabled(tabs.tabs.count <= 1)
            .help("Show two or three tabs side by side (⌘\\) — or drag a tab to the right edge")

            Menu {
                Section(TabsModel.folderName(tabs.currentFolder)) {
                    Button("New Claude Session") { newSession() }
                    Button("New Terminal") { tabs.openNewTab() }
                }
                Divider()
                Button("New Claude Session in Folder…") { newSessionInChosenFolder() }
                if !store.projects.isEmpty {
                    Section("Start in project") {
                        ForEach(store.projects.prefix(10)) { project in
                            Button(project.name) { newSession(in: project.path) }
                                .help(project.path)
                        }
                    }
                }
            } label: {
                Image(systemName: "plus")
            } primaryAction: {
                if tabs.activeTab == nil { newSessionInChosenFolder() } else { newSession() }
            }
            .help("New Claude session (⌘N) — hold for a terminal, another folder, or a project")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let tab = tabs.activeTab {
            VStack(spacing: 0) {
                // Split panes carry their own tab strips in their headers.
                if tabs.groups.count <= 1 {
                    TabBarView(accounts: accounts)
                    Divider()
                }
                if tab.isCommand, let link = terminalManager.signInURL(in: tab.id) {
                    SignInLinkBar(url: link)
                    Divider()
                }
                if findShown {
                    FindBar(term: $findTerm,
                            matches: findMatches,
                            results: findResults,
                            selected: $findSelected,
                            jumpNote: jumpNote,
                            searchesTranscript: activeTranscript != nil,
                            search: searchFromStart,
                            step: step,
                            close: closeFind)
                        // Clicking a result or stepping with ⌘G goes to it.
                        .onChange(of: findSelected) { _, index in jump(toResult: index) }
                    Divider()
                }
                paneStack
            }
            .navigationTitle(tab.title)
            .navigationSubtitle(tab.cwd)
        } else {
            ContentUnavailableView {
                Label("ClaudeHub", systemImage: "terminal")
            } description: {
                Text("Pick a session in the sidebar to resume it right here,\nor start a fresh one.")
            } actions: {
                HStack {
                    Button("New Session…") { newSessionInChosenFolder() }
                        .buttonStyle(.borderedProminent)
                    if let recent = store.projects.first {
                        Button("New Session in \(recent.name)") { newSession(in: recent.path) }
                    }
                }
            }
        }
    }

    // MARK: - Starting sessions

    private func newSession(in folder: String? = nil) {
        tabs.openNewSession(cwd: folder)
        store.refreshSoon()
    }

    /// ⇧⌘N — pick any folder on disk, no existing session needed.
    private func newSessionInChosenFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder for the new Claude session"
        panel.prompt = "Start Session"
        panel.directoryURL = URL(fileURLWithPath: tabs.currentFolder)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        newSession(in: url.path)
    }

    // MARK: - Menus

    @ViewBuilder
    private func sessionMenu(_ session: ClaudeSession) -> some View {
        if !accounts.tokenProfiles.isEmpty {
            Menu("Resume as") {
                ForEach(accounts.tokenProfiles, id: \.self) { profile in
                    Button(accounts.describe(profile: profile)) {
                        tabs.openSession(session, profile: profile)
                    }
                }
                // Without this there is no way back to the CLI's own login
                // once a saved account is the active one.
                Button(accounts.current.map { "\($0.email) (signed in)" } ?? "Signed-in account") {
                    tabs.openSession(session, signedIn: true)
                }
            }
            Divider()
        }
        Button("New Session in This Folder") { newSession(in: session.cwd) }
        Button("New Terminal in This Folder") { tabs.openNewTab(cwd: session.cwd) }
        Divider()
        Button("Watch as Flow Graph") { openGraph(session, alongside: false) }
        Button("Watch Alongside") { openGraph(session, alongside: true) }
        Divider()
        if Self.vsCodeURL != nil {
            Button("Open in VS Code") { openInVSCode(session.cwd) }
        }
        Button("Open in Terminal.app") { openInTerminalApp(session) }
        Button("Reveal Folder in Finder") {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.cwd)
        }
        Divider()
        if store.hiddenSessionIDs.contains(session.id) {
            Button("Unhide Session") { store.setHidden(session, false) }
        }
        Button("Delete Session…", role: .destructive) {
            requestDeletion([session], scope: "“\(session.title)”")
        }
    }

    @ViewBuilder
    private func projectMenu(_ project: ClaudeProject) -> some View {
        Button("New Session in This Project") { newSession(in: project.path) }
        Button("New Terminal in This Project") { tabs.openNewTab(cwd: project.path) }
        Divider()
        if Self.vsCodeURL != nil {
            Button("Open in VS Code") { openInVSCode(project.path) }
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(project.path, forType: .string)
        }
        Divider()
        Button("Delete All Sessions in \(project.name)…", role: .destructive) {
            requestDeletion(project.sessions, scope: "all \(project.sessions.count) sessions in \(project.name)")
        }
    }

    // MARK: - Deleting

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } })
    }

    private var deleteTitle: String {
        pendingDeletion.count == 1 ? "Delete this session?" : "Delete \(pendingDeletion.count) sessions?"
    }

    private var deleteMessage: String {
        let running = pendingDeletion.filter { terminalManager.isRunning($0.id) }.count
        var text = "Deleting \(deletionScope) moves the transcript to the Trash. "
            + "The chat disappears from ClaudeHub and can no longer be resumed."
        if running > 0 {
            text += running == 1
                ? "\n\nIts open tab will be closed and the running process ended."
                : "\n\n\(running) open tabs will be closed and their running processes ended."
        }
        return text
    }

    private func requestDeletion(_ sessions: [ClaudeSession], scope: String) {
        guard !sessions.isEmpty else { return }
        deletionScope = scope
        pendingDeletion = sessions
    }

    /// The ⌫ key on the focused sidebar row.
    private func requestDeletionOfSelection() {
        guard let id = selectedSessionID, let session = session(withID: id) else { return }
        requestDeletion([session], scope: "“\(session.title)”")
    }

    private func confirmDeletion() {
        let sessions = pendingDeletion
        pendingDeletion = []
        guard !sessions.isEmpty else { return }

        let ids = Set(sessions.map(\.id))
        tabs.closeTabs(forSessionIDs: ids)
        if let selected = selectedSessionID, ids.contains(selected) { selectedSessionID = nil }

        let failed = store.delete(sessions)
        guard !failed.isEmpty else { return }
        deleteError = failed.count == 1
            ? "“\(failed[0].title)” could not be moved to the Trash. Check the file's permissions."
            : "\(failed.count) sessions could not be moved to the Trash. Check the files' permissions."
    }

    /// nil when VS Code is not installed, which hides the menu item.
    private static let vsCodeURL: URL? =
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode")

    /// Opens the session as a zoetrope flow graph — in a fresh tab, or split
    /// into its own pane beside the conversation. A running session is
    /// followed at its live edge; a finished one replays from the start.
    private func openGraph(_ session: ClaudeSession, alongside: Bool) {
        let command: String
        if let zoe = TerminalManager.shared.zoePath {
            let running = tabs.tab(forSessionID: session.id)
                .map { terminalManager.isRunning($0.id) } ?? false
            command = "\(ClaudeSession.shellQuote(zoe)) \(ClaudeSession.shellQuote(session.fileURL.path))"
                + (running ? " --follow" : "")
        } else {
            command = """
                echo 'zoetrope is not bundled in this build. Install it with:'; \
                echo; echo '  brew install furkankly/tap/zoetrope'; \
                echo; echo 'https://github.com/furkankly/zoetrope'
                """
        }
        tabs.openGraph(command: command, session: session, alongside: alongside)
    }

    private func openInVSCode(_ path: String) {
        guard let application = Self.vsCodeURL else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)],
                                withApplicationAt: application,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// Opens the session in Terminal.app by handing it a `.command` file.
    ///
    /// This used to drive Terminal with AppleScript, which needs an automation
    /// grant macOS will not give an ad-hoc signed app without a prompt — and
    /// when it was refused, the menu item simply did nothing. A double-clickable
    /// script needs no permission at all: Terminal is what opens `.command`.
    private func openInTerminalApp(_ session: ClaudeSession) {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeHub")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("resume-\(session.id).command")
        let body = """
        #!/bin/zsh
        cd \(ClaudeSession.shellQuote(session.cwd)) || exit 1
        exec \(session.resumeCommand)
        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: script.path)
        } catch {
            deleteError = "Could not write the Terminal script: \(error.localizedDescription)"
            return
        }
        NSWorkspace.shared.open(script)
    }
}

// MARK: - Tab bar

/// The chips of one pane, grouped by the project they belong to.
///
/// Tabs from four projects in one row are four projects' worth of names with
/// nothing to tell them apart; the sidebar has folders for exactly this reason.
/// So the strip keeps each project's tabs together, in the order the projects
/// were first opened, under the folder's own name.
private struct TabStrip: View {
    let pane: Int
    @EnvironmentObject var tabs: TabsModel
    @ObservedObject var terminalManager = TerminalManager.shared
    @ObservedObject var accounts: AccountStore

    private var sections: [(folder: String, tabs: [TerminalTab])] {
        var order: [String] = []
        var byFolder: [String: [TerminalTab]] = [:]
        for tab in tabs.tabs(inPane: pane) {
            let name = TabsModel.folderName(tab.cwd)
            if byFolder[name] == nil { order.append(name) }
            byFolder[name, default: []].append(tab)
        }
        return order.map { ($0, byFolder[$0] ?? []) }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(sections.enumerated()), id: \.element.folder) { index, section in
                    // A quiet heading with a rule before it, the way the
                    // sidebar separates its folders. A capsule with an icon
                    // competes with the tabs for attention it has not earned.
                    if index > 0 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.12))
                            .frame(width: 1, height: 16)
                            .padding(.horizontal, 4)
                    }
                    Text(section.folder.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.trailing, 2)
                        .help(section.tabs.first?.cwd ?? section.folder)
                    ForEach(section.tabs) { tab in
                        TabChip(
                            tab: tab,
                            // Showing in this pane, and whether this pane is
                            // the one with the keyboard.
                            isActive: tabs.groupActive.indices.contains(pane)
                                && tabs.groupActive[pane] == tab.id,
                            hasFocus: tab.id == tabs.activeTabID,
                            activity: terminalManager.activity(of: tab.id),
                            accountLabel: accounts.effectiveLabel,
                            account: terminalManager.profile(of: tab),
                            accountIsLive: terminalManager.hasLaunched(tab.id),
                            activeAccount: accounts.activeProfile,
                            fellBackFrom: terminalManager.fallbackAccount(of: tab.id),
                            pending: terminalManager.pendingSwitch(of: tab.id),
                            limitNotice: terminalManager.limitNotices[tab.id],
                            activate: { tabs.show(tab.id) },
                            splitOff: { tabs.splitOff(tab.id) },
                            canSplit: tabs.canSplit,
                            restart: { terminalManager.relaunch(tab) },
                            close: { tabs.close(tab.id) }
                        )
                    }
                }
            }
            .padding(.vertical, 5)
        }
    }
}

private struct TabBarView: View {
    @EnvironmentObject var tabs: TabsModel
    @ObservedObject var terminalManager = TerminalManager.shared
    @ObservedObject var accounts: AccountStore

    var body: some View {
        // Just the tabs: the window controls live in the toolbar, the way
        // Safari keeps its buttons in the title bar rather than the tab row.
        HStack(spacing: 4) {
            TabStrip(pane: 0, accounts: accounts)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8)
        .background(.bar)
    }
}

/// Find in the tab you are looking at.
///
/// For a conversation that means the transcript, not the screen: the results
/// are messages, so a match from three hours ago is as findable as one from a
/// minute ago. A terminal tab has no transcript, so there it drives SwiftTerm's
/// own search over the scrollback.
private struct FindBar: View {
    @Binding var term: String
    let matches: (index: Int, total: Int)
    let results: [TranscriptMatch]
    @Binding var selected: Int?
    /// Why the selected result could not be found in the terminal, if it could not.
    let jumpNote: String?
    let searchesTranscript: Bool
    let search: () -> Void
    let step: (Bool) -> Void
    let close: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
            if !results.isEmpty {
                Divider()
                resultList
            }
        }
        .background(.bar)
        .onExitCommand(perform: close)
        .onChange(of: term) { _, _ in cache.map.removeAll() }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(searchesTranscript ? "Find in this conversation" : "Find in this terminal",
                      text: $term)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
                .onChange(of: term) { _, _ in search() }
                .onSubmit { step(true) }
                // ↑/↓ walk the results without leaving the field, the way
                // Spotlight and Xcode's find navigator do.
                .onKeyPress(.downArrow) { step(true); return .handled }
                .onKeyPress(.upArrow) { step(false); return .handled }
            if !term.isEmpty {
                Text(counter)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(matches.total == 0 ? Color.orange : Color.secondary)
            }
            Button { step(false) } label: { Image(systemName: "chevron.up") }
                .help("Previous match (⇧⌘G)")
            Button { step(true) } label: { Image(systemName: "chevron.down") }
                .help("Next match (⌘G)")
            Button(action: close) { Image(systemName: "xmark") }
                .help("Close (esc)")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear { focused = true }
    }

    private var counter: String {
        if matches.total == 0 { return "none" }
        return "\(matches.index) of \(matches.total)"
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(results) { match in
                        row(match)
                            .id(match.id)
                        Divider().opacity(0.4)
                    }
                }
            }
            .frame(maxHeight: 220)
            .onChange(of: selected) { _, index in
                guard let index, results.indices.contains(index) else { return }
                withAnimation { proxy.scrollTo(results[index].id, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func row(_ match: TranscriptMatch) -> some View {
        let isSelected = selected.map { results.indices.contains($0) && results[$0].id == match.id } ?? false
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(match.role)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(match.role == "You" ? Color.accentColor : Color.secondary)
                if let date = match.date {
                    Text(date, format: .dateTime.day().month().hour().minute())
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            // Selected, the row opens up to the whole message — the reading
            // copy when the terminal cannot show the original. Idle rows show
            // an excerpt around the hit: laying out a whole paragraph to draw
            // two lines of it, as a selectable text view, is what dragged.
            if isSelected {
                Text(highlighted(match.full, key: "\(match.id)-full"))
                    .font(.system(size: 11))
                    .lineLimit(14)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                Text(highlighted(excerpt(of: match.line), key: "\(match.id)"))
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if isSelected, let jumpNote {
                Text(jumpNote)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        .contentShape(Rectangle())
        .clickable()
        .onTapGesture {
            selected = results.firstIndex { $0.id == match.id }
        }
    }

    /// Built once per result and term, not on every layout pass.
    private final class HighlightCache { var map: [String: AttributedString] = [:] }
    @State private var cache = HighlightCache()

    private func highlighted(_ text: String, key: String) -> AttributedString {
        let cacheKey = "\(term)|\(key)"
        if let hit = cache.map[cacheKey] { return hit }
        let built = highlighted(text)
        cache.map[cacheKey] = built
        return built
    }

    /// Up to ~220 characters around the first hit, so a paragraph-long line
    /// shows the part that matched rather than its opening words.
    private func excerpt(of line: String) -> String {
        guard line.count > 220 else { return line }
        let hit = line.range(of: term, options: .caseInsensitive)?.lowerBound ?? line.startIndex
        let start = line.index(hit, offsetBy: -60, limitedBy: line.startIndex) ?? line.startIndex
        let end = line.index(start, offsetBy: 220, limitedBy: line.endIndex) ?? line.endIndex
        var piece = String(line[start..<end])
        if start > line.startIndex { piece = "…" + piece }
        if end < line.endIndex { piece += "…" }
        return piece
    }

    /// The term picked out of the line, so a result can be read at a glance
    /// instead of hunted through.
    private func highlighted(_ line: String) -> AttributedString {
        var text = AttributedString(line)
        var cursor = text.startIndex
        while let found = text[cursor...].range(of: term, options: .caseInsensitive) {
            text[found].foregroundColor = .primary
            text[found].backgroundColor = .yellow.opacity(0.28)
            cursor = found.upperBound
            if cursor >= text.endIndex { break }
        }
        return text
    }
}

/// The handle between two panes: VS Code's blue line, and the cursor that says
/// it can be dragged.
private struct PaneDivider: View {
    let width: CGFloat
    let onChange: (CGFloat) -> Void
    let onEnd: () -> Void

    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        Rectangle()
            .fill(hovering || dragging ? Color.accentColor : Color.primary.opacity(0.14))
            .frame(width: width)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside {
                    NSCursor.resizeLeftRight.set()
                } else if !dragging {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        dragging = true
                        // Held through the drag: the pointer leaves the handle
                        // as soon as it moves, and the cursor should not.
                        NSCursor.resizeLeftRight.set()
                        onChange(value.translation.width)
                    }
                    .onEnded { _ in
                        dragging = false
                        onEnd()
                        if !hovering { NSCursor.arrow.set() }
                    }
            )
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct TabChip: View {
    let tab: TerminalTab
    /// This is the tab its pane is showing.
    let isActive: Bool
    /// And that pane is the one you are typing in.
    let hasFocus: Bool
    let activity: TerminalActivity
    let accountLabel: String
    /// The saved account this tab runs as, nil for the signed-in one.
    let account: String?
    /// True once the tab is running, so the account is a fact, not a plan.
    let accountIsLive: Bool
    /// The account new sessions run as, so a tab can stay quiet when it matches
    /// and speak up when it does not.
    let activeAccount: String?
    /// Set when the tab wanted a saved account and had to start without it.
    let fellBackFrom: String?
    /// Set when the tab could not move to the new account yet, and why.
    let pending: (account: String, waitingOnPaste: Bool)?
    /// Set when this tab's account has run out, in the session's own words.
    let limitNotice: String?
    let activate: () -> Void
    let splitOff: () -> Void
    let canSplit: Bool
    let restart: () -> Void
    let close: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            // Everything but the close button is the drag handle: a chip that
            // is itself draggable spends the first click deciding whether you
            // meant to drag, and that click was meant for the ✕.
            content
                .contentShape(Rectangle())
                .draggable(tab.id)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    // The glyph stays small; what you have to hit does not.
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Four idle tabs are four crosses you are not going to press. The
            // space stays reserved either way, so nothing shifts under the
            // pointer as it arrives.
            .opacity(isActive || hovering ? 1 : 0)
            .allowsHitTesting(isActive || hovering)
            .help("Close tab (⌘W)")
        }
        .padding(.leading, 9)
        .padding(.trailing, 3)
        .padding(.vertical, 5)
        // Two levels, because a split window has two current tabs and only one
        // of them has the keyboard: the one you are typing in sits highest, the
        // other pane's current tab a step lower — which used to be drawn as an
        // idle tab, leaving that half of the window with nothing marked at all.
        // Neutral greys on purpose; the accent stays for selection and state.
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hasFocus ? Color.primary.opacity(0.12)
                      : isActive ? Color.primary.opacity(0.07)
                      : hovering ? Color.primary.opacity(0.05) : Color.clear)
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contentShape(Rectangle())
        .clickable()
        .help("\(tab.cwd)\n\(account.map { "Running as \($0)" } ?? "Running as the signed-in account")")
        .onTapGesture(perform: activate)
        .contextMenu {
            if canSplit {
                Button("Open Beside") { splitOff() }
            }
            Text(fellBackFrom.map { "Wanted \($0) — running on the signed-in account" }
                 ?? account.map { "Running as \($0)" }
                 ?? "Running as the signed-in account")
            Button(tab.sessionID == nil
                   ? "Restart Tab"
                   : "Restart as \(accountLabel)") { restart() }
            Button("Close Tab") { close() }
        }
    }

    private var content: some View {
        HStack(spacing: 5) {
            if activity == .dead {
                Button(action: restart) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Session ended — restart")
            } else if tab.isConversation {
                ActivityDot(activity: activity, size: 6)
                    .opacity(isActive || hasFocus || activity.pulses ? 1 : 0.55)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(tab.title)
                .font(.callout)
                .foregroundStyle(isActive || hasFocus ? .primary : .secondary)
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            if let limitNotice {
                Text(TerminalManager.resetTime(in: limitNotice).map { "limit · \($0)" } ?? "limit")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.red.opacity(0.22), in: Capsule())
                    .help("""
                        \(limitNotice)

                        This is the limit of \(account ?? "the signed-in account"), the \
                        account this tab started on. Another account may still have room \
                        — the account menu compares them.
                        """)
            } else if let pending {
                Text("→ \(TabsModel.shortLabel(pending.account))")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.20), in: Capsule())
                    .help(pending.waitingOnPaste
                          ? """
                            Waiting: the prompt holds content only this session \
                            has — an image from Claude in Chrome, or a paste from \
                            before ClaudeHub was watching this tab. Send or clear \
                            it and this tab moves to \(pending.account).
                            """
                          : """
                            Busy right now — this conversation moves to \
                            \(pending.account) and resumes as soon as it is done.
                            """)
            } else if let fellBackFrom {
                Text("signed in")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.25), in: Capsule())
                    .help("""
                        This tab runs on the signed-in account: the saved token \
                        for \(fellBackFrom) could not be read. Fix it in the \
                        account menu, then restart the tab.
                        """)
            } else if let account, account != activeAccount {
                // Only when it differs from the account you are working on:
                // the same label on every tab is decoration, and it is the odd
                // one out you need to be able to spot.
                Text(TabsModel.shortLabel(account))
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(accountIsLive ? 0.22 : 0.10), in: Capsule())
                    .help(accountIsLive
                          ? "Running as \(account) — not the account you are on now"
                          : "Will start as \(account)")
            }
        }
    }
}

/// The login URL a `claude auth` tab prints is hard-wrapped across three lines
/// and cmd-clicking it goes straight to the browser, so there is no way to just
/// copy it. This lifts it out whole.
private struct SignInLinkBar: View {
    let url: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            Text(url)
                .font(.system(size: 11).monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button(copied ? "Copied" : "Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            }
            if let destination = URL(string: url) {
                Button("Open") { NSWorkspace.shared.open(destination) }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.10))
    }
}

/// One repository in the Changes section: what is in it, and the ways out of
/// ClaudeHub to look at it properly.
private struct RepoRow: View {
    let repo: RepoStatus
    /// Seeing what is lying around and starting a session about it are the same
    /// thought, so they are one click apart.
    let newSession: () -> Void
    let openInEditor: () -> Void
    /// A file is worth opening on its own; the repository is the coarse answer.
    let openFile: (String) -> Void
    let showDiff: () -> Void
    /// The unified diff as git prints it, for when that is what you want.
    let showRawDiff: () -> Void
    let reveal: () -> Void
    let canOpenInEditor: Bool

    @State private var expanded = false

    private static let shown = 6

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(repo.files.prefix(Self.shown)) { file in
                    HStack(spacing: 6) {
                        Text(file.mark)
                            .font(.system(size: 10, weight: .semibold).monospaced())
                            .foregroundStyle(Self.color(for: file.mark))
                            .frame(width: 9, alignment: .leading)
                        Text(file.path)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .contentShape(Rectangle())
                    .clickable()
                    .onTapGesture { openFile(file.path) }
                    .help("\(file.path)\nClick to open this file in VS Code")
                }
                if repo.files.count > Self.shown {
                    Text("+ \(repo.files.count - Self.shown) more")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                // Three fit the sidebar; the Finder is a right-click away,
                // where a thing you reach for once a week belongs.
                HStack(spacing: 6) {
                    Button("Session", action: newSession)
                        .help("New Claude session in \(repo.name)")
                    Button("Diff", action: showDiff)
                        .help("The changes side by side, in a tab")
                    if canOpenInEditor {
                        Button("VS Code", action: openInEditor)
                            .help("Open \(repo.name) in VS Code")
                    }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .padding(.top, 3)
            }
            .padding(.top, 3)
            .padding(.bottom, 2)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(repo.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text("\(repo.pending)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.pending)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.pending.opacity(0.14), in: Capsule())
                }
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9, weight: .medium))
                    Text(repo.branch)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("·")
                    // An unpushed branch is the state you want to notice before
                    // you close the laptop, so it does not read as an aside.
                    Text(repo.syncLabel)
                        .foregroundStyle(repo.isUnpushed ? Color.pending : Color.secondary)
                    if let age = repo.age {
                        Text("·")
                        Text(age)
                            .help("The oldest of these changes was written \(age) ago")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
            .clickable()
            .help(repo.root)
            .contextMenu {
                Button("New Session in \(repo.name)", action: newSession)
                Button("Diff Side by Side", action: showDiff)
                Button("git diff in a Terminal", action: showRawDiff)
                if canOpenInEditor { Button("Open in VS Code", action: openInEditor) }
                Divider()
                Button("Reveal in Finder", action: reveal)
            }
        }
    }

    private static func color(for mark: String) -> Color {
        switch mark {
        case "A": return .green
        case "D": return .red
        case "?": return .secondary
        case "U": return .pending
        default: return .pending
        }
    }
}

private struct SessionRow: View {
    let session: ClaudeSession
    let activity: TerminalActivity
    let isHidden: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .lineLimit(1)
                Text(session.lastActivity, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isHidden {
                Image(systemName: "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if activity != .stopped {
                ActivityDot(activity: activity)
            }
        }
        .padding(.vertical, 1)
        .opacity(isHidden ? 0.55 : 1)
    }
}

private struct ProjectHeader<MenuContent: View>: View {
    let project: ClaudeProject
    /// The repositories this project folder covers — often several, since a
    /// folder you work in tends to hold a handful of them.
    let repos: [RepoStatus]
    let newSession: () -> Void
    @ViewBuilder let menu: () -> MenuContent
    @State private var isHovering = false

    private var pending: Int { repos.reduce(0) { $0 + $1.pending } }

    /// One repository speaks for itself; several are counted, because there is
    /// no single branch to name.
    private var label: String {
        repos.count == 1 ? repos[0].branch : "\(repos.count) repos"
    }

    /// ~/Documents/… instead of the full /Users/… mouthful.
    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private var tooltip: String {
        repos.map { repo in
            var state = repo.pending > 0 ? "\(repo.pending) uncommitted" : "clean"
            if let age = repo.age, repo.pending > 0 { state += ", oldest \(age)" }
            return "\(repo.name) · \(repo.branch) · \(state) · \(repo.syncLabel)"
        }.joined(separator: "\n")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            // The folder is the real thing: drag it into Finder, Terminal or a
            // file dialog and the project's path travels with it.
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
                .draggable(URL(fileURLWithPath: project.path))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(project.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("\(project.sessions.count)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text(Self.abbreviate(project.path))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if !repos.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9, weight: .medium))
                    Text(label)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if pending > 0 {
                        Text("\(pending)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Color.pending)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.pending.opacity(0.14), in: Capsule())
                    }
                }
                .foregroundStyle(.tertiary)
                .frame(maxWidth: 150, alignment: .trailing)
                .help(tooltip)
            }
            Button(action: newSession) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .clickable()
            .opacity(isHovering ? 1 : 0)
            // Keeps the button clear of the sidebar scroll bar.
            .padding(.trailing, 8)
            .help("New Claude session in \(project.name)")
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
        .contentShape(Rectangle())
        // Deferred: setting state straight from a hover callback mutates the
        // row while AppKit is still laying the table out.
        .onHover { hovering in
            DispatchQueue.main.async { isHovering = hovering }
        }
        .help(project.path)
        .contextMenu { menu() }
    }
}
