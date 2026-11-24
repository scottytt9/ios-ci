import SwiftUI

@MainActor
struct ContinueWatchingShelf: View {
    let history: HistoryStore
    let play: (HistoryEntry.Playback) -> Void
    @ScaledMetric(relativeTo: .body) private var cardWidth = 232.0

    var body: some View {
        let entries = history.entries.filter { !$0.complete && $0.time > 0 && $0.duration > $0.time }
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Continue Watching").font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(entries) { entry in
                            Button { play(entry.playback) } label: { card(entry) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Resume", systemImage: "play.fill") { play(entry.playback) }
                                    Button("Mark watched", systemImage: "checkmark.circle") {
                                        history.setWatched(entry.playback, complete: true)
                                    }
                                    Button("Remove", systemImage: "trash", role: .destructive) {
                                        history.remove(entry)
                                    }
                                }
                                .accessibilityLabel("Resume \(entry.playback.media.title)")
                                .accessibilityValue([entry.playback.label, remaining(entry)].compactMap { $0 }.joined(separator: ", "))
                        }
                    }.scrollTargetLayout()
                }
                .contentMargins(.horizontal, 16, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
            }
        }
    }

    private func card(_ entry: HistoryEntry) -> some View {
        let media = entry.playback.media
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                CatalogueImage(media.backdrop ?? media.poster)
                LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .center, endPoint: .bottom)
                Image(systemName: "play.fill").font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.72), in: .circle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(12)
                GeometryReader { bounds in
                    Capsule().fill(.white.opacity(0.35))
                        .overlay(alignment: .leading) {
                            Capsule().fill(Color.accentColor)
                                .frame(width: bounds.size.width * entry.time / entry.duration)
                        }
                }.frame(height: 4).padding(.horizontal, 10).padding(.bottom, 6)
            }
            .aspectRatio(16.0 / 9, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 10))
            Text(media.title).font(.headline).lineLimit(1)
            Text([entry.playback.label, remaining(entry)].compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }.frame(width: min(cardWidth, 300), alignment: .leading)
    }

    private func remaining(_ entry: HistoryEntry) -> String {
        let minutes = max(1.0, ((entry.duration - entry.time) / 60).rounded(.up))
        return "\(minutes.formatted(.number.precision(.fractionLength(0)))) min left"
    }
}
