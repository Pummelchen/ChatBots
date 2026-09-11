// ChatBotsCore — the two discussion modes, and resolving a seat's persona for one of them
//
// The brief is explicit that the modes must not share a philosophy, and the code takes that
// literally: entertainment personas are *social characters* parameterised by temperament,
// research personas are *professional methods* parameterised by evidence standard. They are
// separate types with separate fields, not one type with a mode flag.
//
// What they have in common is what a seat actually needs at prompt time — an id, a name, a
// one-line summary and a directive — and that is `PersonaStyle`. Everything downstream (the
// prompt builder, the panes, the API, the CLI) works in that, so neither mode has to know
// about the other's shape.

import Foundation

/// Which kind of conversation this is.
///
/// Changing the mode changes what a persona *means*, so it is not a cosmetic setting: a seat
/// cannot keep its entertainment character while running a research session, because the two
/// are not interchangeable. Switching mode therefore reseats the persona, and the app does
/// that rather than leaving a seat holding an identifier from the other library.
public enum DiscussionMode: String, Sendable, Codable, CaseIterable, Identifiable {
    case entertainment
    case research

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .entertainment: "Reality Show"
        case .research: "Research Team"
        }
    }

    public var symbol: String {
        switch self {
        case .entertainment: "theatermasks.fill"
        case .research: "chart.bar.doc.horizontal"
        }
    }

    /// What this mode is for, for the mode picker.
    public var summary: String {
        switch self {
        case .entertainment:
            "Give several personalities a topic and watch them argue. No consensus required."
        case .research:
            "Specialists investigate a question from different methods and produce a conclusion you can use."
        }
    }

    /// Whether the conversation is meant to end.
    ///
    /// Entertainment has no end condition on purpose — the point is that it keeps going.
    /// Research must stop, because a report that never arrives is not a research session.
    public var runsUntilStopped: Bool { self == .entertainment }

    /// The default persona for a seat in this mode.
    public func defaultPersonaID(forSeat index: Int) -> String {
        switch self {
        case .entertainment:
            let featured = SocialLibrary.featured
            return featured[index % featured.count].id
        case .research:
            // The moderator opens, then two analysts with genuinely different methods, then
            // a challenger — which is the shape of a real investigation rather than a panel.
            let lineUp = AnalystLibrary.startingLineUp
            return lineUp[index % lineUp.count].id
        }
    }

    /// Whether a stored persona identifier belongs to this mode's library.
    public func owns(personaID: String) -> Bool {
        PersonaCatalog.styles(for: self).contains { $0.id == personaID }
    }
}

/// What a seat needs to know about its persona, whichever mode produced it.
public struct PersonaStyle: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var emoji: String
    public var summary: String
    /// The full text handed to the model.
    public var directive: String
    /// The group this persona belongs to, for the picker.
    public var group: String
    /// True for the analytical roles, so a pane can show which mode it is speaking in.
    public var isAnalyst: Bool

    public init(
        id: String,
        name: String,
        emoji: String = "",
        summary: String,
        directive: String,
        group: String = "",
        isAnalyst: Bool = false
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.summary = summary
        self.directive = directive
        self.group = group
        self.isAnalyst = isAnalyst
    }

    /// Build from an entertainment character.
    public init(social: SocialCharacter) {
        self.init(
            id: social.id, name: social.name, emoji: social.emoji, summary: social.summary,
            directive: social.directive, group: social.group.rawValue)
    }

    /// Build from an analytical role.
    public init(analyst: AnalystRole) {
        self.init(
            id: analyst.id, name: analyst.name, emoji: analyst.emoji, summary: analyst.summary,
            directive: analyst.directive, group: analyst.group.rawValue, isAnalyst: true)
    }
}

/// Everything a picker needs to offer, in one list, for whichever mode is active.
public enum PersonaCatalog {

    public static func styles(for mode: DiscussionMode) -> [PersonaStyle] {
        // The original 27 styles are offered in *both* modes. They are communication styles
        // rather than characters or job roles, so they are useful either way — and one of
        // them, `neutral`, means "no style at all", which every mode needs. Keeping them
        // available also means a configuration saved before the modes existed still
        // resolves instead of silently becoming something else.
        let shared = PersonaLibrary.all.map {
            PersonaStyle(
                id: $0.id, name: $0.name, summary: $0.summary, directive: $0.directive,
                group: $0.category.rawValue)
        }
        switch mode {
        case .entertainment:
            return SocialLibrary.all.map(PersonaStyle.init(social:)) + shared
        case .research:
            return AnalystLibrary.all.map(PersonaStyle.init(analyst:)) + shared
        }
    }

    /// Resolve an identifier for a mode, falling back rather than failing.
    ///
    /// A stored identifier from the other library — which happens the moment the mode is
    /// switched — resolves to this mode's default for that seat rather than to an empty
    /// directive. That is why seats carry a *persona* and not a bare string.
    public static func style(id: String, mode: DiscussionMode, seatIndex: Int = 0) -> PersonaStyle {
        if let match = styles(for: mode).first(where: { $0.id == id }) { return match }
        return style(defaultFor: mode, seatIndex: seatIndex)
    }

    public static func style(defaultFor mode: DiscussionMode, seatIndex: Int) -> PersonaStyle {
        let identifier = mode.defaultPersonaID(forSeat: seatIndex)
        if let match = styles(for: mode).first(where: { $0.id == identifier }) { return match }
        // Unreachable unless a library is emptied, but a prompt must never be built from a
        // missing persona.
        return PersonaStyle(
            id: identifier, name: identifier, summary: "A participant.",
            directive: "Be yourself.", group: "", isAnalyst: mode == .research)
    }
}
