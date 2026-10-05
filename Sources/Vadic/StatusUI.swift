import AppKit

/// Menu-bar icon (idle / recording / processing / error) and the app menu.
@MainActor
final class StatusUI: NSObject {
    enum Display {
        case idle
        case recording(since: Date)
        case processing
        case downloading(Double)
        case error(String)
    }

    var onOpenConfig: () -> Void = {}
    var onReloadConfig: () -> Void = {}
    var onOpenHistory: () -> Void = {}
    var onPermissions: () -> Void = {}
    var onToggleLaunchAtLogin: () -> Void = {}

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let stateLine = NSMenuItem()
    private let lastLine = NSMenuItem()
    private let permissionsItem = NSMenuItem()
    private lazy var launchAtLoginItem = action("Launch at Login", #selector(toggleLaunchAtLogin))
    private var timer: Timer?
    /// When the overlay is on it shows the recording, and macOS adds its own mic indicator,
    /// so the menu-bar icon steps aside while recording. Without the overlay it shows a timer instead.
    var overlayShowsRecording = false
    private var errorReset: Timer?

    override init() {
        super.init()
        // Keeps the user's position when the item is hidden and shown again.
        item.autosaveName = "vadic"
        let menu = NSMenu()
        menu.delegate = self
        stateLine.isEnabled = false
        lastLine.isEnabled = false
        lastLine.isHidden = true
        menu.addItem(stateLine)
        menu.addItem(lastLine)
        menu.addItem(.separator())
        permissionsItem.target = self
        permissionsItem.action = #selector(permissions)
        menu.addItem(permissionsItem)
        menu.addItem(action("Open Config", #selector(openConfig)))
        menu.addItem(action("Reload Config", #selector(reloadConfig)))
        menu.addItem(action("Open History", #selector(openHistory)))
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Vadic", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        show(.idle)
    }

    func show(_ display: Display) {
        timer?.invalidate()
        timer = nil
        errorReset?.invalidate()
        errorReset = nil
        guard let button = item.button else { return }
        if case .recording = display {
            item.isVisible = !overlayShowsRecording
        } else {
            item.isVisible = true
        }
        button.title = ""

        switch display {
        case .idle:
            setIcon("mic", "Vadic: ready")
            stateLine.title = "Ready: hold the key and speak"
        case .recording(let since):
            setIcon("mic.fill", "Vadic: recording", color: .systemRed)
            stateLine.title = "Recording…"
            guard !overlayShowsRecording else { break }
            let tick: @MainActor () -> Void = { [weak button] in
                let s = Int(Date().timeIntervalSince(since))
                button?.title = String(format: " %d:%02d", s / 60, s % 60)
            }
            tick()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                MainActor.assumeIsolated { tick() }
            }
        case .processing:
            setIcon("waveform", "Vadic: transcribing")
            stateLine.title = "Transcribing…"
        case .downloading(let fraction):
            setIcon("arrow.down.circle", "Vadic: downloading model")
            stateLine.title = "Downloading speech model: \(Int(fraction * 100))%"
        case .error(let message):
            setIcon("exclamationmark.triangle.fill", "Vadic: \(message)", color: .systemOrange)
            stateLine.title = "Error: \(message.prefix(120))"
            errorReset = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.show(.idle) }
            }
        }
    }

    func setLast(_ text: String) {
        lastLine.title = "Last: \(text.prefix(80))"
        lastLine.toolTip = text
        lastLine.isHidden = false
    }

    /// Template icons are always repainted in the menu-bar colour, so a coloured state uses a palette symbol.
    private func setIcon(_ symbol: String, _ tooltip: String, color: NSColor? = nil) {
        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        if let color {
            image = image?.withSymbolConfiguration(.init(paletteColors: [color]))
            image?.isTemplate = false
        }
        item.button?.image = image
        item.button?.toolTip = tooltip
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    @objc private func openConfig() { onOpenConfig() }
    @objc private func reloadConfig() { onReloadConfig() }
    @objc private func openHistory() { onOpenHistory() }
    @objc private func permissions() { onPermissions() }
    @objc private func toggleLaunchAtLogin() { onToggleLaunchAtLogin() }
}

extension StatusUI: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        let missing = Permissions.missing
        permissionsItem.isHidden = missing.isEmpty
        permissionsItem.title = "Missing permission: " + missing.map(\.title).joined(separator: ", ") + "…"
        launchAtLoginItem.state = LaunchAtLogin.isEnabled ? .on : .off
    }
}
