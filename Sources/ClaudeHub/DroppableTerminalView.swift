import AppKit
import SwiftTerm

/// A terminal you can drop files onto, which every other terminal on this
/// machine lets you do: the path is typed in at the cursor, escaped, as if you
/// had written it out.
///
/// SwiftTerm registers no dragged types at all, so without this the view simply
/// refuses the drop — no path, no feedback, nothing. Claude Code takes a path
/// for an image or a file to read exactly as it takes typed text, so this is
/// the whole of what is needed.
///
/// It also watches what is pasted into it: Claude Code shows a paste as
/// `[Pasted text #12 +36 lines]` and keeps the content to itself, so this is
/// the only place the content can be kept — see `PasteMemory`.
final class DroppableTerminalView: LocalProcessTerminalView {
    /// Which tab this terminal is, so what is pasted into it is remembered
    /// against the right prompt.
    var tabID: String?
    /// Whether ⌃V means "take this image" here — it does to Claude Code, and
    /// to a shell it means quoted-insert, which is not something to send one
    /// on a guess.
    var takesImagePastes = false
    /// Runs Cursor's agent: Shift+Enter, a tap in the input and the colours
    /// all work a little differently there — see `TerminalManager`.
    var isCursorAgent = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes(Self.dragTypes)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(Self.dragTypes)
    }

    /// Files, file promises (Mail, Photos, Safari — the file only exists once
    /// a receiver asks for it), and bare image data.
    private static let dragTypes: [NSPasteboard.PasteboardType] = {
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]
        for raw in NSFilePromiseReceiver.readableDraggedTypes {
            types.append(NSPasteboard.PasteboardType(raw))
        }
        return types
    }()

    // MARK: Selecting

    /// In a Cursor chat, selecting text copies it, the way the standalone
    /// CursorHub did. A tap that only moves the caret selects nothing, so the
    /// clipboard stays as it was.
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard isCursorAgent, let text = getSelection(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Pastes

    override func paste(_ sender: Any) {
        guard let tabID else { return super.paste(sender) }

        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
            PasteMemory.shared.note(.text(text), pastedInto: self, tab: tabID)
            return super.paste(sender)
        }

        // An image on the clipboard. ⌘V in a terminal pastes nothing at all —
        // there is no text to send — and Claude Code takes images on ⌃V, which
        // it answers by reading the clipboard itself. So ⌘V is passed on as
        // that, and the image is kept on the way through.
        guard takesImagePastes,
              let file = PasteMemory.shared.keepClipboardImage() else { return super.paste(sender) }
        PasteMemory.shared.note(.image(file), pastedInto: self, tab: tabID)
        send(txt: "\u{16}")
    }

    // MARK: Drops

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.droppable(sender) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard

        // Mail and friends drag a promise, not a file: receive it into a
        // scratch folder and type the path once it lands.
        if let promises = board.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !promises.isEmpty {
            let folder = Self.dropsFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for promise in promises {
                promise.receivePromisedFiles(atDestination: folder, options: [:],
                                             operationQueue: Self.promiseQueue) { [weak self] url, error in
                    guard error == nil else { return }
                    DispatchQueue.main.async { self?.type(path: url.path) }
                }
            }
            return true
        }

        let paths = Self.paths(in: sender)
        if !paths.isEmpty {
            paths.forEach { type(path: $0) }
            return true
        }

        // A bare image, dragged out of a browser or a chat: saved as a file,
        // because a path is what a terminal can take.
        if let data = board.data(forType: .png) ?? board.data(forType: .tiff),
           let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
            let file = Self.dropsFolder.appendingPathComponent("\(UUID().uuidString).png")
            guard (try? png.write(to: file)) != nil else { return false }
            type(path: file.path)
            return true
        }
        return false
    }

    /// The path at the cursor, escaped, trailed by a space — and the keyboard
    /// back in the terminal, so the next thing typed goes with it.
    private func type(path: String) {
        send(txt: Self.escaped(path) + " ")
        window?.makeFirstResponder(self)
    }

    private static func droppable(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        let types = board.types ?? []
        if types.contains(.fileURL) || types.contains(.png) || types.contains(.tiff) { return true }
        return board.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
    }

    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Dropped content that only existed as data or a promise. Drops older
    /// than a week are cleaned out — those paths have long since been sent.
    private static let dropsFolder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = caches.appendingPathComponent("ClaudeHub/drops", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let fm = FileManager.default
        for item in (try? fm.contentsOfDirectory(at: folder,
                                                 includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? fm.removeItem(at: item) }
        }
        return folder
    }()

    private static func paths(in sender: NSDraggingInfo) -> [String] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                        options: options) as? [URL]
        return (urls ?? []).map(\.path)
    }

    /// Backslash-escaped the way a terminal writes a dropped path, so it can be
    /// used as-is whether the line is read by a shell or by Claude.
    private static func escaped(_ path: String) -> String {
        let specials = Set(" \t\n\"'\\$`&|;<>()*?[]{}!#")
        var out = ""
        for character in path {
            if specials.contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }
}
