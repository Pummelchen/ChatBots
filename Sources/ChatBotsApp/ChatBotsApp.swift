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
    @StateObject private var controller = ChatController()
    @StateObject private var theme = ThemeStore()

    /// Below this the two panes stop being usable side by side.
    private static let minimumWindowSize = NSSize(width: 720, height: 480)

    var body: some Scene {
        // The title bar is left fully standard: close / minimize / zoom, double-click to
        // zoom, drag to move, drag edges to resize. `WindowConfigurator` only sets the
        // appearance and the first-launch frame.
        Window("ChatBots", id: "main") {
            ContentView(controller: controller)
                .themePalette(theme.palette)
                .environmentObject(theme)
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
