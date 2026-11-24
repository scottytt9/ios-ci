import SwiftUI

enum PlaybackService: String, CaseIterable, Identifiable {
    case tmdb, torbox, addon
    var id: Self { self }

    var account: String {
        switch self {
        case .tmdb: Catalogue.account
        case .torbox: "TorBox"
        case .addon: TorrentSources.account
        }
    }

    var title: String {
        self == .tmdb ? "The Movie Database" : account
    }

    var prompt: String {
        switch self {
        case .tmdb: "API key or read access token"
        case .torbox: "TorBox API key"
        case .addon: "Stream add-on manifest URL"
        }
    }

    var icon: String {
        switch self {
        case .tmdb: "film.stack"
        case .torbox: "tray.full"
        case .addon: "link"
        }
    }
}

@MainActor
final class PlaybackConnections: ObservableObject {
    @Published private(set) var connected = Set<PlaybackService>()
    @Published private(set) var revisions: [PlaybackService: Int] = [:]
    var complete: Bool { connected.count == PlaybackService.allCases.count }

    init() { refresh() }

    func refresh() {
        let saved = Set(PlaybackService.allCases.filter { TorBox.key(account: $0.account) != nil })
        if connected != saved { connected = saved }
    }

    func connect(_ service: PlaybackService, input: String) async throws {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 2048, !value.contains(where: \.isWhitespace) else {
            throw LibraryError.responseHint(service.prompt)
        }
        switch service {
        case .tmdb:
            try await Catalogue.connect(value)
        case .torbox:
            let data = try await TorBox.request("/user/me", key: value)
            let _: [String: Any] = try TorBox.payload(data)
            try TorBox.save(value)
            SourceVideo.forgetAssociations()
        case .addon:
            try await TorrentSources.connect(value)
        }
        revisions[service, default: 0] += 1
        refresh()
    }

    func disconnect(_ service: PlaybackService) {
        TorBox.remove(account: service.account)
        if service == .torbox { SourceVideo.forgetAssociations() }
        revisions[service, default: 0] += 1
        refresh()
    }
}

@MainActor
struct ConnectionsPage: View {
    @ObservedObject var connections: PlaybackConnections
    var finishSetup: (() -> Void)? = nil
    @State private var entries: [PlaybackService: String] = [:]
    @State private var errors: [PlaybackService: String] = [:]
    @State private var pending: PlaybackService?
    @State private var editing = Set<PlaybackService>()

    var body: some View {
        Form {
            if finishSetup != nil {
                Section {
                    Text("Connect your catalogue, playback account, and stream search to get started.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(PlaybackService.allCases) { service in
                Section {
                    let connected = connections.connected.contains(service)
                    if connected && !editing.contains(service) {
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                        Button("Replace") { editing.insert(service) }.disabled(pending != nil)
                        if finishSetup == nil {
                            Button("Disconnect", role: .destructive) { connections.disconnect(service) }.disabled(pending != nil)
                        }
                    } else {
                        SecureField(service.prompt, text: Binding(get: { entries[service, default: ""] }, set: { entries[service] = $0 }))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .disabled(pending == service)
                        Button(connected ? "Save replacement" : "Connect") { connect(service) }
                            .disabled(pending != nil || entries[service, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if connected { Button("Cancel") { editing.remove(service); entries[service] = ""; errors[service] = nil }.disabled(pending != nil) }
                        if pending == service { ProgressView() }
                    }
                    if let error = errors[service] { Text(error).foregroundStyle(.orange).font(.footnote) }
                    if service == .tmdb { Link("Get a TMDB key", destination: URL(string: "https://www.themoviedb.org/settings/api")!) }
                    if service == .torbox { Link("Find your TorBox key", destination: URL(string: "https://torbox.app/settings")!) }
                } header: { Label(service.title, systemImage: service.icon) }
            }
            if let finishSetup {
                Section {
                    if connections.complete {
                        Button("Go to Discover", action: finishSetup).disabled(pending != nil)
                    } else {
                        Button("Set up later", action: finishSetup).disabled(pending != nil)
                    }
                }
            }
        }
        .navigationTitle(finishSetup == nil ? "Connections" : "Set up Interlude")
    }

    private func connect(_ service: PlaybackService) {
        let input = entries[service, default: ""]
        pending = service
        errors[service] = nil
        Task {
            defer { pending = nil }
            do {
                try await connections.connect(service, input: input)
                entries[service] = ""
                editing.remove(service)
            } catch {
                errors[service] = error.localizedDescription
            }
        }
    }
}
