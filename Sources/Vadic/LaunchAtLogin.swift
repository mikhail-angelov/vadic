import ServiceManagement

/// Login item through SMAppService: macOS keeps the state (System Settings → General → Login Items),
/// so there is nothing to store in the config.
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// On by default: registers once on the first launch. After that the menu and System Settings decide,
    /// so switching it off is never undone on the next launch.
    static func enableOnFirstLaunch() throws {
        let key = "launchAtLoginDefaultApplied"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if SMAppService.mainApp.status == .notRegistered { try SMAppService.mainApp.register() }
    }

    static func toggle() throws {
        let service = SMAppService.mainApp
        if service.status == .enabled {
            try service.unregister()
        } else {
            try service.register()
            // The user switched it off in System Settings before; only they can switch it back on there.
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        }
    }
}
