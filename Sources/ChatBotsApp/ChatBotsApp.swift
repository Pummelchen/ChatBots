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

    var body: some Scene {
        Window("ChatBots — two local LLMs, one conversation", id: "main") {
            ContentView(controller: controller)
                .background(WindowConfigurator())
        }
        .defaultSize(width: 1280, height: 780)
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

/// Positions and focuses the window on first appearance.
///
/// SwiftUI gives no window geometry API, so grab the `NSWindow` once. If two displays
/// are present the window is nudged onto the main one rather than straddling the seam.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.title = "ChatBots"
            window.setContentSize(NSSize(width: 1280, height: 780))
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
