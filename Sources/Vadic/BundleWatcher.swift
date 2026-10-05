import AppKit

/// Follows the app's own bundle on disk: when an upgrade (`brew upgrade`, a rebuild) replaces it, Vadic restarts
/// into the new version; when it is deleted (`brew uninstall`), Vadic quits.
@MainActor
final class BundleWatcher {
    private let bundleURL = Bundle.main.bundleURL
    private var infoPlist: URL { bundleURL.appending(path: "Contents/Info.plist") }
    private var source: DispatchSourceFileSystemObject?

    func start() {
        let descriptor = open(infoPlist.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.delete, .rename, .revoke], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.bundleChanged() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    private func bundleChanged() {
        source?.cancel()
        source = nil
        Task { @MainActor in
            // An upgrade removes the old bundle first and moves the new one in a moment later.
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(1))
                if FileManager.default.fileExists(atPath: infoPlist.path) {
                    try? await Task.sleep(for: .seconds(1)) // let the move finish
                    relaunch()
                    return
                }
            }
            Self.quit()
        }
    }

    /// The new copy starts only after this process has exited, so the two never share whisper-server.
    private func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", bundleURL.path]
        do {
            try process.run()
        } catch {
            return // keep running the old version rather than quitting with nothing to replace it
        }
        Self.quit()
    }

    /// Leaves the current main-actor job first: terminate waits on main-actor work that needs the main queue.
    private static func quit() {
        RunLoop.main.perform { MainActor.assumeIsolated { NSApp.terminate(nil) } }
    }
}
