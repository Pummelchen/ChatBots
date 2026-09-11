// ChatBotsApp — who the human moderator is, as the room sees them
//
// The models have names and characters; the person commissioning the work and cutting in to
// redirect it arrived as "[Moderator]", which is a role rather than a person. This is where that
// person gets a name and, if they want one, a way of arguing — drawn from the same library the
// seats use, because a room where one participant's method is unstated is a room with a
// participant nobody can weigh.
//
// Deliberately small. The persona shapes how the human's interjections are *read*; it does not
// generate them, and there is no model behind it. Anything more would be putting words in the
// moderator's mouth.

import ChatBotsCore
import SwiftUI

struct ModeratorIdentitySheet: View {
    @EnvironmentObject private var zoom: ZoomStore
    @ObservedObject var controller: ChatController
    let dismiss: () -> Void

    @State private var name = ""
    @State private var personaID = PersonaLibrary.neutral.id

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            Text("Name")
                                .scaledFont(size: 11, weight: .semibold)
                            TextField("Moderator", text: $name)
                                .textFieldStyle(.roundedBorder)
                                .scaledFont(size: 12)
                                .frame(maxWidth: 240)
                        }
                        GridRow {
                            Text("Reads as")
                                .scaledFont(size: 11, weight: .semibold)
                            Picker("Reads as", selection: $personaID) {
                                Text("Neutral — no style imposed")
                                    .tag(PersonaLibrary.neutral.id)
                                ForEach(controller.availablePersonas, id: \.id) { persona in
                                    Text("\(persona.emoji) \(persona.name)")
                                        .tag(persona.id)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 300)
                        }
                    }

                    Text(
                        controller.mode == .research
                            ? "In a research session the analysts work for this person, so how they approach the work is told to the room. It never writes their messages."
                            : "The characters are told who is watching and how to read an interruption. It never writes the moderator's messages."
                    )
                    .scaledFont(size: 11)
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 520 * zoom.scale, height: 300 * zoom.scale)
        .onAppear {
            name = controller.lastSnapshot?.moderatorName ?? ModeratorIdentity.defaultName
            personaID = controller.moderatorPersonaID
        }
    }

    @Environment(\.themePalette) private var palette

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.wave.2.fill")
                .foregroundStyle(AgentTheme.moderatorTint(palette))
            VStack(alignment: .leading, spacing: 2) {
                Text("You")
                    .scaledFont(size: 13, weight: .semibold)
                Text("Your name and how your interjections read. Applies from the next turn.")
                    .scaledFont(size: 11)
                    .foregroundStyle(palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            // Changeable while a conversation runs, unlike the topic: who is speaking is not a
            // property of the question.
            Spacer(minLength: 0)
            Button("Cancel") { dismiss() }
            Button("Apply") {
                controller.setModerator(name: name, personaID: personaID)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }
}
