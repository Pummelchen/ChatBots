// ChatBotsCoreTests — the names the participants are given

import ChatBotsCore
import Foundation
import Testing

@Suite("Name lists")
struct NameListTests {

    @Test("All six languages are present, each with both lists")
    func languagesPresent() {
        #expect(NameLanguage.allCases.count == 6)
        for language in NameLanguage.allCases {
            let list = NameLists.list(for: language)
            #expect(list.female.count >= 15, "\(language) has too few female names")
            #expect(list.male.count >= 15, "\(language) has too few male names")
            #expect(!language.label.isEmpty)
        }
    }

    @Test("The languages the brief asked for")
    func requestedLanguages() {
        let labels = NameLanguage.allCases.map(\.label)
        for expected in [
            "English", "French", "German", "Spanish (Latino)",
            "Brazilian Portuguese", "Italian",
        ] {
            #expect(labels.contains(expected), "missing \(expected)")
        }
    }

    @Test("No name appears in both lists, or twice in one")
    func namesAreDistinct() {
        // A name in both lists would make the female and male picks occasionally identical,
        // which defeats the point of asking for one of each.
        for language in NameLanguage.allCases {
            let list = NameLists.list(for: language)
            #expect(Set(list.female).count == list.female.count, "\(language) repeats a female name")
            #expect(Set(list.male).count == list.male.count, "\(language) repeats a male name")
            let overlap = Set(list.female).intersection(list.male)
            #expect(overlap.isEmpty, "\(language) has names in both lists: \(overlap)")
        }
    }

    @Test("Names are non-empty, single-line, and not marked up")
    func namesAreClean() {
        for language in NameLanguage.allCases {
            let list = NameLists.list(for: language)
            for name in list.female + list.male {
                #expect(!name.isEmpty)
                #expect(!name.contains("\n"))
                // The parser strips markers and comments; a stray one would mean the file
                // format is being ignored.
                #expect(!name.hasPrefix("["), "\(name) looks like a section marker")
                #expect(!name.hasPrefix("#"), "\(name) looks like a comment")
                #expect(name.first?.isLetter == true, "\(name) does not start with a letter")
            }
        }
    }

    @Test("Accents and non-ASCII names survive")
    func unicodeNames() {
        // Six languages, several of which have names that are not plain ASCII. A name that
        // arrives mangled would be worse than one that is missing.
        let all = NameLanguage.allCases.flatMap {
            let list = NameLists.list(for: $0)
            return list.female + list.male
        }
        #expect(all.contains("Amélie"))
        #expect(all.contains("João Pedro"))
        #expect(all.contains("Jürgen"))
        #expect(all.contains("Lucía"))
        #expect(all.contains("Vittoria"))
        for name in all {
            #expect(!name.contains("\u{FFFD}"), "\(name) has a replacement character")
        }
    }
}

@Suite("Assigning names at startup")
struct NameAssignmentTests {

    /// A generator that hands out a fixed sequence, so a test can predict the pick.
    private struct Counting: RandomNumberGenerator {
        var value: UInt64 = 0
        mutating func next() -> UInt64 {
            value &+= 1
            return value &* 6_364_136_223_846_793_005
        }
    }

    @Test("Agent 1 gets a female name and Agent 2 a male one")
    func oneOfEach() {
        var seats = AgentSpec.makeSeats(count: 2)
        var generator = Counting()
        AgentSpec.assignNames(to: &seats, using: &generator)

        let female = Set(NameLanguage.allCases.flatMap { NameLists.list(for: $0).female })
        let male = Set(NameLanguage.allCases.flatMap { NameLists.list(for: $0).male })

        #expect(female.contains(seats[0].displayName), "\(seats[0].displayName) is not a female name")
        #expect(male.contains(seats[1].displayName), "\(seats[1].displayName) is not a male name")
        // And the names are not the seat numbers any more.
        #expect(seats[0].displayName != "Agent 1")
        #expect(seats[1].displayName != "Agent 2")
    }

    @Test("The seat ids are untouched, so the log and settings keep working")
    func idsAreUnchanged() {
        var seats = AgentSpec.makeSeats(count: 2)
        let originalIDs = seats.map(\.id)
        var generator = Counting()
        AgentSpec.assignNames(to: &seats, using: &generator)
        #expect(seats.map(\.id) == originalIDs)
        #expect(seats[0].id == "Agent 1")
    }

    @Test("A third and fourth seat keep their numbers")
    func onlyTheFirstTwoAreNamed() {
        // The brief is about the pair. Inventing a gender balance for four seats would be
        // arbitrary, so the rest keep their seat numbers.
        var seats = AgentSpec.makeSeats(count: 4)
        var generator = Counting()
        AgentSpec.assignNames(to: &seats, using: &generator)
        #expect(seats[2].displayName == "Agent 3")
        #expect(seats[3].displayName == "Agent 4")
    }

    @Test("One seat is named, and does not crash")
    func singleSeat() {
        var seats = AgentSpec.makeSeats(count: 1)
        var generator = Counting()
        AgentSpec.assignNames(to: &seats, using: &generator)
        #expect(seats[0].displayName != "Agent 1")
        #expect(seats.count == 1)
    }

    @Test("The roster the app starts from is named")
    func rosterIsNamed() {
        let seats = AgentSpec.SeatRoster.namedSpecs(environment: [:])
        #expect(seats.count == AgentSpec.SeatRoster.shippingCount)
        #expect(seats[0].displayName != "Agent 1")
        #expect(seats[1].displayName != "Agent 2")
    }

    @Test("Different starts give different names")
    func namesVaryBetweenStarts() {
        // The whole point: two runs should not open with the same pair. Checked over several
        // draws rather than one, because any single pair could legitimately repeat.
        var seen = Set<String>()
        for _ in 0..<12 {
            var seats = AgentSpec.makeSeats(count: 2)
            var generator = SystemRandomNumberGenerator()
            AgentSpec.assignNames(to: &seats, using: &generator)
            seen.insert(seats.map(\.displayName).joined(separator: "/"))
        }
        #expect(seen.count > 3, "names barely varied across twelve starts: \(seen)")
    }

    @Test("A name reaches the prompt, so the models use it")
    func nameReachesThePrompt() {
        var spec = AgentSpec.seat(index: 0)
        spec.displayName = "Amélie"
        var other = AgentSpec.seat(index: 1)
        other.displayName = "Joaquín"

        let conversation = Conversation(
            topic: "Eggs",
            turns: [Turn(sequence: 1, speakerName: "Moderator", kind: .topic, content: "Eggs")])
        let text = PromptBuilder.prompt(for: spec, others: [other], conversation: conversation)
            .map(\.content).joined(separator: "\n")

        #expect(text.contains("You are Amélie"))
        #expect(text.contains("Joaquín"))
        #expect(!text.contains("You are Agent 1"))
    }
}
