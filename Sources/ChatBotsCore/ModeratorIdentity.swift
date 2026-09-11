// ChatBotsCore — who the human moderator is
//
// The models have names, characters and methods. The person who commissioned the work and who
// cuts in to redirect it had none: their messages arrived as `[Moderator]`, which is a role
// rather than a person, and nothing in the prompt said who was asking or how they argue.
//
// That is a small gap with a large effect in a research session. "The moderator is the person
// commissioning this work" is the rule the analysts are given; a rule about a role is weaker
// than knowing that the person asking is a sceptical operator who wants the downside first. So
// the human gets an identity of their own — a name and, optionally, a persona from the same
// library the seats draw from — and it is presented to the room the same way a seat's is.
//
// **It is not a character sheet for the human.** The moderator's persona shapes *how their
// interjections are read* and nothing else; it does not generate their messages, it is not a
// prompt for them, and there is no model behind it. A front end that made the human's persona
// do anything more would be putting words in the moderator's mouth.

import Foundation

/// The human moderator, as the room sees them.
public struct ModeratorIdentity: Sendable, Hashable, Codable {
    /// What the room calls this person.
    public var name: String
    /// A persona from the active mode's library, or `neutral` for none.
    ///
    /// Held as an identifier and resolved at use, for the same reason a seat's is: switching
    /// mode between a show and an investigation has to leave a stored identifier that still
    /// means something.
    public var personaID: String

    public init(name: String = ModeratorIdentity.defaultName, personaID: String = PersonaLibrary.neutral.id) {
        self.name = name
        self.personaID = personaID
    }

    public static let defaultName = "Moderator"

    /// Whether this is the default, so a prompt can leave the line out rather than saying
    /// nothing interesting at length.
    public var isDefault: Bool {
        name == Self.defaultName && personaID == PersonaLibrary.neutral.id
    }

    /// What the room is told about the human, in the mode they are working in.
    ///
    /// Returns nil when there is nothing worth saying, so the prompt does not grow a paragraph
    /// explaining that the moderator has no character. Two sentences of nothing is worse than
    /// silence: it is tokens spent to say that there is nothing to say.
    public func briefing(mode: DiscussionMode) -> String? {
        let style = PersonaCatalog.style(id: personaID, mode: mode, seatIndex: 0)
        let hasStyle = !style.directive.isEmpty
        let named = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasStyle || (named != Self.defaultName && !named.isEmpty) else { return nil }

        let who = named.isEmpty ? Self.defaultName : named
        var text = "The moderator is \(who), a person rather than a participant."
        if hasStyle {
            text += " They approach the work as — \(style.name): \(style.directive)"
        }
        text += """
            \nTheir messages override everything else. Do not address them as a participant and \
            do not write their part.
            """
        return text
    }

    /// The speaker tag the human's own messages carry in the shared log.
    ///
    /// Falls back to the role when no name has been chosen, so a transcript from before this
    /// existed still reads the way it always did.
    public var speakerName: String {
        let named = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return named.isEmpty ? Self.defaultName : String(named.prefix(40))
    }
}
