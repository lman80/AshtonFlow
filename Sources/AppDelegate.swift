import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    var setupWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var transcribeAudioWindow: NSWindow?
    private var setupWindowObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SuperFeedback: in-app "Send Feedback…" → opens a GitHub Issue (with a
        // screenshot) in this app's own repo, via the shared backend. No token or
        // setup ships in the app; the backend holds the GitHub key.
        SuperFeedback.configure(
            backendURL: URL(string: "https://superfeedback.ashton-mcp-worker.workers.dev")!,
            repo: "lman80/AshtonFlow",
            app: AppName.displayName
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowSetup),
            name: .showSetup,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowSettings),
            name: .showSettings,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowTranscribeAudio),
            name: .showTranscribeAudio,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowSendFeedback),
            name: .showSendFeedback,
            object: nil
        )

        appState.startNetworkMonitoring()

        if !appState.hasCompletedSetup {
            showSetupWindow()
        } else {
            appState.startHotkeyMonitoring()
            appState.startAccessibilityPolling()
            // Keep the on-device model warm so offline (incl. auto-fallback) is
            // instant. Preload when offline is on, or when auto-fallback is on and
            // the model is already downloaded (so we don't trigger a surprise
            // download for users who never go offline).
            if appState.offlineModeEnabled
                || (appState.autoOfflineFallbackEnabled
                    && LocalTranscriptionService.hasDownloadedModel(named: appState.offlineModelName)) {
                appState.prepareLocalModel()
            }
            Task { @MainActor in
                UpdateManager.shared.startPeriodicChecks()
            }

            if !AXIsProcessTrusted() {
                appState.showAccessibilityAlert()
            }
        }

    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard appState.hasCompletedSetup else { return true }
        if !flag {
            showSettingsWindow()
        }
        return true
    }

    @objc func handleShowSetup() {
        // Single wizard at a time — opening a second leaks the first's
        // willClose observer and breaks the bail-restore.
        if let existing = setupWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let wasCompleted = appState.hasCompletedSetup
        appState.hasCompletedSetup = false
        appState.stopAccessibilityPolling()
        appState.stopHotkeyMonitoring()
        showSetupWindow()

        // Restore prior state if the user closes the wizard without completing.
        // completeSetup() flips hasCompletedSetup back to true before window.close(),
        // so the !hasCompletedSetup check below correctly skips the restore there.
        if wasCompleted, let window = setupWindow {
            // Drop any stale observer first, then self-remove inside the block, so
            // repeated wizard opens never pile up observers (each broke the restore).
            if let existing = setupWindowObserver {
                NotificationCenter.default.removeObserver(existing)
                setupWindowObserver = nil
            }
            setupWindowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self = self else { return }
                if let token = self.setupWindowObserver {
                    NotificationCenter.default.removeObserver(token)
                    self.setupWindowObserver = nil
                }
                if !self.appState.hasCompletedSetup {
                    self.appState.hasCompletedSetup = true
                    self.appState.startHotkeyMonitoring()
                    self.appState.startAccessibilityPolling()
                    NSApp.setActivationPolicy(.accessory)
                }
                self.setupWindow = nil
            }
        }
    }

    @objc private func handleShowSettings() {
        showSettingsWindow()
    }

    @objc private func handleShowTranscribeAudio() {
        showTranscribeAudioWindow()
    }

    // SuperFeedback — menu-bar app pattern (see SuperFeedback docs/menu-bar-apps.md,
    // "Classic AppKit"): a self-contained NSAlert collects a message + type, captures
    // the app window if one is open, and POSTs via SuperFeedback.send → opens a GitHub
    // Issue in this app's repo. No window/style change needed for our menu.
    @objc private func handleShowSendFeedback() {
        NSApp.activate(ignoringOtherApps: true)
        let screenshot = SuperFeedback.captureWindowPNG()   // nil is fine for a menu-bar app

        let alert = NSAlert()
        alert.messageText = "Send Feedback"
        alert.informativeText = "Found a bug or have an idea? This opens an issue on \(AppName.displayName)'s GitHub" + (screenshot != nil ? ", with a screenshot of the current window." : ".")
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")

        // Accessory: a type picker over a multiline message box.
        let width: CGFloat = 320
        let typePopup = NSPopUpButton(frame: NSRect(x: 0, y: 118, width: 180, height: 25), pullsDown: false)
        typePopup.addItems(withTitles: ["🐞 Bug", "✨ Feature request", "💬 Other"])

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 108))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 108))
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        scroll.documentView = textView

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 150))
        accessory.addSubview(typePopup)
        accessory.addSubview(scroll)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = textView

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let message = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }

        let type: String
        switch typePopup.indexOfSelectedItem {
        case 0: type = "bug"
        case 1: type = "feature"
        default: type = "other"
        }

        Task {
            let result = await SuperFeedback.send(message: message, type: type, screenshot: screenshot)
            await MainActor.run {
                let done = NSAlert()
                if result.ok {
                    done.messageText = "Thanks for the feedback!"
                    done.informativeText = result.url.map { "Opened \($0)" } ?? "Your report was sent."
                } else {
                    done.messageText = "Couldn't send feedback"
                    done.informativeText = (result.error ?? "Unknown error.") + "\n\nPlease try again, or check your internet connection."
                }
                done.addButton(withTitle: "OK")
                done.runModal()
            }
        }
    }

    private func showTranscribeAudioWindow() {
        NSApp.setActivationPolicy(.regular)

        if let transcribeAudioWindow, transcribeAudioWindow.isVisible {
            transcribeAudioWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let transcribeView = TranscribeAudioView()
            .environmentObject(appState)
        let hostingView = NSHostingView(rootView: transcribeView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Transcribe Audio"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 460, height: 420)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        transcribeAudioWindow = window

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            if self?.setupWindow == nil && self?.settingsWindow == nil {
                NSApp.setActivationPolicy(.accessory)
            }
            self?.transcribeAudioWindow = nil
        }
    }

    private func showSettingsWindow() {
        NSApp.setActivationPolicy(.regular)

        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if settingsWindow == nil {
            presentSettingsWindow()
        } else {
            settingsWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func presentSettingsWindow() {
        let settingsView = SettingsView()
            .environmentObject(appState)
        let hostingView = NSHostingView(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppName.displayName
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            if self?.setupWindow == nil {
                NSApp.setActivationPolicy(.accessory)
            }
            self?.settingsWindow = nil
        }
    }


    func showSetupWindow() {
        NSApp.setActivationPolicy(.regular)

        let setupView = SetupView(onComplete: { [weak self] in
            self?.completeSetup()
        })
        .environmentObject(appState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = AppName.displayName
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: setupView)
        window.minSize = NSSize(width: 520, height: 680)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false

        self.setupWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func completeSetup() {
        appState.hasCompletedSetup = true
        setupWindow?.close()
        setupWindow = nil
        NSApp.setActivationPolicy(.accessory)
        appState.startHotkeyMonitoring()
        appState.startAccessibilityPolling()
        Task { @MainActor in
            UpdateManager.shared.startPeriodicChecks()
        }

        if !AXIsProcessTrusted() {
            appState.showAccessibilityAlert()
        }
    }
}
