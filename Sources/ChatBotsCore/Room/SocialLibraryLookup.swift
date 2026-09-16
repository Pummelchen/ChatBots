// ChatBotsCore — choosing one of the entertainment characters
//
// Split out of `SocialLibrary.swift`, which held the 36 character definitions and the rules for
// choosing among them in one 515-line file. The characters did not change; only the lookups moved.

import Foundation

extension SocialLibrary {

    /// The 36 shipping characters, in picker order.
    public static let all: [SocialCharacter] = [
        // Conflict & drama
        alpha, villain, contrarian, hothead, schemer, manipulator, diva, instigator, jealous, grudge,
        // Relationships
        flirt, romantic, heartbreaker, jealousLover, bestFriend, gossip, peacemaker, fakeNice,
        // Intellectual
        scientist, philosopher, lawyer, factChecker, skeptic, conspiracy, pragmatist, idealist,
        // Humour
        comedian, troll, chaos, storyteller, deadpan,
        // Competition & ambition
        underdog, perfectionist, hustler, survivor, overachiever,
    ]

    public static func character(id: String) -> SocialCharacter {
        all.first { $0.id == id } ?? alpha
    }

    /// The line-up shown in the picker, which is what the brief's mock-up asks for.
    public static let featured: [SocialCharacter] = [
        alpha, scientist, troll, romantic, skeptic, schemer, conspiracy, hustler,
    ]
}
