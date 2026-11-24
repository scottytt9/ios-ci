import SwiftUI
import UIKit

@MainActor
struct ProfilePage: View {
    let store: HistoryStore
    @ObservedObject var connections: PlaybackConnections
    @Binding var showConnections: Bool
    @State private var code = ""
    @State private var message = ""
    @State private var busy = false
    @State private var name = ""
    @State private var bgColor = Color(red: 0.05, green: 0.06, blue: 0.07)
    @State private var accentColor = Color(red: 0.64, green: 0.91, blue: 0.81)
    @State private var qualityProfile = QualityProfile.current

    private static let quickBackdrops = ["#000000", "#0d1011", "#111728", "#1c1423", "#201512", "#081410", "#0f090b", "#1a202c", "#f5f1e8", "#faf8f5"]
    private static let quickAccents = ["#ecf841", "#a3e8ce", "#ff4560", "#f5c451", "#38bdf8", "#a855f7", "#fb7185", "#34d399", "#ffab79", "#f0f0f0", "#285b9c"]

    private var watchTimeLabel: String {
        let totalSeconds = store.entries.reduce(0.0) { $0 + max(0, $1.time) }
        let hours = Int(totalSeconds / 3600)
        return hours > 0 ? "\(hours)h" : "\(Int(totalSeconds / 60))m"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        statCard(value: "\(store.entries.filter(\.complete).count)", label: "Watched")
                        statCard(value: "\(store.list.count)", label: "My List")
                        statCard(value: watchTimeLabel, label: "Watch Time")
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    NavigationLink {
                        ConnectionsPage(connections: connections)
                    } label: {
                        LabeledContent("Connections", value: "\(connections.connected.count) of \(PlaybackService.allCases.count)")
                    }
                }

                Section("Playback Quality") {
                    Picker("Preferred quality", selection: $qualityProfile) {
                        ForEach(QualityProfile.allCases) { profile in
                            Text(profile.label).tag(profile)
                        }
                    }
                    .onChange(of: qualityProfile) { _, updated in
                        QualityProfile.current = updated
                    }
                    Text(qualityProfile.summary)
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Appearance") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(store.themes.available) { theme in
                                let selected = store.themes.active.id == theme.id
                                let bg = ProfileTheme.color(theme.background)
                                let ac = ProfileTheme.color(theme.accent)
                                Button {
                                    store.selectTheme(theme.id)
                                } label: {
                                    VStack(spacing: 7) {
                                        Circle()
                                            .fill(ac)
                                            .frame(width: 26, height: 26)
                                            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                                        Text(theme.name)
                                            .font(.caption.weight(selected ? .bold : .medium))
                                            .foregroundStyle(theme.scheme == .light ? Color.black : Color.white)
                                            .lineLimit(1)
                                    }
                                    .frame(width: 84, height: 74)
                                    .background(bg, in: .rect(cornerRadius: 14))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14)
                                            .stroke(selected ? Color.accentColor : Color.primary.opacity(0.18), lineWidth: selected ? 2.5 : 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))

                    DisclosureGroup("Create custom theme") {
                        TextField("Theme name", text: $name)
                        ColorPicker("Background", selection: $bgColor, supportsOpacity: false)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Self.quickBackdrops, id: \.self) { hex in
                                    Button { bgColor = ProfileTheme.color(hex) } label: {
                                        Circle().fill(ProfileTheme.color(hex))
                                            .frame(width: 22, height: 22)
                                            .overlay(Circle().stroke(.secondary.opacity(0.45), lineWidth: 1))
                                    }.buttonStyle(.plain)
                                }
                            }.padding(.vertical, 2)
                        }
                        ColorPicker("Accent", selection: $accentColor, supportsOpacity: false)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Self.quickAccents, id: \.self) { hex in
                                    Button { accentColor = ProfileTheme.color(hex) } label: {
                                        Circle().fill(ProfileTheme.color(hex))
                                            .frame(width: 22, height: 22)
                                            .overlay(Circle().stroke(.secondary.opacity(0.45), lineWidth: 1))
                                    }.buttonStyle(.plain)
                                }
                            }.padding(.vertical, 2)
                        }
                        Button("Save theme") {
                            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            let finalName = trimmed.isEmpty ? "Custom \(store.themes.available.count + 1)" : String(trimmed.prefix(48))
                            store.saveTheme(name: finalName, background: hexString(bgColor), accent: hexString(accentColor))
                            name = ""
                            message = "Saved \(finalName)."
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if store.themes.custom.contains(where: { $0.id == store.themes.active.id }) {
                        Button("Delete \"\(store.themes.active.name)\"", role: .destructive) {
                            let removed = store.themes.active.name
                            store.deleteTheme(store.themes.active.id)
                            message = "Deleted \(removed)."
                        }
                    }

                    if UIApplication.shared.supportsAlternateIcons {
                        Button("Match Home Screen icon") {
                            let icon = store.themes.active.icon
                            guard UIApplication.shared.alternateIconName != icon else { message = "Icon already matches the theme."; return }
                            UIApplication.shared.setAlternateIconName(icon) { error in
                                Task { @MainActor in message = error == nil ? "Home Screen icon updated." : "iOS couldn’t change the icon." }
                            }
                        }
                    }
                }.disabled(busy)

                Section("Transfer profile") {
                    Button("Copy profile code") {
                        let profile = store.profile
                        run {
                            let exported = try await Task.detached { try profile.encode() }.value
                            UIPasteboard.general.string = exported
                            message = "Profile code copied."
                        }
                    }
                    DisclosureGroup("Import profile code") {
                        TextEditor(text: $code).font(.caption.monospaced()).frame(minHeight: 64)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityLabel("Profile code")
                        Button("Import") {
                            let pasted = code
                            run {
                                let imported = try await Task.detached { try ProfileFile.decode(pasted) }.value
                                store.apply(imported)
                                code = ""
                                message = "Profile imported."
                            }
                        }.disabled(code.isEmpty)
                    }
                }.disabled(busy)

                if !message.isEmpty { Section { Text(message).font(.footnote) } }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showConnections) { ConnectionsPage(connections: connections) }
            .onAppear {
                connections.refresh()
                qualityProfile = QualityProfile.current
            }
        }
    }

    private func statCard(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.title2.bold()).foregroundStyle(Color.accentColor)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func hexString(_ color: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return "#101010" }
        return String(format: "#%02x%02x%02x",
                      Int(max(0, min(1, r)) * 255),
                      Int(max(0, min(1, g)) * 255),
                      Int(max(0, min(1, b)) * 255))
    }

    private func run(_ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        message = ""
        Task {
            defer { busy = false }
            do { try await work() }
            catch { message = error.localizedDescription }
        }
    }
}
