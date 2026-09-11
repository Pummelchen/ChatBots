// ChatBotsApp — an AppKit scroll view for the transcript
//
// SwiftUI's `ScrollViewReader.scrollTo` is unusable in this hierarchy. Any call to it —
// even throttled to 250 ms, even reduced to once per finished turn — sends the view graph
// into a transaction loop, and within a minute of streaming the window stops drawing
// (verified twice by sampling: the main thread pins inside `NSRunLoop.flushObservers` →
// `GraphHost.flushTransactions`). The loop is `scrollTo` → content resize → republish →
// `scrollTo`.
//
// So the transcript is hosted in a plain `NSScrollView`, scrolled through AppKit's
// direct, one-way primitive (`contentView.scroll(to:)`, no animation) from a deferred
// main-queue turn. Scrolling is strictly event-driven — once per completed turn. A timer
// that re-scrolls while a model streams re-enters SwiftUI's update pass on every tick and
// the window stops drawing, at both 40 ms and 500 ms cadence. It also brings the standard
// macOS overlay scrollbars and rubber-banding for free.

import AppKit
import SwiftUI

/// A vertical `NSScrollView` hosting arbitrary SwiftUI content.
///
/// The content is sized to its ideal height, so the enclosing scroll view does the
/// scrolling rather than the content being compressed.
struct AppKitScrollView<Content: View>: NSViewRepresentable {
    /// Bumped by the caller when it wants the view scrolled to the bottom. Scrolling only
    /// happens when this value changes, so a redraw alone never moves the viewport.
    var scrollToBottomSignal: Int
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        scrollView.scrollerStyle = .overlay

        let hosting = NSHostingView(rootView: AnyView(content()))
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width]
        scrollView.documentView = hosting

        context.coordinator.hostingView = hosting
        context.coordinator.lastSignal = scrollToBottomSignal
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let hosting = context.coordinator.hostingView else { return }

        // Re-render the SwiftUI content.
        hosting.rootView = AnyView(content())

        // The document view must be as tall as the content wants to be, otherwise the
        // scroll view has nothing to scroll.
        let fitting = hosting.fittingSize
        if abs(hosting.frame.height - fitting.height) > 0.5
            || abs(hosting.frame.width - scrollView.contentSize.width) > 0.5
        {
            hosting.frame = NSRect(
                x: 0, y: 0,
                width: max(fitting.width, scrollView.contentSize.width),
                height: max(fitting.height, scrollView.contentSize.height)
            )
        }

        let signalChanged = context.coordinator.lastSignal != scrollToBottomSignal
        context.coordinator.lastSignal = scrollToBottomSignal
        guard signalChanged else { return }

        // Scroll *after* this update pass, never inside it. Touching the clip view
        // during `updateNSView` invalidates the layout that is still being applied, so
        // SwiftUI re-enters the transaction and the main thread never leaves the update
        // observer (verified by sampling: `NSRunLoop.flushObservers` →
        // `GraphHost.flushTransactions`, indefinitely). Deferring to the next main-queue
        // turn breaks that cycle, and the re-entrancy guard collapses a burst of
        // requests into one scroll.
        guard !context.coordinator.scrollScheduled else { return }
        context.coordinator.scrollScheduled = true
        DispatchQueue.main.async {
            context.coordinator.scrollScheduled = false
            context.coordinator.scrollToBottom(scrollView)
        }
    }

    final class Coordinator {
        var hostingView: NSHostingView<AnyView>?
        var lastSignal = 0
        var scrollScheduled = false

        /// One-way scroll: no animation, so it cannot queue a follow-up transaction.
        func scrollToBottom(_ scrollView: NSScrollView) {
            guard let documentView = scrollView.documentView else { return }
            let visibleHeight = scrollView.contentView.bounds.height
            let documentHeight = documentView.frame.height
            guard documentHeight > visibleHeight else { return }
            let target = NSPoint(x: 0, y: documentHeight - visibleHeight)
            scrollView.contentView.scroll(to: target)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}
