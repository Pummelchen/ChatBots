// ChatBotsCLI — the catalogues the listing flags print and exit on
//
// `--list-models` and `--list-personas` are answered during parsing, and `--list-characters` and
// `--list-roles` after the engines exist; all four are printing rather than conversation, so they
// live together here instead of in the parser and the entry point.

import ChatBotsCore

enum Listings {

    /// `--list-models`: the checkpoints this app offers, with the aliases that resolve to them.
    static func printModels() {
        for choice in ModelCatalog.choices {
            let size = choice.sizeLabel.map { "  (\($0))" } ?? ""
            print("\(choice.name)\(size)")
            print("  \(choice.id)")
            print("  \(choice.summary)")
            print("  aliases: \(choice.aliases.joined(separator: ", "))")
        }
    }

    /// `--list-personas`: the shared styles both modes draw on, grouped by category.
    static func printPersonas() {
        for category in Persona.Category.allCases {
            print("\(category.rawValue):")
            for persona in PersonaLibrary.personas(in: category) {
                print("  \(persona.id.padding(toLength: 18, withPad: " ", startingAt: 0)) \(persona.summary)")
            }
        }
    }

    /// `--list-characters`: the entertainment cast, so the pickers are discoverable from a terminal.
    static func printCharacters() {
        print("Entertainment cast — \(SocialLibrary.all.count) characters\n")
        for group in SocialCharacter.Group.allCases {
            print("\(group.rawValue):")
            for character in SocialLibrary.all where character.group == group {
                print(
                    "  \(character.emoji) \(character.name.padding(toLength: 24, withPad: " ", startingAt: 0)) "
                        + "\(character.summary)"
                )
            }
            print("")
        }
        print("Shared styles are also available in both modes: see --list-personas")
    }

    /// `--list-roles`: the research analysts, and the line-up a conversation starts from.
    static func printRoles() {
        print("Research analysts — \(AnalystLibrary.all.count) roles\n")
        for group in AnalystRole.Group.allCases {
            print("\(group.rawValue):")
            for role in AnalystLibrary.all where role.group == group {
                print("  \(role.emoji) \(role.name.padding(toLength: 28, withPad: " ", startingAt: 0)) \(role.summary)")
            }
            print("")
        }
        print("Default line-up: " + AnalystLibrary.startingLineUp.map(\.name).joined(separator: ", "))
    }
}
