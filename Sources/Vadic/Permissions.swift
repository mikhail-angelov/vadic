import AppKit
import AVFoundation
import ApplicationServices

@MainActor
enum Permissions {
    enum Kind: CaseIterable {
        case microphone, accessibility

        var title: String {
            switch self {
            case .microphone: "Microphone"
            case .accessibility: "Accessibility"
            }
        }

        var why: String {
            switch self {
            case .microphone: "needed to record your voice"
            case .accessibility: "needed to type the text into other apps"
            }
        }

        var settingsURL: URL {
            let pane = switch self {
            case .microphone: "Privacy_Microphone"
            case .accessibility: "Privacy_Accessibility"
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        }

        var isGranted: Bool {
            switch self {
            case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            case .accessibility: AXIsProcessTrusted()
            }
        }
    }

    static var missing: [Kind] { Kind.allCases.filter { !$0.isGranted } }

    /// Triggers the system prompts for whatever has not been decided yet.
    static func request() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        if !AXIsProcessTrusted() {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    /// Explains what is missing and offers to open the matching settings pane.
    static func explainMissing() {
        let missing = missing
        guard let first = missing.first else { return }
        let alert = NSAlert()
        alert.messageText = "Vadic needs permissions"
        alert.informativeText = missing.map { "• \($0.title): \($0.why)" }.joined(separator: "\n")
            + "\n\nIf Vadic is already enabled in the list but this keeps appearing, remove it with the − button, "
            + "add it again and restart Vadic."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(first.settingsURL)
        }
    }
}
