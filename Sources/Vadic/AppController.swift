import AppKit
import VadicCore

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let paths = Paths.standard
    private let recorder = Recorder()
    private let muter = OutputMuter()
    private let bundleWatcher = BundleWatcher()
    private let ui = StatusUI()
    private var overlay: Overlay?
    private var machine = DictationStateMachine()
    private var config: Config!
    private lazy var engine = WhisperEngine(config: config.engine, language: config.language,
                                            prompt: config.prompt, serverLog: paths.serverLog)
    private var hotkey: Hotkey?
    private var sigterm: DispatchSourceSignal?
    private var recordingLimit: Timer?
    private var reloadPending = false
    private var serverStartup: Task<Void, Never>?
    private var processing: Task<Void, Never>?
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `kill`/logout send SIGTERM, which skips applicationShouldTerminate and would orphan whisper-server.
        signal(SIGTERM, SIG_IGN)
        sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        // Leave the GCD block first: terminate waits on main-actor work that needs the main queue.
        sigterm?.setEventHandler { RunLoop.main.perform { MainActor.assumeIsolated { NSApp.terminate(nil) } } }
        sigterm?.resume()

        ui.onOpenConfig = { [unowned self] in NSWorkspace.shared.open(paths.config) }
        ui.onReloadConfig = { [unowned self] in requestReload() }
        ui.onOpenHistory = { [unowned self] in
            try? FileManager.default.createDirectory(at: paths.history, withIntermediateDirectories: true)
            NSWorkspace.shared.open(paths.history)
        }
        ui.onPermissions = { Permissions.explainMissing() }
        ui.onToggleLaunchAtLogin = { [unowned self] in
            do { try LaunchAtLogin.toggle() } catch { display(.error("launch at login: \(error.localizedDescription)")) }
        }

        reload()
        bundleWatcher.start()
        do { try LaunchAtLogin.enableOnFirstLaunch() } catch { ui.show(.error("launch at login: \(error.localizedDescription)")) }
        let store = HistoryStore(root: paths.history)
        let config = config!
        Task.detached { store.prune(audioDays: config.audioRetentionDays, historyDays: config.historyRetentionDays) }
        Task {
            await Permissions.request()
            Permissions.explainMissing()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        reloadPending = false
        serverStartup?.cancel()
        processing?.cancel()
        hotkey?.stop()
        stopRecordingLimit()
        recorder.cancel()
        _ = machine.cancelRecording()
        muter.restore()
        let engine = engine
        let serverStartup = serverStartup
        let processing = processing
        Task {
            await engine.shutdown()
            await serverStartup?.value
            await processing?.value
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func reload() {
        guard !isTerminating else { return }
        let defaults = Config.defaults(paths: paths)
        var loadError: String?
        do {
            config = try ConfigStore.load(from: paths.config, defaults: defaults)
        } catch {
            config = defaults
            loadError = "config could not be read, using defaults: \(error.localizedDescription)"
        }

        let config = config!
        serverStartup?.cancel()
        let models = paths.models
        serverStartup = Task { [weak self, engine] in
            await engine.reconfigure(config: config.engine, language: config.language, prompt: config.prompt)
            do {
                // First launch: fetch the model and VAD instead of shipping 575 MB inside the bundle.
                for model in ModelDownloader.missing(for: config.engine, in: models) {
                    self?.showDownload(0)
                    try await ModelDownloader.download(model, to: models) { fraction in
                        Task { @MainActor in self?.showDownload(fraction) }
                    }
                }
                if self?.machine.state == .idle { self?.display(.idle) }
                try await engine.ensureServer()
            } catch {
                guard !Task.isCancelled, let self, !self.isTerminating else { return }
                self.ui.show(.error(error.localizedDescription))
            }
        }

        if !config.overlay { overlay?.show(.idle) }
        overlay = config.overlay ? (overlay ?? Overlay()) : nil
        ui.overlayShowsRecording = config.overlay
        recorder.onLevel = { [weak self] in self?.overlay?.push(level: $0) }

        hotkey?.stop()
        let hotkey = Hotkey(key: config.hotkey)
        hotkey.onPress = { [unowned self] in startRecording() }
        hotkey.onRelease = { [unowned self] in finishRecording() }
        hotkey.onInterrupt = { [unowned self] in cancelRecording() }
        hotkey.start()
        self.hotkey = hotkey

        if let loadError { ui.show(.error(loadError)) }
    }

    /// Swapping the hotkey or engine mid-dictation would lose the key release or kill the running request,
    /// so a reload waits until the app is idle.
    private func requestReload() {
        guard !isTerminating else { return }
        if machine.state == .idle {
            reload()
        } else {
            reloadPending = true
        }
    }

    /// Every way back to idle goes through here, so a deferred reload is never forgotten.
    private func returnToIdle(showing state: StatusUI.Display = .idle) {
        display(state)
        guard reloadPending else { return }
        reloadPending = false
        reload()
    }

    private func stopRecordingLimit() {
        recordingLimit?.invalidate()
        recordingLimit = nil
    }

    /// Download progress never covers a dictation that started meanwhile.
    private func showDownload(_ fraction: Double) {
        if machine.state == .idle { display(.downloading(fraction)) }
    }

    private func display(_ state: StatusUI.Display) {
        ui.show(state)
        overlay?.show(state)
    }

    private func startRecording() {
        guard !isTerminating else { return }
        let now = Date()
        guard machine.startRecording(at: now) else { return }
        if config.muteWhileRecording { muter.mute() }
        do {
            try recorder.start(to: paths.recordings.appending(path: "\(UUID().uuidString).wav"))
            recordingLimit = Timer.scheduledTimer(withTimeInterval: config.maxRecordingMinutes * 60, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishRecording() }
            }
            display(.recording(since: now))
        } catch {
            _ = machine.cancelRecording()
            muter.restore()
            returnToIdle(showing: .error(error.localizedDescription))
        }
    }

    private func cancelRecording() {
        guard machine.cancelRecording() else { return }
        stopRecordingLimit()
        recorder.cancel()
        muter.restore()
        returnToIdle()
    }

    private func finishRecording() {
        guard machine.stopRecording() else { return }
        stopRecordingLimit()
        let stopped = recorder.stop()
        muter.restore()
        guard let recording = stopped else {
            machine.finishProcessing()
            returnToIdle()
            return
        }
        let verdict = AudioGate.evaluate(durationSec: recording.durationSec, peakDb: recording.peakDb,
                                         minDurationSec: config.minDurationSec, thresholdDb: config.silenceThresholdDb)
        guard verdict == .accept else {
            // Accidental tap or silence: no text, no history, no leftover file.
            try? FileManager.default.removeItem(at: recording.url)
            machine.finishProcessing()
            returnToIdle()
            return
        }

        display(.processing)
        let config = config!
        let engine = engine
        let serverStartup = serverStartup
        processing = Task {
            await serverStartup?.value
            let outcome = await process(recording, config: config, engine: engine)
            machine.finishProcessing()
            guard !isTerminating else { return }
            returnToIdle(showing: outcome)
        }
    }

    private func process(_ recording: Recording, config: Config, engine: WhisperEngine) async -> StatusUI.Display {
        var entry = HistoryEntry(date: Date(), durationSec: recording.durationSec, text: nil, engine: nil,
                                 model: config.engine.modelPath, insertMode: config.insertMode, inserted: false,
                                 frontApp: nil, error: nil)
        var display = StatusUI.Display.idle
        do {
            // A failed normalization still leaves a usable recording, so it never fails the dictation.
            try? await Task.detached { try AudioNormalizer.normalize(recording.url) }.value
            let result = try await engine.transcribe(recording.url)
            try Task.checkCancellation()
            entry.engine = result.engine
            let text = Replacer.apply(config.replacements, to: result.text)
            guard !text.isEmpty else { throw EngineError("nothing recognized") }
            entry.text = text
            ui.setLast(text)
            // Insert wherever focus is now, even if the user switched apps while speaking.
            entry.frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            do {
                // A sent message (Return) needs no separator before the next dictation.
                let typed = config.appendSpace && !config.pressReturn ? text + " " : text
                entry.inserted = try await Inserter.insert(typed, mode: config.insertMode, pressReturn: config.pressReturn)
            } catch {
                if isTerminating { throw error }
                // Never lose dictated text: leave it on the clipboard for a manual paste.
                _ = try? await Inserter.insert(text, mode: .clipboard, pressReturn: false)
                throw EngineError("\(error.localizedDescription). The text is on the clipboard")
            }
            if let reason = result.fallbackReason {
                display = .error("server failed, used whisper-cli: \(reason)")
            }
        } catch {
            entry.error = error.localizedDescription
            display = .error(error.localizedDescription)
        }
        do {
            let store = HistoryStore(root: paths.history)
            try await Task.detached {
                try store.save(entry, audio: recording.url, keepAudio: config.keepAudio)
                store.prune(audioDays: config.audioRetentionDays, historyDays: config.historyRetentionDays)
            }.value
        } catch {
            display = .error("history not saved: \(error.localizedDescription)")
        }
        return display
    }
}
