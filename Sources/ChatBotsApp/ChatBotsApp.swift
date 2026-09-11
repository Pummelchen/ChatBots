// ChatBotsApp — application entry point
//
// A plain SwiftUI `App`. `WindowConfigurator` attaches to the key window so the
// two-pane layout opens at a sensible size and picks up the theme; nothing here reaches
// into the engine.

import AppKit
import ChatBotsCore
import SwiftUI

@main
struct ChatBotsApp: App {
    @StateObject private var controller: ChatController
    @StateObject private var endpoints = APIEndpointStore()
    @StateObject private var settings: UserSettingsStore
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // Before any engine loads: point model storage at the project's `models/` folder
        // and make sure it exists. See ModelStore for how the path is resolved.
        ModelStore.prepare()

        // Restore what the user set last time — topic, per-seat persona/thinking/backend,
        // and the thinking-block toggle — and write it back on every change.
        let store = UserSettingsStore()
        let restored = ChatController(
            specs: store.settings.seats,
            initialTopic: store.settings.topic,
            initialModeratorDraft: store.settings.moderatorDraft,
            initialShowReasoning: store.settings.showReasoning
        )
        // Every change writes: the topic as it is typed, and each seat's persona, thinking
        // level and backend as they are picked.
        let snapshot: @MainActor () -> UserSettings = { [weak restored] in
            UserSettings(
                topic: restored?.topic ?? "",
                moderatorDraft: restored?.moderatorDraft ?? "",
                showReasoning: restored?.showReasoning ?? true,
                seats: restored?.currentSeats ?? AgentSpec.SeatRoster.specs()
            )
        }
        restored.onSettingsChanged = { [weak store] in
            guard let store else { return }
            store.save(snapshot())
        }
        // If something was stored but unreadable, say so once rather than letting the user
        // wonder why their setup reverted.
        if let warning = store.takeLoadWarning() {
            restored.errorBanner = warning
        }
        _settings = StateObject(wrappedValue: store)
        _controller = StateObject(wrappedValue: restored)

        AppDelegate.flush = { [weak store] in
            guard let store else { return }
            store.saveNow(snapshot())
        }
    }
    @StateObject private var theme = ThemeStore()
    @StateObject private var zoom = ZoomStore()

    /// Below this the two panes stop being usable side by side. Scaled with the text size:
    /// at 200% text the same 720 points would clip every label, so the floor rises with it.
    private var minimumWindowSize: NSSize {
        NSSize(width: 720 * zoom.scale, height: 480 * (1 + (zoom.scale - 1) * 0.5))
    }

    var body: some Scene {
        // The title bar is left fully standard: close / minimize / zoom, double-click to
        // zoom, drag to move, drag edges to resize. `WindowConfigurator` only sets the
        // appearance and the first-launch frame.
        Window("ChatBots", id: "main") {
            ContentView(controller: controller)
                .themePalette(theme.palette)
                .environmentObject(theme)
                .environmentObject(endpoints)
                .environmentObject(settings)
                .environmentObject(zoom)
                // Restore each seat's saved endpoint before any turn can run.
                .task { controller.applyAPIEndpoints(endpoints) }
                // The black theme is dark-only regardless of the Mac's setting; the
                // original theme follows the system.
                .preferredColorScheme(theme.mode == .black ? .dark : nil)
                .background(WindowConfigurator(palette: theme.palette))
        }
        .defaultSize(width: 1280, height: 780)
        // `.contentMinSize` would cap the window at the content's maximum size — with a
        // fixed frame in the view that caps it at exactly one size, which is what made
        // the window refuse to resize. `.contentSize` lets the window grow freely and
        // derives its *minimum* from the content, which is what we want.
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}

            // The panes contain no selectable text (see AppKitScrollView), so copying the
            // transcript is an explicit command rather than ⌘A then ⌘C.
            CommandGroup(after: .pasteboard) {
                Button("Copy Conversation") { controller.copyConversation() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(controller.turns.isEmpty)
            }

            CommandGroup(after: .saveItem) {
                Button("Save Conversation…") { controller.saveConversation() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(controller.turns.isEmpty)

                Button("Clear Conversation") { controller.reset() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(controller.isRunning)

                Divider()

                Button("Start Conversation") { controller.startOrRestart() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!controller.canStart)
                Button(controller.status.isPaused ? "Resume" : "Pause") {
                    controller.togglePause()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!controller.status.isActive && !controller.status.isPaused)
                Button("Stop Conversation") { controller.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!controller.status.isActive && !controller.status.isPaused)

                Divider()

                Button("Send Moderator Message") { controller.sendModeratorMessage() }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(
                        controller.moderatorDraft
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // A theme is a view setting on macOS, so it belongs in View as well as in the
            // bar. SwiftUI supplies Minimize/Zoom/Enter Full Screen after this group.
            CommandGroup(after: .toolbar) {
                Picker("Window Layout", selection: $theme.windowMode) {
                    ForEach(WindowMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.inline)

                Divider()

                Divider()

                Button("Bigger Text") { zoom.step(larger: true) }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(!zoom.canEnlarge)
                Button("Smaller Text") { zoom.step(larger: false) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(!zoom.canReduce)
                Button("Actual Text Size") { zoom.reset() }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(zoom.percent == zoom.resetPercent)

                Divider()

                Picker("Theme", selection: $theme.mode) {
                    ForEach(ThemeMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            }

            CommandGroup(replacing: .help) {
                Button("ChatBots Help") { HelpWindow.show() }
            }
        }
    }
}

/// Opens a small standard About-panel-style help window.
/// Writes the settings one last time on the way out.
///
/// The store already writes as changes happen, so this only closes the gap of the short
/// coalescing window — but "it forgot my last edit" is exactly the kind of thing that makes
/// an app feel unreliable, so it is worth the few lines.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the controller exists; called on termination. Main-actor isolated because
    /// it closes over the controller, and `applicationWillTerminate` arrives on the main
    /// thread.
    @MainActor static var flush: (() -> Void)?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Self.flush?() }
    }
}


enum HelpWindow {
    @MainActor
    static func show() {
        let alert = NSAlert()
        alert.messageText = "ChatBots"
        alert.informativeText = """
            Two local LLMs discuss a topic you set, with you as moderator.

            Start / Restart   ⌘↩
            Pause / Resume    ⇧⌘P
            Stop              ⌘.
            Clear transcript  ⌘K
            Steer both models ⇧⌘↩

            Both models run in-process on the GPU via MLX. Your moderator messages go \
            into the shared log, so both models read them.
            """
        alert.addButton(withTitle: "OK")
        alert.alertStyle = .informational
        alert.runModal()
    }
}

/// Applies the window appearance and first-launch frame.
///
/// Appearance is set at the AppKit level as well as in SwiftUI, because a SwiftUI
/// background alone leaves the titlebar and the split-view gutter in the system
/// appearance. Beyond that the window is a completely standard macOS window: it is
/// resizable, minimizable, zoomable and fullscreen-capable, and SwiftUI's `Window` scene
/// handles frame autosave so the size and position survive relaunch.
struct WindowConfigurator: NSViewRepresentable {
    let palette: AppPalette

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.title = "ChatBots"
            window.contentMinSize = NSSize(width: 720, height: 480)
            window.collectionBehavior.insert(.fullScreenPrimary)
            // Traffic lights are only hidden by `.fullSizeContentView`; make sure nothing
            // has turned them off.
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = false
            }
            applyAppearance(to: window)
            Self.fitOnScreen(window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        DispatchQueue.main.async { applyAppearance(to: window) }
    }

    /// Sizes and centres the window so it always fits the screen it opens on.
    ///
    /// `center()` alone is not enough: a 1280pt-wide window on a 1512pt-wide desktop,
    /// centred, can still hang its right edge — where the second pane and the theme
    /// picker live — past the display boundary.
    private static func fitOnScreen(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else {
            window.center()
            return
        }
        let available = screen.visibleFrame
        var size = window.frame.size
        size.width = min(size.width, available.width - 24)
        size.height = min(size.height, available.height - 24)
        let origin = NSPoint(
            x: available.midX - size.width / 2,
            y: available.midY - size.height / 2
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func applyAppearance(to window: NSWindow) {
        if palette.forcesDarkChrome {
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .black
            window.titlebarAppearsTransparent = true
            window.isOpaque = true
        } else {
            // Hand the window back to the system so it tracks the Mac's appearance.
            window.appearance = nil
            window.backgroundColor = .windowBackgroundColor
            window.titlebarAppearsTransparent = false
            window.isOpaque = true
        }
    }
}
