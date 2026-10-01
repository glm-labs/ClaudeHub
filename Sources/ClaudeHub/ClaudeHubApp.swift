import SwiftUI
import UserNotifications

extension Notification.Name {
    /// Menu → "New Session in Folder…": the folder picker lives in the window
    /// that has the tabs, so the command just asks for it.
    static let newClaudeSessionInFolder = Notification.Name("ClaudeHub.newSessionInFolder")
    /// Menu → "Delete Session": acted on by the window holding the selection.
    static let deleteSelectedSession = Notification.Name("ClaudeHub.deleteSelectedSession")
    static let showMCPManager = Notification.Name("ClaudeHub.showMCPManager")
    static let splitActiveTab = Notification.Name("ClaudeHub.splitActiveTab")
    /// ⌘F, ⌘G, ⇧⌘G — find in the tab you are looking at.
    static let findInTab = Notification.Name("ClaudeHub.findInTab")
    static let findNextMatch = Notification.Name("ClaudeHub.findNextMatch")
    static let findPreviousMatch = Notification.Name("ClaudeHub.findPreviousMatch")
    /// The account sessions run as changed, so the limits belong to someone else now.
    static let activeAccountChanged = Notification.Name("ClaudeHub.activeAccountChanged")
    /// A notification banner was clicked: bring that session forward.
    static let focusTab = Notification.Name("ClaudeHub.focusTab")
    static let toggleSidebar = Notification.Name("ClaudeHub.toggleSidebar")
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Asked for once, and only used for "your session finished while you
        // were elsewhere" — declined is a perfectly good answer, the dot in the
        // sidebar and the count on the icon say the same thing.
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .badge]) { _, _ in }
    }

    /// Clicking the banner opens the session it came from.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completion: @escaping () -> Void) {
        if let tab = response.notification.request.content.userInfo["tab"] as? String {
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .focusTab, object: tab)
        }
        completion()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A restart mid-flight may be borrowing the clipboard to hand a session
        // back its image; quitting is the one thing that would leave it there.
        TerminalManager.shared.releaseBorrowedClipboard()
        let running = TerminalManager.shared.runningCount
        guard running > 0 else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = running == 1
            ? "1 terminal is still running"
            : "\(running) terminals are still running"
        alert.informativeText = "Quitting ClaudeHub ends these processes. Claude sessions can be resumed later from the sidebar."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

@main
struct ClaudeHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = SessionStore()
    @StateObject private var tabs = TabsModel()
    @StateObject private var accounts = AccountStore()
    @StateObject private var usage = UsageStore()
    @StateObject private var git = GitStore()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(tabs)
                .environmentObject(accounts)
                .environmentObject(usage)
                .environmentObject(git)
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { UpdateChecker.shared.check() }
            }
            CommandGroup(replacing: .newItem) {
                NewItemCommands(store: store, tabs: tabs)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Find…") {
                    NotificationCenter.default.post(name: .findInTab, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
                Button("Find Next") {
                    NotificationCenter.default.post(name: .findNextMatch, object: nil)
                }
                .keyboardShortcut("g", modifiers: .command)
                Button("Find Previous") {
                    NotificationCenter.default.post(name: .findPreviousMatch, object: nil)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                Divider()
                Button("MCP Servers…") {
                    NotificationCenter.default.post(name: .showMCPManager, object: nil)
                }
                Divider()
                Button("Delete Session…") {
                    NotificationCenter.default.post(name: .deleteSelectedSession, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button("Show/Hide Sidebar") {
                    NotificationCenter.default.post(name: .toggleSidebar, object: nil)
                }
                .keyboardShortcut("b", modifiers: .command)
                Button("Open Tab Beside") {
                    NotificationCenter.default.post(name: .splitActiveTab, object: nil)
                }
                .keyboardShortcut("\\", modifiers: .command)
            }
            // Take over ⌘W: close the active tab, not the window
            CommandGroup(replacing: .saveItem) {
                Button("Close Tab") {
                    if let id = tabs.activeTabID { tabs.close(id) }
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(tabs.activeTabID == nil)
                Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("Bigger Text") { TerminalManager.shared.changeFontSize(by: 1) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Smaller Text") { TerminalManager.shared.changeFontSize(by: -1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { TerminalManager.shared.resetFontSize() }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
            }
            CommandMenu("Claude") {
                Button("Usage & Limits") { ClaudeCommands.send("/usage", tabs: tabs) }
                    .keyboardShortcut("u", modifiers: .command)
                    .disabled(!ClaudeCommands.canSend(tabs))
                Button("Refresh Limits") { usage.refresh() }
                Button("Account & Status") { ClaudeCommands.send("/status", tabs: tabs) }
                    .disabled(!ClaudeCommands.canSend(tabs))
                Button("Context Left") { ClaudeCommands.send("/context", tabs: tabs) }
                    .disabled(!ClaudeCommands.canSend(tabs))
                Button("Model…") { ClaudeCommands.send("/model", tabs: tabs) }
                    .disabled(!ClaudeCommands.canSend(tabs))

                Divider()

                Button("Switch Account…") {
                    ClaudeCommands.logIn(as: nil, accounts: accounts, tabs: tabs)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                AccountItems(accounts: accounts, tabs: tabs, usage: usage)
            }
            CommandMenu("Tabs") {
                ForEach(1..<10, id: \.self) { number in
                    Button("Tab \(number)") { tabs.activate(index: number - 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                        .disabled(tabs.tabs.count < number)
                }
            }
        }
    }
}

/// The File menu. A view (rather than inline buttons) so it can reach
/// `openWindow` for "New Window", which `.newItem` no longer provides.
///
/// Plain references, not @ObservedObject: these commands only call methods,
/// they show no state, so there is nothing to observe.
private struct NewItemCommands: View {
    let store: SessionStore
    let tabs: TabsModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Claude Session") {
            tabs.openNewSession()
            store.refreshSoon()
        }
        .keyboardShortcut("n", modifiers: .command)

        Button("New Claude Session in Folder…") {
            NotificationCenter.default.post(name: .newClaudeSessionInFolder, object: nil)
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])

        Button("New Terminal Tab") { tabs.openNewTab() }
            .keyboardShortcut("t", modifiers: .command)

        Divider()

        Button("New Window") { openWindow(id: "main") }
            .keyboardShortcut("n", modifiers: [.command, .option])

        Button("Refresh Sessions") { store.refresh() }
            .keyboardShortcut("r", modifiers: .command)
    }
}
