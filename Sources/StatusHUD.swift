import AppKit
import SwiftUI

final class StatusHUDState: ObservableObject {
    @Published var text: String = ""
    @Published var systemImage: String = "cpu"
}

private struct StatusHUDView: View {
    @ObservedObject var state: StatusHUDState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
            Text(state.text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .fixedSize()
        // Generous transparent margin so the soft shadow has room to render and
        // isn't clipped into a hard rectangle by the (smaller) window frame.
        .padding(20)
    }
}

/// A small, clean capsule that appears just below the menu bar for a couple of
/// seconds when transcription mode changes (e.g. "Offline · on-device"), then
/// fades out. Borderless floating panel, doesn't steal focus, shows on all spaces.
final class StatusHUD {
    private var panel: NSPanel?
    private var hosting: NSHostingView<StatusHUDView>?
    private var dismissWork: DispatchWorkItem?
    private let state = StatusHUDState()

    func show(_ text: String, systemImage: String, duration: TimeInterval? = 2.2) {
        if Thread.isMainThread {
            present(text, systemImage: systemImage, duration: duration)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.present(text, systemImage: systemImage, duration: duration)
            }
        }
    }

    /// Show a persistent status that stays up until you call `hide()` or show
    /// something else. Use it to narrate ongoing work (downloading, loading…) so
    /// the user always knows what's happening instead of seeing a bare spinner.
    func showProgress(_ text: String, systemImage: String) {
        show(text, systemImage: systemImage, duration: nil)
    }

    /// Fade out whatever is currently showing.
    func hide() {
        if Thread.isMainThread {
            dismissWork?.cancel()
            fadeOut()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.dismissWork?.cancel()
                self?.fadeOut()
            }
        }
    }

    private func present(_ text: String, systemImage: String, duration: TimeInterval?) {
        state.text = text
        state.systemImage = systemImage

        let panel = ensurePanel()
        positionAndSize(panel)

        dismissWork?.cancel()
        if panel.alphaValue < 1.0 || !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.orderFrontRegardless()
        }

        guard let duration else { return } // sticky: keep showing until updated/hidden
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.level = .screenSaver
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        let host = NSHostingView(rootView: StatusHUDView(state: state))
        p.contentView = host
        hosting = host
        panel = p
        return p
    }

    private func positionAndSize(_ panel: NSPanel) {
        guard let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let width = max(size.width, 120)
        let height = max(size.height, 36)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let x = screen.frame.midX - width / 2
        // Panel top sits just under the menu bar; the capsule itself lands ~14px
        // below it thanks to the transparent shadow padding baked into the view.
        let y = screen.visibleFrame.maxY - height + 6
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    private func fadeOut() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
        })
    }
}
