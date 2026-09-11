// ChatBotsApp — application entry point
//
// A plain SwiftUI `App`. `WindowConfigurator` attaches to the key window once so the
// two-pane layout opens at a sensible size; nothing here reaches into the engine.

import AppKit
import ChatBotsCore
import SwiftUI

@main
struct ChatBotsApp: App {
    @StateObject private var controller = ChatController()
    @StateObject private var theme = ThemeStore()

    var body: some Scene {
        Window("ChatBots — two local LLMs, one conversation", id: "main") {
            ContentView(controller: controller)
                .themePalette(theme.palette)
                .environmentObject(theme)
                // The black theme is dark-only regardless of the Mac's setting; the
                // original theme follows the system.
                .preferredColorScheme(theme.mode == .black ? .dark : nil)
                .background(WindowConfigurator(palette: theme.palette))
        }
        .defaultSize(width: 1280, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Pause / Resume") { controller.togglePause() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Stop") { controller.stop() }
                    .keyboardShortcut(".", modifiers: .command)
            }
        }
    }
}

/// Positions, darkens and focuses the window on first appearance.
///
/// Applies the window geometry and appearance.
///
/// SwiftUI has no window appearance API, so the `NSWindow` is configured here. The
/// appearance and background are set as well as in SwiftUI so the titlebar and any
/// gutter around the split view match the theme. For the black theme the window
/// appearance is pinned to dark, because a light-mode Mac would otherwise give the
/// titlebar light chrome above an all-black window.
struct WindowConfigurator: NSViewRepresentable {
    let palette: AppPalette

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.title = "ChatBots"
            applyAppearance(to: window)
            window.setContentSize(NSSize(width: 1280, height: 780))
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
    /// `center()` alone is not enough: at 1280pt wide the window is wider than a 13"
    /// MacBook's default 1131pt desktop, and centring it then leaves its right edge —
    /// which is where the second pane and the theme picker live — off-screen.
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
        }
    }
}
