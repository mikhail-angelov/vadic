import AppKit
import ApplicationServices
import VadicCore

/// Inserts text into whatever field has focus at the moment of insertion.
@MainActor
enum Inserter {
    /// Returns whether the text was put into a field (clipboard mode returns false).
    static func insert(_ text: String, mode: InsertMode, pressReturn: Bool) async throws -> Bool {
        switch mode {
        case .type:
            try await type(text)
        case .paste:
            try await paste(text)
        case .clipboard:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return false
        }
        if pressReturn {
            try await Task.sleep(for: .milliseconds(50))
            postKey(36)
        }
        return true
    }

    /// Types the text as Unicode keystrokes: layout-independent and leaves the clipboard alone.
    private static func type(_ text: String) async throws {
        try requireAccessibility()
        let source = CGEventSource(stateID: .privateState)
        for character in text {
            let units = Array(String(character).utf16)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                event?.flags = []
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event?.post(tap: .cghidEventTap)
            }
            // Some apps drop keystrokes that arrive in one burst.
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Clipboard + Cmd+V, then the previous clipboard contents are restored.
    private static func paste(_ text: String) async throws {
        try requireAccessibility()
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // Tells clipboard managers to skip this entry.
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.writeObjects([item])
        let ours = pasteboard.changeCount
        defer {
            // Restore on cancellation too, without clobbering something the user copied meanwhile.
            if pasteboard.changeCount == ours {
                pasteboard.clearContents()
                if !saved.isEmpty { pasteboard.writeObjects(saved) }
            }
        }
        postCommandV()
        try await Task.sleep(for: .milliseconds(400))
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private static func requireAccessibility() throws {
        guard AXIsProcessTrusted() else {
            throw EngineError("no Accessibility permission: keystrokes would not reach the app")
        }
    }

    private static func postCommandV() {
        postKey(9, flags: .maskCommand)
    }

    private static func postKey(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}
