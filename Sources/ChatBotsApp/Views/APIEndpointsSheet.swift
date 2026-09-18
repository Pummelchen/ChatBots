// ChatBotsApp — configuring an OpenAI-compatible endpoint
//
// One sheet for all seats, because the common case is "point both at the same server" and
// the less common one is per-seat URLs. Edits apply to the next turn, so this can be
// opened mid-conversation without disturbing it.

import ChatBotsCore
import SwiftUI

struct APIEndpointsSheet: View {
    @EnvironmentObject private var zoom: ZoomStore
    @EnvironmentObject private var store: APIEndpointStore
    @ObservedObject var controller: ChatController
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(0..<APIEndpointStore.seatCount, id: \.self) { seat in
                        if seat < controller.panes.count {
                            seatForm(seat)
                        }
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 560 * zoom.scale, height: 560 * zoom.scale)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "network")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("OpenAI-compatible endpoints")
                    .scaledFont(size: 13, weight: .semibold)
                Text("Any /v1 URL: a local server, or a cloud provider. Applied from each seat's next turn.")
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    // MARK: Seat form

    private func seatForm(_ seat: Int) -> some View {
        let pane = controller.panes[seat]
        let usesAPI = store.isAPI(pane.spec)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: AgentTheme.symbol(forSeat: seat))
                    .foregroundStyle(AgentTheme.tint(forSeat: seat, palette: .original))
                Text(pane.spec.displayName)
                    .scaledFont(size: 12, weight: .semibold, design: .rounded)
                Spacer(minLength: 0)
                Toggle("Use API", isOn: useAPIBinding(seat))
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("URL").scaledFont(size: 11).foregroundStyle(.secondary)
                    TextField("https://api.openai.com or http://localhost:1234",
                              text: baseURLBinding(seat))
                        .textFieldStyle(.roundedBorder)
                        .scaledFont(size: 11.5, design: .monospaced)
                }
                GridRow {
                    Text("Model").scaledFont(size: 11).foregroundStyle(.secondary)
                    TextField("gpt-4o-mini, gpt-5, qwen35 …", text: modelBinding(seat))
                        .textFieldStyle(.roundedBorder)
                        .scaledFont(size: 11.5, design: .monospaced)
                }
                GridRow {
                    Text("API key").scaledFont(size: 11).foregroundStyle(.secondary)
                    SecureField(store.keys[seat].isEmpty ? "not needed for a local server" : "",
                                text: keyBinding(seat))
                        .textFieldStyle(.roundedBorder)
                        .scaledFont(size: 11.5, design: .monospaced)
                }
                if let keyError = store.keyStoreError {
                    GridRow {
                        Text("").scaledFont(size: 11)
                        Text(keyError).scaledFont(size: 11).foregroundStyle(.orange)
                    }
                }
                GridRow {
                    Text("Parameters").scaledFont(size: 11).foregroundStyle(.secondary)
                    Picker("", selection: compatibilityBinding(seat)) {
                        ForEach(APICompatibility.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }
            .disabled(!usesAPI)
            .opacity(usesAPI ? 1 : 0.45)

            HStack(spacing: 10) {
                Text(store.endpoint(forSeat: seat).responsesURL?.absoluteString ?? "no URL yet")
                    .scaledFont(size: 10, design: .monospaced)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if seat > 0 {
                    Button("Copy seat 1") { store.mirrorSeat(0) }
                        .buttonStyle(.link)
                        .scaledFont(size: 10)
                }
            }

            if pane.spec.webSearchEnabled, usesAPI {
                Label(
                    "Web tools are unavailable on the API backend",
                    systemImage: "exclamationmark.triangle")
                    .scaledFont(size: 10.5)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Keys are stored in the macOS Keychain. \(APIEndpointStore.apiKeyEnvironmentKey) overrides them.")
                .scaledFont(size: 10)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    // MARK: Bindings

    private func useAPIBinding(_ seat: Int) -> Binding<Bool> {
        Binding(
            get: { controller.panes.indices.contains(seat)
                && store.isAPI(controller.panes[seat].spec) },
            set: { useAPI in
                let backend: AgentSpec.Backend = useAPI ? .openAIResponses : .mlx
                controller.setBackend(backend, for: controller.panes[seat].id)
                controller.applyAPIEndpoints(store)
            })
    }

    private func baseURLBinding(_ seat: Int) -> Binding<String> {
        Binding(
            get: { store.endpoints.indices.contains(seat) ? store.endpoints[seat].baseURL : "" },
            set: {
                store.setBaseURL($0, seat: seat)
                controller.applyAPIEndpoints(store)
            })
    }

    private func modelBinding(_ seat: Int) -> Binding<String> {
        Binding(
            get: { store.endpoints.indices.contains(seat) ? store.endpoints[seat].model : "" },
            set: {
                store.setModel($0, seat: seat)
                controller.applyAPIEndpoints(store)
            })
    }

    private func keyBinding(_ seat: Int) -> Binding<String> {
        Binding(
            get: { store.keys.indices.contains(seat) ? store.keys[seat] : "" },
            set: {
                store.setKey($0, seat: seat)
                controller.applyAPIEndpoints(store)
            })
    }

    private func compatibilityBinding(_ seat: Int) -> Binding<APICompatibility> {
        Binding(
            get: {
                store.endpoints.indices.contains(seat) ? store.endpoints[seat].compatibility : .extended
            },
            set: {
                store.setCompatibility($0, seat: seat)
                controller.applyAPIEndpoints(store)
            })
    }
}
