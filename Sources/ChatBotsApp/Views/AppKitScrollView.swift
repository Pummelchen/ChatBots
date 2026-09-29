// ChatBotsApp — an AppKit scroll view for the transcript
//
// SwiftUI's `ScrollViewReader.scrollTo` is unusable in this hierarchy. Any call to it —
// even throttled to 250 ms, even reduced to once per finished turn — sends the view graph
// into a transaction loop, and within a minute of streaming the window stops drawing
// (verified twice by sampling: the main thread pins inside `NSRunLoop.flushObservers` →
// `GraphHost.flushTransactions`). The loop is `scrollTo` → content resize → republish →
// `scrollTo`.
//
// A second, related hazard lives in the same area: `.textSelection(.enabled)` on any view
// inside a pane. The pane republishes roughly 20 times a second while a model streams, so
// the selection overlay is rebuilt on every pass, and each rebuild re-runs its text scan
// and triggers another layout cycle. That also ends with the main thread pinned in
// `GraphHost.flushTransactions` and a window that no longer draws — verified by removing
// the modifier from one view at a time until the freezes stopped. There is therefore no
// selectable text in the panes; Edit ▸ Copy Conversation copies the whole transcript.
//
// So the transcript is hosted in a plain `NSScrollView`, scrolled through AppKit's
// direct, one-way primitive (`contentView.scroll(to:)`, no animation) from a deferred
// main-queue turn. Two things ask for that scroll: the caller's signal, which is how a finished
// turn brings its last line into view, and the document growing, which keeps a streamed reply in
// sight as it is written. Both yield to the reader: while the transcript is scrolled away from the
// bottom nothing moves it, and returning to the bottom hands it back to the stream.
//
// **The content must be laid out eagerly.** This view sizes its document from the content's own
// fitting size, so a lazy stack — which reports an *estimate* until its off-screen rows have been
// measured, and they cannot be measured until they scroll into view — leaves the document too short.
// The visible result is the newest row clipped and unreachable, and text that shifts under the
// reader as the estimate is revised. A transcript is bounded by the turn limit, so there is nothing
// for laziness to buy here. A *timer* that
// re-scrolls while a model streams re-enters SwiftUI's update pass on every tick and the window
// stops drawing, at both 40 ms and 500 ms cadence; a resize is not that, because the update pass
// that grew the document is already running and the scroll is deferred out of it. It also brings
// the standard macOS overlay scrollbars and rubber-banding for free.

import AppKit
import SwiftUI

/// How far above the bottom still counts as "at the bottom" when deciding whether to follow a stream.
///
/// At file scope rather than on the coordinator because a static stored property is not allowed in a
/// generic type, and this view is generic over its content.
///
/// Small on purpose: the bottom inset already leaves empty space below the last line, and a generous
/// tolerance would keep following — and moving — for a reader who has deliberately scrolled up a
/// little.
private let scrollPinTolerance: CGFloat = 12

/// A vertical `NSScrollView` hosting arbitrary SwiftUI content.
///
/// The content is sized to its ideal height, so the enclosing scroll view does the
/// scrolling rather than the content being compressed.
struct AppKitScrollView<Content: View>: NSViewRepresentable {
    /// Bumped by the caller when it wants the view scrolled to the bottom. Scrolling only
    /// happens when this value changes, so a redraw alone never moves the viewport.
    var scrollToBottomSignal: Int
    /// Empty space kept below the last line.
    ///
    /// Without it the transcript ends flush against the bottom edge, so the last line sits half
    /// under the pane's edge and a descender or a wrapped word is cut off. The inset is content, so
    /// scrolling to the bottom leaves it visible — and the document has to be sized from its content
    /// for that to be true at all, which is what the eager layout in the transcript views is for.
    var bottomInset: CGFloat = 36
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        // Always visible. Overlay scrollers hide themselves once the pointer leaves, and a transcript
        // you cannot tell the length of — or even that it scrolls — is what "there is no scrollbar"
        // means from the outside.
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        scrollView.scrollerStyle = .overlay

        // The inset is content rather than a clip-view inset, so the document is genuinely taller
        // than the text and the scroll to the bottom lands on empty space below the last line.
        let hosting = NSHostingView(rootView: AnyView(content().padding(.bottom, bottomInset)))
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width]
        scrollView.documentView = hosting

        context.coordinator.hostingView = hosting
        context.coordinator.lastSignal = scrollToBottomSignal
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let hosting = context.coordinator.hostingView else { return }

        // Measured *before* the content is replaced. Afterwards the document has already grown and a
        // view that was at the bottom no longer is, so asking then would answer "not at the bottom"
        // for every update of a stream and following would never happen at all.
        let wasAtBottom = context.coordinator.isAtBottom(scrollView)

        // Re-render the SwiftUI content. The inset is applied here as well as at creation: the
        // root view is replaced on every pass, so leaving it out of one of the two drops the empty
        // space below the last line as soon as the first update arrives.
        hosting.rootView = AnyView(content().padding(.bottom, bottomInset))

        // The document view must be as tall as the content wants to be, otherwise the
        // scroll view has nothing to scroll.
        let fitting = hosting.fittingSize
        var resized = false
        if abs(hosting.frame.height - fitting.height) > 0.5
            || abs(hosting.frame.width - scrollView.contentSize.width) > 0.5
        {
            hosting.frame = NSRect(
                x: 0, y: 0,
                width: max(fitting.width, scrollView.contentSize.width),
                height: max(fitting.height, scrollView.contentSize.height)
            )
            resized = true
        }

        let signalChanged = context.coordinator.lastSignal != scrollToBottomSignal
        context.coordinator.lastSignal = scrollToBottomSignal
        // Following the stream makes a document that grew reason enough to scroll, and the signal is the
        // caller asking for one. Both yield to the reader: scrolling up means "stay here", so a reply
        // that arrives while someone is reading earlier in the conversation no longer drags the view off
        // the page they were on. Scrolling back to the bottom hands the view back to the stream.
        guard wasAtBottom, signalChanged || resized else { return }

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

    /// `@MainActor` because everything it touches — `NSScrollView`, `NSClipView`,
    /// `NSHostingView` — is main-actor isolated. Without it those calls are made from a
    /// nonisolated context, which the compiler warns about and which is a real hazard rather
    /// than a formality: AppKit view state belongs to the main thread.
    @MainActor
    final class Coordinator {
        var hostingView: NSHostingView<AnyView>?
        var lastSignal = 0
        var scrollScheduled = false

        /// Whether the bottom of the document is in view.
        ///
        /// The one piece of reader intent this view has to respect. A document shorter than the
        /// viewport is always at the bottom, which is what lets the first lines of a reply follow the
        /// stream before there is anything to scroll.
        func isAtBottom(_ scrollView: NSScrollView) -> Bool {
            guard let documentView = scrollView.documentView else { return true }
            let distance = documentView.frame.height - scrollView.contentView.bounds.maxY
            return distance <= scrollPinTolerance
        }

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
