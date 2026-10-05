import AppKit
import VadicCore

/// Push-to-talk on a single modifier. Any other key pressed while holding means the modifier
/// was used for a shortcut, so the recording is interrupted instead of transcribed.
@MainActor
final class Hotkey {
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    var onInterrupt: () -> Void = {}

    private let key: HotkeyKey
    private var monitors: [Any] = []
    private var isDown = false

    init(key: HotkeyKey) {
        self.key = key
    }

    func start() {
        stop()
        let flags: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.handleFlags(event) }
        }
        let keyDown: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.handleKeyDown() }
        }
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags),
            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { flags($0); return $0 },
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keyDown),
        ].compactMap { $0 }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        isDown = false
    }

    private func handleFlags(_ event: NSEvent) {
        guard event.keyCode == key.keyCode else { return }
        // Device-dependent bits tell the right modifier from the left one.
        let pressed = event.modifierFlags.rawValue & key.deviceMask != 0
        if pressed, !isDown {
            isDown = true
            onPress()
        } else if !pressed, isDown {
            isDown = false
            onRelease()
        }
    }

    private func handleKeyDown() {
        if isDown { onInterrupt() }
    }
}

private extension HotkeyKey {
    var keyCode: UInt16 {
        switch self {
        case .rightOption: 61
        case .rightCommand: 54
        case .rightControl: 62
        case .fn: 63
        }
    }

    var deviceMask: UInt {
        switch self {
        case .rightOption: 0x40 // NX_DEVICERALTKEYMASK
        case .rightCommand: 0x10 // NX_DEVICERCMDKEYMASK
        case .rightControl: 0x2000 // NX_DEVICERCTLKEYMASK
        case .fn: NSEvent.ModifierFlags.function.rawValue
        }
    }
}
