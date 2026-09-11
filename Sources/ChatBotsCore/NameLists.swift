// ChatBotsCore — the names participants are given at startup
//
// Generated from `names/` by `tools/embed-names.py`; edit the text files there, not here.
// Six languages, each with a female and a male list.
//
// Kept as text rather than as Swift literals so the lists can be edited and reviewed like
// data, which is what they are. The generated file is checked in so the build needs no extra
// step, and `tools/embed-names.py --check` catches the two drifting apart.

import Foundation

/// A language the app can draw names from.
public enum NameLanguage: String, Sendable, Codable, CaseIterable, Identifiable {
    case english
    case french
    case german
    case spanish
    case brazilianPortuguese
    case italian

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .english: "English"
        case .french: "French"
        case .german: "German"
        case .spanish: "Spanish (Latino)"
        case .brazilianPortuguese: "Brazilian Portuguese"
        case .italian: "Italian"
        }
    }

    /// The female and male names this language offers.
    var names: NameList {
        switch self {
        case .english:
            NameList(female: ["Alice", "Clara", "Diana", "Eleanor", "Fiona", "Grace", "Hannah", "Iris", "Julia", "Katherine", "Laura", "Maya", "Nora", "Olivia", "Phoebe", "Rachel", "Rose", "Sophie", "Tessa", "Vivian"],
                     male: ["Adam", "Benjamin", "Charles", "Daniel", "Edward", "Felix", "George", "Henry", "Isaac", "James", "Leo", "Marcus", "Nathan", "Oliver", "Peter", "Robert", "Samuel", "Thomas", "Victor", "William"])
        case .french:
            NameList(female: ["Amélie", "Camille", "Chloé", "Claire", "Élodie", "Émilie", "Juliette", "Léa", "Madeleine", "Manon", "Margaux", "Mathilde", "Noémie", "Océane", "Pauline", "Sabine", "Sophie", "Valérie", "Véronique", "Zoé"],
                     male: ["Antoine", "Bastien", "Benoît", "Clément", "Étienne", "Guillaume", "Henri", "Julien", "Laurent", "Lucas", "Mathieu", "Nicolas", "Olivier", "Philippe", "Rémi", "Sébastien", "Théo", "Thierry", "Vincent", "Xavier"])
        case .german:
            NameList(female: ["Anneliese", "Birgit", "Claudia", "Elke", "Franziska", "Greta", "Hannelore", "Ilse", "Johanna", "Katrin", "Lena", "Marlene", "Monika", "Petra", "Renate", "Sabine", "Stefanie", "Susanne", "Ursula", "Wiebke"],
                     male: ["Andreas", "Bernd", "Christoph", "Dieter", "Florian", "Gregor", "Hans", "Jürgen", "Klaus", "Lukas", "Manfred", "Matthias", "Niklas", "Otto", "Rainer", "Sebastian", "Thomas", "Ulrich", "Wolfgang", "Volker"])
        case .spanish:
            NameList(female: ["Alejandra", "Beatriz", "Camila", "Carolina", "Daniela", "Elena", "Esperanza", "Gabriela", "Isabel", "Jimena", "Lucía", "Mariana", "Mercedes", "Paloma", "Pilar", "Renata", "Rosario", "Sofía", "Valentina", "Ximena"],
                     male: ["Alejandro", "Andrés", "Bernardo", "Carlos", "Diego", "Eduardo", "Emilio", "Esteban", "Federico", "Gonzalo", "Ignacio", "Javier", "Joaquín", "Leonardo", "Mateo", "Nicolás", "Rafael", "Rodrigo", "Santiago", "Tomás"])
        case .brazilianPortuguese:
            NameList(female: ["Adriana", "Ana Clara", "Beatriz", "Bruna", "Camila", "Cláudia", "Elaine", "Fernanda", "Gabriela", "Helena", "Isabela", "Juliana", "Larissa", "Letícia", "Luana", "Mariana", "Patrícia", "Renata", "Tatiana", "Vitória"],
                     male: ["Alexandre", "André", "Bruno", "Caio", "Carlos Eduardo", "Daniel", "Eduardo", "Felipe", "Gabriel", "Gustavo", "Henrique", "João Pedro", "Lucas", "Marcelo", "Mateus", "Rafael", "Ricardo", "Rodrigo", "Thiago", "Vinícius"])
        case .italian:
            NameList(female: ["Alessandra", "Beatrice", "Camilla", "Chiara", "Eleonora", "Federica", "Francesca", "Giovanna", "Giulia", "Ilaria", "Lucia", "Marta", "Michela", "Paola", "Raffaella", "Serena", "Silvia", "Valentina", "Vittoria", "Ylenia"],
                     male: ["Alessandro", "Andrea", "Carlo", "Daniele", "Enrico", "Fabio", "Federico", "Giovanni", "Giuseppe", "Leonardo", "Lorenzo", "Marco", "Massimo", "Matteo", "Nicola", "Paolo", "Riccardo", "Simone", "Stefano", "Tommaso"])
        }
    }
}

/// One language's names, split by gender.
public struct NameList: Sendable, Hashable {
    public var female: [String]
    public var male: [String]

    public init(female: [String], male: [String]) {
        self.female = female
        self.male = male
    }

    public func names(for gender: Gender) -> [String] {
        switch gender {
        case .female: female
        case .male: male
        }
    }
}

/// The names the participants are given at startup.
public enum NameLists {

    /// Every language, in the order they are declared.
    public static var all: [NameLanguage] { NameLanguage.allCases }

    public static func list(for language: NameLanguage) -> NameList { language.names }

    /// A name at random from one language.
    ///
    /// Random on purpose: two runs of the app should not open with the same pair of
    /// participants, which is the point of the exercise. The choice is saved with the rest of
    /// the settings, so a name does not change under a conversation that is already running.
    public static func random(
        _ gender: Gender, language: NameLanguage, using generator: inout some RandomNumberGenerator
    ) -> String {
        let names = list(for: language).names(for: gender)
        guard !names.isEmpty else { return "Agent" }
        return names[Int.random(in: 0..<names.count, using: &generator)]
    }

    /// A name drawn from any language, which is what the app uses.
    ///
    /// Deliberately not matching a language to a locale: a German name is a perfectly good
    /// name for a participant in an English conversation, and mixing them is more interesting
    /// than always drawing from one list.
    public static func random(
        _ gender: Gender, using generator: inout some RandomNumberGenerator
    ) -> String {
        random(gender, language: all.randomElement(using: &generator) ?? .english,
               using: &generator)
    }
}

/// Which list a name is drawn from.
public enum Gender: String, Sendable, Codable, CaseIterable, Identifiable {
    case female
    case male

    public var id: String { rawValue }
}
