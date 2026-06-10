// SuperFeedback — native macOS (SwiftUI + AppKit) reference widget. v1.1.0
//
// Same contract as the web widget (see ../../PROTOCOL.md). Capture a window
// screenshot, collect a message, POST it to your backend, which opens a GitHub
// Issue (with the screenshot) in your app's repo.
//
// Placement options (pick the least-intrusive for your app):
//   • Floating button:   ContentView().modifier(SuperFeedbackButton())
//   • Menu / toolbar / anywhere:
//        - attach the panel once:   RootView().superFeedbackHost()
//        - open it from anything:   Button("Send Feedback…") { SuperFeedback.present() }
//          (e.g. in a `.commands { CommandGroup(after: .help) { … } }`, a toolbar item,
//           or a right-click menu)
//
// Setup once at launch:
//   SuperFeedback.configure(backendURL: URL(string: "https://…workers.dev")!,
//                           repo: "lman80/my-app", app: "My App")
//
// Requires macOS 12+. The screenshot uses view caching (no Screen Recording prompt).

import SwiftUI
import AppKit

// MARK: - Core

enum SuperFeedback {
    static let version = "1.1.1"

    struct Config {
        var backendURL: URL
        var repo: String
        var app: String
        var appKey: String
    }

    static var config: Config?

    static func configure(backendURL: URL, repo: String, app: String, appKey: String = "") {
        config = Config(backendURL: backendURL, repo: repo, app: app, appKey: appKey)
    }

    /// Open the feedback panel from anywhere (menu item, toolbar, shortcut). The host
    /// modifier (`.superFeedbackHost()`) must be attached somewhere in the view tree.
    static func present() {
        let shot = captureWindowPNG()
        DispatchQueue.main.async {
            SuperFeedbackModel.shared.screenshot = shot
            SuperFeedbackModel.shared.presented = true
        }
    }

    /// Captures the key window's content as a PNG data URL. Returns nil if unavailable.
    static func captureWindowPNG() -> String? {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }),
              let view = window.contentView else { return nil }
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + data.base64EncodedString()
    }

    struct Result { let ok: Bool; let url: String?; let error: String? }

    static func send(message: String, type: String, screenshot: String?) async -> Result {
        guard let c = config else { return Result(ok: false, url: nil, error: "SuperFeedback.configure was not called") }

        var meta: [String: String] = [
            "platform": "macOS " + ProcessInfo.processInfo.operatingSystemVersionString,
            "os": "darwin",
            "locale": Locale.current.identifier,
        ]
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String { meta["appVersion"] = v }

        var payload: [String: Any] = [
            "repo": c.repo, "app": c.app, "type": type, "message": message, "meta": meta,
        ]
        if let s = screenshot { payload["screenshot"] = s }
        if !c.appKey.isEmpty { payload["appKey"] = c.appKey }

        do {
            var req = URLRequest(url: c.backendURL.appendingPathComponent("report"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, _) = try await URLSession.shared.data(for: req)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let ok = (obj?["ok"] as? Bool) ?? false
            return Result(ok: ok, url: obj?["url"] as? String, error: obj?["error"] as? String)
        } catch {
            return Result(ok: false, url: nil, error: error.localizedDescription)
        }
    }
}

// MARK: - Shared state + host

final class SuperFeedbackModel: ObservableObject {
    static let shared = SuperFeedbackModel()
    @Published var presented = false
    @Published var screenshot: String?
}

/// Attach once near the root so `SuperFeedback.present()` can open the panel from anywhere.
struct SuperFeedbackHost: ViewModifier {
    @ObservedObject private var model = SuperFeedbackModel.shared
    func body(content: Content) -> some View {
        content.sheet(isPresented: $model.presented) {
            SuperFeedbackSheet(isPresented: $model.presented, screenshot: $model.screenshot)
        }
    }
}

extension View {
    /// Enables `SuperFeedback.present()` from menus, toolbars, shortcuts, etc.
    func superFeedbackHost() -> some View { modifier(SuperFeedbackHost()) }
}

// MARK: - Floating button (one of several placement options)

/// Floats a "Feedback" button over your content. Usage: `.modifier(SuperFeedbackButton())`
struct SuperFeedbackButton: ViewModifier {
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                Button { SuperFeedback.present() } label: {
                    Label("Feedback", systemImage: "bubble.left.and.bubble.right.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(20)
            }
            .superFeedbackHost()
    }
}

// MARK: - The panel

struct SuperFeedbackSheet: View {
    @Binding var isPresented: Bool
    @Binding var screenshot: String?

    @State private var type = "bug"
    @State private var message = ""
    @State private var attach = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send feedback").font(.headline)

            Picker("Type", selection: $type) {
                Text("🐞 Bug").tag("bug")
                Text("✨ Feature request").tag("feature")
                Text("💬 Other").tag("other")
            }
            .pickerStyle(.segmented)

            TextEditor(text: $message)
                .frame(minHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))

            if screenshot != nil {
                Toggle("Attach screenshot", isOn: $attach)
            }

            HStack {
                Button("Cancel") { isPresented = false }
                Spacer()
                Button("Send") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 360)
    }

    // Close immediately; upload in the background so the user never waits.
    private func submit() {
        let msg = message
        let t = type
        let shot = attach ? screenshot : nil
        isPresented = false
        Task { _ = await SuperFeedback.send(message: msg, type: t, screenshot: shot) }
    }
}
