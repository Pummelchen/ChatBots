// ChatBotsCore — a sample conversation, for laying out the interface
//
// Used by `--seed` so screen captures and layout checks have realistic content: several
// turns, a long reply, a short one, a moderator interjection and a tool line. The point is
// to exercise the layout, not to be interesting — but it has to be long enough that a
// wrapping, scrolling or clamping bug would actually show.

import Foundation

public enum SampleConversation {

    public static func turns(topic: String) -> [Turn] {
        let start = Date.now.addingTimeInterval(-600)
        func at(_ offset: Double) -> Date { start.addingTimeInterval(offset) }

        var sequence = 0
        func next() -> Int {
            sequence += 1
            return sequence
        }

        return [
            Turn(
                sequence: next(), speakerName: "Moderator", kind: .topic,
                content: topic, timestamp: at(0)),

            Turn(
                sequence: next(), speakerID: "Agent 1", speakerName: "Agent 1", kind: .chat,
                content: """
                    The question assumes there is one answer, and I don't think there is.

                    An egg is ovoid because of how it is made, not because ovoid is optimal. \
                    The shell membrane is shaped by the oviduct, and the oviduct is a tube. A \
                    tube produces a shape that is round in cross-section and elongated along \
                    its axis. That is an ovoid. Any bird with a tubular oviduct gets an ovoid \
                    egg whether or not it helps.

                    What I would want before accepting an adaptive story is a comparison \
                    across species with genuinely different oviduct anatomy. Without that, \
                    "ovoid is optimal" is a just-so story.
                    """,
                timestamp: at(40)),

            Turn(
                sequence: next(), speakerID: "Agent 2", speakerName: "Agent 2", kind: .chat,
                content: """
                    That's a mechanism, but a mechanism isn't an explanation of why the shape \
                    persists. Lots of shapes are compatible with a tube.

                    The point load argument is the one I find worth testing: an ovoid resists \
                    a concentrated force at the tip better than a sphere does, and a nest is \
                    full of point loads. That would predict thicker shells at the poles, which \
                    is measurable.
                    """,
                timestamp: at(85)),

            Turn(
                sequence: next(), speakerID: "Agent 1", speakerName: "Agent 1", kind: .tool,
                content: "web_search: 5 result(s) for \"egg shape oviduct membrane\"",
                timestamp: at(120)),

            Turn(
                sequence: next(), speakerName: "Moderator", kind: .steering,
                content: "Both of you: keep it to claims you can support.",
                timestamp: at(155)),

            Turn(
                sequence: next(), speakerID: "Agent 2", speakerName: "Agent 2", kind: .chat,
                content: "Fine. Thicker at the poles is testable, and if it holds, the mechanism story needs revising.",
                timestamp: at(190)),
        ]
    }
}
