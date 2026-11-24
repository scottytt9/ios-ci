import SwiftUI
import UIKit

@MainActor
struct PlayerSettings: View {
    @Bindable var playback: Playback
    let room: WatchRoom
    let watchTogether: () -> Void
    let playNext: () -> Void
    let importCaptions: () -> Void
    let sources: () -> Void
    let startsInSubtitles: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if startsInSubtitles {
                subtitleTracks.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            } else {
            List {
                Section("Playback") {
                    Button("Playback sources", systemImage: "tray.full", action: sources)
                    if !room.connected {
                        NavigationLink {
                            speeds
                        } label: {
                            HStack {
                                Text("Playback speed")
                                Spacer()
                                Text(playback.speed == 1 ? "Normal" : playback.speed.formatted() + "×")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Toggle("Fill screen (zoom)", isOn: Binding(get: { playback.videoFill }, set: { playback.toggleVideoFill($0) }))
                    if playback.nextEpisode != nil && (!room.connected || room.hosts) {
                        Button("Next episode", systemImage: "forward.end", action: playNext)
                    }
                    if !playback.chapters.isEmpty {
                        NavigationLink {
                            List(playback.chapters) { chapter in
                                Button(chapter.title) { playback.action("seek", time: chapter.start); dismiss() }
                            }.navigationTitle("Chapters")
                        } label: {
                            HStack {
                                Text("Chapters")
                                Spacer()
                                Text("\(playback.chapters.count)").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Audio & Subtitles") {
                    NavigationLink {
                        subtitleTracks
                    } label: {
                        HStack {
                            Text("Subtitles")
                            Spacer()
                            Text(activeSubtitleSummary).foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink {
                        audioTracks
                    } label: {
                        HStack {
                            Text("Audio & dialogue")
                            Spacer()
                            if playback.enhanceDialogue {
                                Text("Dialogue boost").foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button {
                        _ = playback.whatDidTheySay()
                        dismiss()
                    } label: {
                        Label("What did they say? (−10s + CC)", systemImage: "text.bubble")
                    }
                }
                Section("Tools & Automation") {
                    Button("Watch Together", systemImage: "person.2", action: watchTogether)
                    NavigationLink {
                        sleepTimerSettings
                    } label: {
                        HStack {
                            Text("Sleep timer")
                            Spacer()
                            if playback.sleepOption != .off {
                                Text(playback.sleepRemainingLabel ?? playback.sleepOption.title)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Off").foregroundStyle(.secondary)
                            }
                        }
                    }
                    NavigationLink("Playback automation") {
                        Form {
                            Toggle("Autoplay the next episode", isOn: $playback.autoNext)
                            Toggle("Skip intros automatically", isOn: $playback.autoSkipIntro)
                            Toggle("Use IntroDB timings", isOn: Binding(get: { playback.communityTimings }, set: playback.updateCommunityTimings))
                        }.navigationTitle("Playback automation")
                    }
                }
                Section("Audio output") { AudioRoutePicker().frame(height: 34) }
            }
            .navigationTitle("Playback settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var activeSubtitleSummary: String {
        if let imported = playback.importedCaptionName { return imported }
        if playback.compatibility != nil {
            return playback.compatibilityCaptions.first { $0.id == playback.compatibilityCaptionID }?.name ?? "Off"
        }
        return playback.selectedCaption?.displayName ?? "Off"
    }

    private var speeds: some View {
        List([Float(0.5), 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { value in
            Button { playback.setSpeed(value) } label: {
                choice(value == 1 ? "Normal" : value.formatted() + "×", selected: playback.speed == value)
            }
        }.navigationTitle("Speed")
    }

    private var subtitleTracks: some View {
        List {
            if playback.compatibility != nil {
                Button { playback.selectCompatibilityCaption(-1) } label: {
                    choice("Off", selected: playback.compatibilityCaptionID < 0 && playback.importedCaptionName == nil)
                }
                ForEach(playback.compatibilityCaptions) { track in
                    Button { playback.selectCompatibilityCaption(track.id) } label: {
                        choice(track.name, selected: playback.compatibilityCaptionID == track.id)
                    }
                }
            } else {
                Button { playback.selectCaption(nil) } label: {
                    choice("Off", selected: playback.selectedCaption == nil && playback.importedCaptionName == nil)
                }
                ForEach(playback.captions, id: \.self) { track in
                    Button { playback.selectCaption(track) } label: { choice(track.displayName, selected: playback.selectedCaption == track) }
                }
            }
            if let imported = playback.importedCaptionName { choice(imported, selected: true) }
            NavigationLink {
                OnlineSubtitlePicker(playback: playback)
            } label: {
                Label("Search OpenSubtitles online", systemImage: "globe")
            }
            Button("Import SRT or WebVTT", systemImage: "folder", action: importCaptions)
            NavigationLink("Subtitle appearance") { captionStyle }
            if playback.importedCaptionName != nil || playback.compatibilityCaptionID >= 0 {
                Section("Timing") {
                    offsetSlider
                    Button("Reset timing") { playback.setCaptionOffset(0) }
                }
            }
        }.navigationTitle("Subtitles")
    }

    private var captionStyle: some View {
        let style = playback.captionStyle
        return Form {
            VideoCaptionLayer(text: "Subtitle preview", style: style)
                .frame(height: 100).background(.black, in: RoundedRectangle(cornerRadius: 10))
                .listRowInsets(EdgeInsets())
            Picker("Font", selection: setting(\.font)) {
                Text("Sans").tag("sans"); Text("Serif").tag("serif"); Text("Monospace").tag("mono")
            }
            styledSlider("Font size", \.size, range: 14...52, step: 1, suffix: " px")
            styledSlider("Background opacity", \.opacity, range: 0...100, step: 1, suffix: "%")
            styledSlider("Outline", \.outline, range: 0...5, step: 0.25, suffix: " px")
            styledSlider("Shadow", \.shadow, range: 0...8, step: 0.5, suffix: " px")
            styledSlider("Position from bottom", \.bottom, range: 0...30, step: 1, suffix: "%")
            ColorPicker("Text color", selection: Binding(get: { ProfileTheme.color(style.color) }, set: { color in
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                if UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
                    var updated = playback.captionStyle
                    updated.color = String(format: "#%02X%02X%02X", Int(red.clamped * 255), Int(green.clamped * 255), Int(blue.clamped * 255))
                    playback.setCaptionStyle(updated)
                }
            }), supportsOpacity: false)
            Button("Reset style") { playback.setCaptionStyle(CaptionStyle()) }
            Text("Applies to imported subtitles.")
                .font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("Subtitle style")
    }

    private var audioTracks: some View {
        List {
            Section(playback.compatibility != nil ? "Video volume & boost (\(Int((playback.filmVolume * 100).rounded()))%)" : "Video volume") {
                Slider(value: Binding(get: { playback.filmVolume }, set: playback.setVolume),
                       in: 0...(playback.compatibility != nil ? 2 : 1)) { Text("Video volume") }
                Toggle("Enhance dialogue clarity", isOn: Binding(get: { playback.enhanceDialogue }, set: { playback.setEnhanceDialogue($0) }))
            }
            Section("Audio tracks") {
                if playback.compatibility != nil {
                    if playback.compatibilityAudio.isEmpty { Text("Default audio track").foregroundStyle(.secondary) }
                    ForEach(playback.compatibilityAudio) { track in
                        Button { playback.selectCompatibilityAudio(track.id) } label: {
                            choice(track.name, selected: playback.compatibilityAudioID == track.id)
                        }
                    }
                } else {
                    if playback.audioTracks.isEmpty { Text("Default audio track").foregroundStyle(.secondary) }
                    ForEach(playback.audioTracks, id: \.self) { track in
                        Button { playback.selectAudio(track) } label: { choice(track.displayName, selected: playback.selectedAudio == track) }
                    }
                }
            }
        }.navigationTitle("Audio")
    }

    private var offsetSlider: some View {
        VStack(alignment: .leading) {
            Text("Sync offset \(playback.captionOffset.formatted(.number.precision(.fractionLength(2)))) s")
            Slider(value: Binding(get: { playback.captionOffset }, set: playback.setCaptionOffset), in: -60...60, step: 0.1) {
                Text("Sync offset")
            }
        }
    }

    private func setting<T>(_ key: WritableKeyPath<CaptionStyle, T>) -> Binding<T> {
        Binding(get: { playback.captionStyle[keyPath: key] }, set: { value in
            var style = playback.captionStyle
            style[keyPath: key] = value
            playback.setCaptionStyle(style)
        })
    }

    private func styledSlider(_ label: String, _ key: WritableKeyPath<CaptionStyle, Double>, range: ClosedRange<Double>, step: Double, suffix: String) -> some View {
        VStack(alignment: .leading) {
            Text(label + " · " + playback.captionStyle[keyPath: key].formatted() + suffix)
            Slider(value: setting(key), in: range, step: step) { Text(label) }
        }
    }

    private func choice(_ title: String, selected: Bool) -> some View {
        HStack { Text(title); Spacer(); if selected { Image(systemName: "checkmark").accessibilityHidden(true) } }
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var sleepTimerSettings: some View {
        List {
            ForEach(SleepTimerOption.allCases) { option in
                Button {
                    playback.setSleepTimer(option)
                    dismiss()
                } label: {
                    choice(option.title, selected: playback.sleepOption == option)
                }
            }
        }
        .navigationTitle("Sleep timer")
    }
}

@MainActor
private struct OnlineSubtitlePicker: View {
    let playback: Playback
    @Environment(\.dismiss) private var dismiss
    @State private var tracks: [OnlineSubtitle] = []
    @State private var loading = true
    @State private var downloadingID: String?
    @State private var error = ""

    var body: some View {
        List {
            if loading {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Searching OpenSubtitles…").foregroundStyle(.secondary)
                }
            } else if !error.isEmpty {
                Section {
                    Text(error).foregroundStyle(.orange)
                    Button("Try again") { Task { await search() } }
                }
            } else if tracks.isEmpty {
                ContentUnavailableView("No online subtitles", systemImage: "captions.bubble",
                                       description: Text("No OpenSubtitles tracks matched this title."))
            } else {
                ForEach(tracks) { track in
                    Button {
                        Task { await apply(track) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.label).font(.body.weight(.medium))
                                Text(track.lang.uppercased()).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if downloadingID == track.id { ProgressView() }
                        }
                    }
                    .disabled(downloadingID != nil)
                }
            }
        }
        .navigationTitle("Online subtitles")
        .task { await search() }
    }

    private func search() async {
        loading = true
        error = ""
        do {
            tracks = try await OnlineSubtitles.lookup(for: playback.selection)
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func apply(_ track: OnlineSubtitle) async {
        downloadingID = track.id
        error = ""
        do {
            let body = try await OnlineSubtitles.download(track.url)
            try await playback.loadExternalCaptions(name: track.label, text: body)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        downloadingID = nil
    }
}

private extension CGFloat {
    var clamped: CGFloat { Swift.min(1, Swift.max(0, self)) }
}

struct VideoCaptionLayer: View {
    let text: String
    let style: CaptionStyle

    var body: some View {
        GeometryReader { geometry in
            if !text.isEmpty {
                let design: Font.Design = style.font == "serif" ? .serif : style.font == "mono" ? .monospaced : .default
                let label = Text(verbatim: text).font(.system(size: style.size, weight: .semibold, design: design)).multilineTextAlignment(.center)
                VStack {
                    Spacer(minLength: 0)
                    ZStack {
                        if style.outline > 0 {
                            ForEach(0..<8) { index in
                                let angle = Double(index) * Double.pi / 4
                                label.foregroundStyle(.black).offset(x: cos(angle) * style.outline, y: sin(angle) * style.outline)
                            }
                        }
                        label.foregroundStyle(ProfileTheme.color(style.color))
                    }
                    .shadow(color: .black, radius: style.shadow, x: 1, y: 1)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(style.opacity / 100), in: RoundedRectangle(cornerRadius: 3))
                    .frame(maxWidth: geometry.size.width * 0.9)
                    .padding(.bottom, geometry.size.height * style.bottom / 100)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
