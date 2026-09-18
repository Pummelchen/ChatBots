// ChatBotsCLI — the `--export-sample` mode
//
// Printing the export format, with no model involved: handy for checking what a saved conversation
// looks like, and for support. Split out of `main.swift`, which held the entry point, the command
// line and every mode in one 1132-line file.

import ChatBotsCore
import Foundation

enum ExportSample {

    static func run(options: Options) {
        // Named, so the sample shows what a real log looks like. Built here rather than read
        // from the roster: the sample demonstrates the export format, so it needs two seats
        // whatever this run's roster is — and indexing `namedSpecs()[1]` trapped with a
        // "Fatal error: Index out of range" for the legal one-seat `CHATBOTS_SEATS=1`
        // configuration.
        var sampleSeats = [
            AgentSpec.seat(index: 0, modelID: options.modelA),
            AgentSpec.seat(index: 1, modelID: options.modelB),
        ]
        var nameGenerator = SystemRandomNumberGenerator()
        AgentSpec.assignNames(to: &sampleSeats, using: &nameGenerator)
        let specA = sampleSeats[0]
        let specB = sampleSeats[1]
        let stamp: (String) -> Date = { value in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter.date(from: value) ?? Date.now
        }
        let turns = [
            Turn(
                sequence: 1, speakerName: "Moderator", kind: .topic,
                content: options.topic, timestamp: stamp("2026-12-25 13:15:04")),
            Turn(
                sequence: 2, speakerName: specA.displayName, kind: .chat,
                content:
                    "An ovoid resists a point load at the tip far better than a sphere does.\nThe shell thickens "
                    + "where curvature is highest.",
                timestamp: stamp("2026-12-25 13:15:41")),
            Turn(
                sequence: 3, speakerName: specB.displayName, kind: .chat,
                content: "Which part of that is established? A sphere is the minimal surface for a given volume.",
                timestamp: stamp("2026-12-25 13:16:02")),
        ]
        print(
            TranscriptWriter.text(
                topic: options.topic, turns: turns, participants: [specA, specB],
                exportedAt: stamp("2026-12-25 13:20:00")))
        exit(0)
    }
}
