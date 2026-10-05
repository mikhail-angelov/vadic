import AppKit
import SwiftUI

/// Floating pill at the bottom of the screen: live level bars and timer while recording, a spinner while
/// recognizing. It never takes focus, so typed text still lands in the field the user was in.
@MainActor
final class Overlay {
    private let model = OverlayModel()
    private let panel: NSPanel
    private var hideTimer: Timer?
    /// A fade-out finishing after a new show() must not hide the panel again.
    private var wantsVisible = false

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
    }

    func show(_ display: StatusUI.Display) {
        hideTimer?.invalidate()
        hideTimer = nil
        switch display {
        case .idle:
            hide()
            return
        case .recording(let since):
            model.levels = Array(repeating: 0, count: OverlayModel.barCount)
            model.phase = .recording(since: since)
        case .processing:
            model.phase = .processing
        case .downloading(let fraction):
            model.phase = .downloading(fraction)
        case .error(let message):
            model.phase = .error(message)
            hideTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
        wantsVisible = true
        if !panel.isVisible {
            position()
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
    }

    /// `level` is 0…1.
    func push(level: Float) {
        guard case .recording = model.phase else { return }
        model.levels.removeFirst()
        model.levels.append(level)
    }

    private func hide() {
        wantsVisible = false
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 }) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.wantsVisible else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    /// Bottom centre of the screen the user is working on, above the Dock.
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 24))
    }
}

@MainActor
@Observable
final class OverlayModel {
    enum Phase {
        case recording(since: Date)
        case processing
        case downloading(Double)
        case error(String)
    }

    static let barCount = 24
    var phase: Phase = .processing
    var levels = Array(repeating: Float(0), count: barCount)
}

private struct OverlayView: View {
    let model: OverlayModel

    var body: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .recording(let since):
                Circle().fill(.red).frame(width: 8, height: 8)
                LevelBars(levels: model.levels)
                TimelineView(.periodic(from: since, by: 0.5)) { context in
                    let s = max(0, Int(context.date.timeIntervalSince(since)))
                    Text(String(format: "%d:%02d", s / 60, s % 60))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            case .processing:
                ProgressView().controlSize(.small)
                Text("Transcribing…").font(.system(size: 12, weight: .medium))
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(width: 120)
                Text("Downloading model… \(Int(fraction * 100))%")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.system(size: 12)).lineLimit(1).truncationMode(.tail).frame(maxWidth: 280)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .fixedSize()
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LevelBars: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(.white.opacity(0.85))
                    .frame(width: 3, height: 3 + CGFloat(levels[i]) * 18)
            }
        }
        .frame(height: 22)
        .animation(.easeOut(duration: 0.08), value: levels)
    }
}
