import SwiftUI

@MainActor
struct CataloguePage: View {
    let history: HistoryStore
    let connected: Bool
    var searchOnly = false
    let openConnections: () -> Void
    let openRoom: () -> Void
    let play: (HistoryEntry.Playback, Bool) -> Void
    @State private var shelf: Catalogue.Shelf = .trending
    @State private var query = ""
    @State private var genre: Int?
    @State private var genres: [CatalogueGenre] = []
    @State private var titles: [CatalogueTitle] = []
    @State private var people: [CatalogueActor] = []
    @State private var page = 1
    @State private var more = false
    @State private var error = ""
    @State private var busy = false
    @State private var loadedRequest: Request?
    @State private var loadID: UUID?
    @State private var moviePicks: [CatalogueTitle] = []
    @State private var seriesPicks: [CatalogueTitle] = []
    @State private var topPicks: [CatalogueTitle] = []
    @State private var recPicks: [CatalogueTitle] = []
    @State private var heroLogos: [String: String] = [:]
    @State private var recentSearches: [String] = UserDefaults.standard.stringArray(forKey: "recent-searches") ?? []

    private struct Request: Equatable { let shelf: Catalogue.Shelf; let query: String; let genre: Int?; let connected: Bool }
    private var seed: HistoryEntry.Playback.Media? {
        (history.entries.filter(\.complete).map(\.playback.media) + history.list).first {
            ($0.kind == "movie" || $0.kind == "tv") && $0.id != nil && $0.provider != "tvmaze"
        }
    }

    var body: some View {
        NavigationStack {
            Group {
            if connected {
                if searchOnly { browse.searchable(text: $query, prompt: "Movies, TV shows, or actors") }
                else { browse }
            } else {
                ScrollView {
                    if !searchOnly { ContinueWatchingShelf(history: history) { play($0, false) } }
                    ContentUnavailableView {
                        Label("Connect your catalogue", systemImage: "film.stack")
                    } description: {
                        Text("Add a TMDB key to browse movies and TV shows.")
                    } actions: {
                        Button("Open Connections", action: openConnections).buttonStyle(.borderedProminent)
                    }
                }
                .navigationTitle(searchOnly ? "Search" : "Interlude")
            }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Watch Together", systemImage: "person.2.wave.2", action: openRoom)
                }
            }
        }
    }

    private var browse: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !searchOnly && shelf == .trending && loadedRequest?.shelf == .trending && loadedRequest?.query == "" {
                    let backdrops = titles.filter { $0.media.backdrop != nil }
                    let heroItems = Array((backdrops.count >= 2 ? backdrops : titles).prefix(5))
                    if !heroItems.isEmpty {
                        heroCarousel(heroItems)
                    }
                }

                // Category filter capsules
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Catalogue.Shelf.allCases) { item in
                            let active = item == shelf
                            Button(item.rawValue) { shelf = item; genre = nil }
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(active ? Color.accentColor : Color.primary.opacity(0.09), in: .capsule)
                                .foregroundStyle(active ? accentForeground : .primary)
                                .buttonStyle(CinemaPressStyle())
                                .accessibilityAddTraits(active ? [.isSelected] : [])
                        }
                    }
                    .padding(.horizontal)
                }

                // Netflix-style Home Feed: Hero Carousel -> Category Pills -> Continue Watching -> Top 10 -> Recommended -> Popular Movies/TV/Top Rated
                if !searchOnly && shelf == .trending {
                    ContinueWatchingShelf(history: history) { play($0, false) }
                    if !titles.isEmpty {
                        posterShelf("Top 10 Trending", items: Array(titles.prefix(10)), ranked: true)
                    }
                    posterShelf("Recommended for You", items: recPicks)
                    posterShelf("Popular Movies", items: moviePicks)
                    posterShelf("Popular TV Shows", items: seriesPicks)
                    posterShelf("Top Rated Movies", items: topPicks)
                }

                if searchOnly && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !recentSearches.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Recent searches").font(.headline)
                            Spacer()
                            Button("Clear") {
                                recentSearches = []
                                UserDefaults.standard.removeObject(forKey: "recent-searches")
                            }.font(.subheadline)
                        }.padding(.horizontal)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(recentSearches, id: \.self) { term in
                                    Button { query = term } label: {
                                        Label(term, systemImage: "magnifyingglass")
                                            .font(.subheadline)
                                            .padding(.horizontal, 12).padding(.vertical, 7)
                                            .background(Color.primary.opacity(0.08), in: .capsule)
                                    }.buttonStyle(.plain)
                                }
                            }.padding(.horizontal)
                        }
                    }
                }

                if shelf.kind != nil && query.isEmpty && !genres.isEmpty {
                    Picker("Genre", selection: $genre) {
                        Text("All genres").tag(Int?.none)
                        ForEach(genres) { Text($0.name).tag(Optional($0.id)) }
                    }.padding(.horizontal)
                }

                if searchOnly && !people.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("People").font(.title3.bold()).padding(.horizontal)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 12) {
                                ForEach(people) { person in
                                    NavigationLink { ActorCredits(actor: person, history: history, play: play) } label: {
                                        HStack(spacing: 8) {
                                            CatalogueImage(person.photo, cornerRadius: 20).frame(width: 40, height: 40).clipShape(.circle)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(person.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                                if let role = person.role, !role.isEmpty {
                                                    Text(role).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                                }
                                            }
                                        }
                                        .padding(.trailing, 12).padding(.leading, 4).padding(.vertical, 4)
                                        .background(Color.primary.opacity(0.08), in: .capsule)
                                    }.buttonStyle(.plain)
                                }
                            }.padding(.horizontal)
                        }
                    }
                }

                if busy && titles.isEmpty {
                    if !searchOnly && shelf == .trending { HomeSkeletonView() }
                    else { ProgressView().frame(maxWidth: .infinity) }
                }
                if !error.isEmpty {
                    ContentUnavailableView {
                        Label("Catalogue unavailable", systemImage: "wifi.exclamationmark")
                    } description: { Text(error) } actions: {
                        Button("Try again") { Task { await load(reset: true) } }.buttonStyle(.bordered)
                    }
                }
                if !busy && titles.isEmpty && people.isEmpty && error.isEmpty {
                    if query.isEmpty { ContentUnavailableView("No titles found", systemImage: "film.stack") }
                    else { ContentUnavailableView.search(text: query) }
                }

                if !titles.isEmpty && (searchOnly || shelf != .trending) {
                    Text(query.isEmpty ? shelf.rawValue : "Results").font(.title2.bold()).padding(.horizontal)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 12)], alignment: .leading, spacing: 18) {
                        ForEach(titles) { item in
                            poster(item)
                                .onAppear {
                                    if item.id == titles.last?.id, more, !busy {
                                        Task { await load(reset: false) }
                                    }
                                }
                        }
                    }
                    .padding(.horizontal)
                }
                if more && (searchOnly || shelf != .trending) {
                    if busy { ProgressView().frame(maxWidth: .infinity) }
                    else { Button("Load more") { Task { await load(reset: false) } }.frame(maxWidth: .infinity) }
                }
                Text("Movie and TV data by TMDB.").foregroundStyle(.secondary).font(.caption).padding(.horizontal)
            }.padding(.vertical, 10)
        }
        .background(ProfileTheme.color(history.themes.active.background))
        .navigationTitle(searchOnly ? "Search" : "Interlude")
        .navigationBarTitleDisplayMode(searchOnly ? .large : .inline)
        .task {
            guard !searchOnly, moviePicks.isEmpty, seriesPicks.isEmpty else { return }
            async let movies = try? Catalogue.feed(shelf: .movies, query: "", genre: nil, page: 1, seed: nil)
            async let series = try? Catalogue.feed(shelf: .shows, query: "", genre: nil, page: 1, seed: nil)
            async let top = try? Catalogue.feed(shelf: .topRated, query: "", genre: nil, page: 1, seed: nil)
            async let recs = seed != nil ? (try? Catalogue.feed(shelf: .recommended, query: "", genre: nil, page: 1, seed: seed)) : nil
            let (movieRes, seriesRes, topRes, recRes) = await (movies, series, top, recs)
            guard !Task.isCancelled else { return }
            moviePicks = Array((movieRes?.titles ?? []).prefix(14))
            seriesPicks = Array((seriesRes?.titles ?? []).prefix(14))
            topPicks = Array((topRes?.titles ?? []).prefix(14))
            recPicks = Array((recRes?.titles ?? []).prefix(14))
        }
        .task(id: shelf) {
            genres = []
            if let kind = shelf.kind, let loaded = try? await Catalogue.genres(kind: kind), !Task.isCancelled { genres = loaded }
        }
        .task(id: Request(shelf: shelf, query: query, genre: genre, connected: connected)) {
            let request = Request(shelf: shelf, query: query, genre: genre, connected: connected)
            guard loadedRequest != request else { return }
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(280)) }
            if !Task.isCancelled { await load(reset: true) }
        }
        .refreshable { await load(reset: true) }
    }

    private var accentForeground: Color {
        let color = UIColor(ProfileTheme.color(history.themes.active.accent))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return .black }
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return lum > 0.38 ? .black : .white
    }

    private func heroCarousel(_ items: [CatalogueTitle]) -> some View {
        TabView {
            ForEach(items) { item in
                featured(item)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: items.count > 1 ? .automatic : .never))
        .frame(height: 390)
    }

    private func featured(_ item: CatalogueTitle) -> some View {
        let saved = history.list.contains { $0.key == item.id }
        let bg = ProfileTheme.color(history.themes.active.background)
        let eyebrow = ProfileTheme.readableAccent(history.themes.active.accent)
        return ZStack(alignment: .bottomLeading) {
            CatalogueImage(item.media.backdrop ?? item.media.poster, cornerRadius: 20)
            LinearGradient(colors: [.black.opacity(0.28), .clear, .black.opacity(0.45), bg.opacity(0.96)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                Text(item.media.kind == "tv" ? "FEATURED SERIES" : "FEATURED FILM")
                    .font(.caption2.weight(.heavy)).tracking(1.4).foregroundStyle(eyebrow)
                StudioLogoView(address: heroLogos[item.id] ?? item.logo, fallback: item.media.title, maxHeight: 72)
                    .task(id: item.id) {
                        guard heroLogos[item.id] == nil, item.logo == nil, let id = item.media.id else { return }
                        if let url = try? await Catalogue.logoURL(kind: item.media.kind, id: id), !Task.isCancelled {
                            heroLogos[item.id] = url
                        }
                    }
                HStack(spacing: 8) {
                    if let year = item.media.year, !year.isEmpty { Text(year) }
                    if let rating = item.media.rating, rating > 0 {
                        Label(rating.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                            .foregroundStyle(.yellow)
                    }
                }.font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.88))
                if let overview = item.media.description, !overview.isEmpty {
                    Text(overview).font(.footnote).foregroundStyle(.white.opacity(0.86)).lineLimit(2)
                }
                HStack(spacing: 8) {
                    if item.media.kind == "movie" {
                        Button { play(item.playback(), false) } label: {
                            Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).foregroundStyle(accentForeground)
                    }
                    NavigationLink {
                        CatalogueDetail(item: item, history: history, play: play)
                    } label: {
                        Label(item.media.kind == "tv" ? "Episodes" : "Details", systemImage: "info.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).tint(.white)
                    Button { history.toggleSaved(item.media) } label: {
                        Image(systemName: saved ? "checkmark" : "plus")
                    }
                    .buttonStyle(.bordered).tint(.white)
                    .accessibilityLabel(saved ? "Remove from My List" : "Add to My List")
                }.controlSize(.regular).padding(.bottom, 16)
            }.foregroundStyle(.white).padding(18)
        }
        .clipShape(.rect(cornerRadius: 20))
        .padding(.horizontal)
    }

    private func posterShelf(_ title: String, items: [CatalogueTitle], ranked: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !items.isEmpty {
                Text(title).font(.title3.bold()).padding(.horizontal).accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            poster(item, rank: ranked ? index + 1 : nil).frame(width: ranked ? 138 : 118)
                        }
                    }.scrollTargetLayout()
                }
                .contentMargins(.horizontal, 16, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden)
            }
        }
    }

    private func poster(_ item: CatalogueTitle, rank: Int? = nil) -> some View {
        NavigationLink {
            CatalogueDetail(item: item, history: history, play: play)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                ZStack(alignment: .bottomLeading) {
                    ZStack(alignment: .topTrailing) {
                        CatalogueImage(item.media.poster, cornerRadius: 10).aspectRatio(2 / 3, contentMode: .fit)
                        if let rating = item.media.rating, rating > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "star.fill").foregroundStyle(.yellow)
                                Text(rating.formatted(.number.precision(.fractionLength(1))))
                            }
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.72), in: .rect(cornerRadius: 6))
                            .padding(6)
                        }
                    }
                    .padding(.leading, rank == nil ? 0 : 20)
                    if let rank {
                        Text("\(rank)")
                            .font(.system(size: 56, weight: .black, design: .rounded))
                            .foregroundStyle(ProfileTheme.readableAccent(history.themes.active.accent))
                            .shadow(color: .black.opacity(0.9), radius: 5, x: 0, y: 2)
                            .offset(x: -2, y: 10)
                    }
                }
                Text(item.media.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    .padding(.leading, rank == nil ? 0 : 20)
                if let year = item.media.year, !year.isEmpty {
                    Text(year).font(.caption).foregroundStyle(.secondary)
                        .padding(.leading, rank == nil ? 0 : 20)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(CinemaPressStyle())
    }

    private func rememberSearch(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        var updated = recentSearches.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        updated.insert(trimmed, at: 0)
        recentSearches = Array(updated.prefix(8))
        UserDefaults.standard.set(recentSearches, forKey: "recent-searches")
    }

    private func load(reset: Bool) async {
        let request = Request(shelf: shelf, query: query, genre: genre, connected: connected)
        let ticket = UUID()
        loadID = ticket
        let index = reset ? 1 : page + 1
        if reset && loadedRequest != request { titles = []; people = []; more = false; loadedRequest = nil }
        busy = true
        error = ""
        defer { if loadID == ticket { busy = false } }
        let trimmed = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let result = try await Catalogue.feed(shelf: request.shelf, query: trimmed,
                genre: request.genre, page: index, seed: seed)
            guard !Task.isCancelled, loadID == ticket,
                  request == Request(shelf: shelf, query: query, genre: genre, connected: connected) else { return }
            var existing = Set(reset ? [] : titles.map(\.id))
            let incoming = result.titles.filter { existing.insert($0.id).inserted }
            if reset {
                titles = incoming
                people = result.people
                if !trimmed.isEmpty { rememberSearch(trimmed) }
            } else {
                titles.append(contentsOf: incoming)
            }
            page = index
            more = result.more
            loadedRequest = request
        } catch {
            if !Task.isCancelled, loadID == ticket,
               request == Request(shelf: shelf, query: query, genre: genre, connected: connected) { self.error = error.localizedDescription }
        }
    }
}

@MainActor
struct CatalogueDetail: View {
    let item: CatalogueTitle
    let history: HistoryStore
    let play: (HistoryEntry.Playback, Bool) -> Void
    @Environment(\.openURL) private var openURL
    @State private var details: CatalogueTitle?
    @State private var franchise: CatalogueCollection?
    @State private var season: Int?
    @State private var episodes: [CatalogueEpisode] = []
    @State private var error = ""
    @State private var episodeError = ""
    @State private var loadedSeason: Int?

    private var title: CatalogueTitle { details ?? item }
    private var resumeEpisode: HistoryEntry.Playback? {
        history.entries.first {
            $0.playback.media.key == title.id && $0.playback.episode != nil && !$0.complete && $0.time > 0
        }?.playback
    }
    private var primaryPlayback: HistoryEntry.Playback? {
        if title.media.kind == "movie" { return title.playback() }
        if let resumeEpisode { return resumeEpisode }
        guard let season, loadedSeason == season else { return nil }
        let selections = episodes.map { title.playback(season: season, episode: $0) }
        return selections.first { !history.isWatched($0) } ?? selections.first
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                hero
                VStack(alignment: .leading, spacing: 16) {
                    if let primary = primaryPlayback {
                        let resume = history.entries.contains { $0.id == primary.id && !$0.complete && $0.time > 0 }
                        let action = resume ? "Resume" : "Play"
                        let label = primary.episode.map { "\(action) S\($0.season) E\($0.number)" } ?? action
                        Button { play(primary, false) } label: {
                            Label(label, systemImage: "play.fill").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).controlSize(.large)
                    }
                    HStack {
                        if let primary = primaryPlayback {
                            Button { play(primary, true) } label: { Label("Together", systemImage: "person.2") }
                                .accessibilityLabel("Watch Together")
                        }
                        let saved = history.list.contains { $0.key == title.id }
                        Button { history.toggleSaved(title.media) } label: {
                            Label(saved ? "In My List" : "My List", systemImage: saved ? "checkmark" : "plus")
                        }
                        Menu { watched(title.playback()) } label: {
                            Label("More", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                                .accessibilityLabel("More actions")
                        }
                    }.buttonStyle(.bordered).controlSize(.large)
                    if let trailer = title.trailer, let url = URL(string: "https://www.youtube.com/watch?v=\(trailer)") {
                        Button { openURL(url) } label: {
                            Label("Watch Trailer", systemImage: "play.rectangle.fill").frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered).controlSize(.large)
                    }

                    if let tagline = title.tagline {
                        Text(tagline).font(.subheadline.italic())
                            .foregroundStyle(ProfileTheme.readableAccent(history.themes.active.accent))
                    }
                    if let description = title.media.description, !description.isEmpty { Text(description).font(.callout) }
                    if let director = title.director {
                        Text("\(title.media.kind == "tv" ? "Created by" : "Directed by") \(director)")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if details == nil && error.isEmpty { ProgressView().accessibilityLabel("Loading title details") }

                    if title.media.kind == "tv" && !title.seasons.isEmpty {
                        Section {
                            HStack {
                                Picker("Season", selection: $season) {
                                    ForEach(title.seasons, id: \.self) { Text($0 == 0 ? "Specials" : "Season \($0)").tag(Optional($0)) }
                                }.pickerStyle(.menu)
                                Spacer()
                                if let season, loadedSeason == season, !episodes.isEmpty {
                                    let entries = episodes.map { title.playback(season: season, episode: $0) }
                                    let complete = entries.allSatisfy(history.isWatched)
                                    Button(complete ? "Unwatch season" : "Mark season watched") {
                                        history.setWatched(entries, complete: !complete)
                                    }.font(.caption.weight(.semibold))
                                }
                            }
                            if !episodeError.isEmpty { Text(episodeError).foregroundStyle(.orange) }
                            if let season, loadedSeason == season {
                                if episodes.isEmpty { Text("No episodes available.").foregroundStyle(.secondary) }
                                ForEach(episodes) { episode in
                                    let playback = title.playback(season: season, episode: episode)
                                    let isDone = history.isWatched(playback)
                                    let entry = history.entries.first { $0.id == playback.id }
                                    let pct: Double = (!isDone && (entry?.duration ?? 0) > 0 && (entry?.time ?? 0) > 2)
                                        ? min(1, max(0.03, (entry?.time ?? 0) / (entry?.duration ?? 1))) : 0
                                    HStack(alignment: .top, spacing: 10) {
                                        Button { play(playback, false) } label: {
                                            HStack(alignment: .top, spacing: 11) {
                                                ZStack {
                                                    CatalogueImage(episode.still ?? title.media.backdrop, cornerRadius: 8)
                                                        .frame(width: 118, height: 66)
                                                    Image(systemName: "play.fill")
                                                        .font(.caption.bold())
                                                        .foregroundStyle(.white)
                                                        .frame(width: 30, height: 30)
                                                        .background(.black.opacity(0.66), in: Circle())
                                                    if isDone {
                                                        Image(systemName: "checkmark.circle.fill")
                                                            .foregroundStyle(Color.accentColor)
                                                            .background(Circle().fill(.black))
                                                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                                            .padding(4)
                                                    }
                                                    if pct > 0 {
                                                        VStack {
                                                            Spacer()
                                                            GeometryReader { g in
                                                                ZStack(alignment: .leading) {
                                                                    Rectangle().fill(.white.opacity(0.3))
                                                                    Rectangle().fill(Color.accentColor).frame(width: g.size.width * pct)
                                                                }
                                                            }.frame(height: 3)
                                                        }
                                                    }
                                                }
                                                .frame(width: 118, height: 66)
                                                .clipShape(.rect(cornerRadius: 8))

                                                VStack(alignment: .leading, spacing: 4) {
                                                    HStack(spacing: 4) {
                                                        Text("\(episode.id). \(episode.name)").font(.subheadline.weight(.semibold)).lineLimit(2)
                                                        Spacer(minLength: 2)
                                                        if let mins = episode.runtime, mins > 0 {
                                                            Text("\(mins)m").font(.caption2).foregroundStyle(.secondary)
                                                        }
                                                    }
                                                    if !episode.overview.isEmpty {
                                                        Text(episode.overview).lineLimit(2).font(.caption).foregroundStyle(.secondary)
                                                    }
                                                }
                                            }.contentShape(Rectangle())
                                        }.buttonStyle(CinemaPressStyle())
                                        Menu {
                                            Button("Watch Together") { play(playback, true) }
                                            watched(playback)
                                        } label: {
                                            Image(systemName: "ellipsis").frame(width: 32, height: 40)
                                                .accessibilityLabel("Actions for \(episode.name)")
                                        }
                                    }
                                    Divider()
                                }
                            } else if episodeError.isEmpty {
                                ProgressView().accessibilityLabel("Loading episodes")
                            }
                        } header: {
                            Text("Episodes").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                        }
                    }

                    if !title.cast.isEmpty {
                        Section {
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 12) {
                                    ForEach(title.cast) { person in
                                        NavigationLink { ActorCredits(actor: person, history: history, play: play) } label: {
                                            VStack(alignment: .center, spacing: 5) {
                                                CatalogueImage(person.photo, cornerRadius: 34).frame(width: 68, height: 68).clipShape(.circle)
                                                Text(person.name).font(.caption.weight(.semibold)).multilineTextAlignment(.center).lineLimit(2)
                                                if let role = person.role { Text(role).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                                            }.frame(width: 82)
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }
                        } header: { Text("Cast").font(.title3.bold()) }
                    }

                    if let franchise, franchise.parts.count > 1 {
                        Section {
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 12) {
                                    ForEach(franchise.parts) { part in
                                        NavigationLink { CatalogueDetail(item: part, history: history, play: play) } label: {
                                            VStack(alignment: .leading, spacing: 4) {
                                                CatalogueImage(part.media.poster, cornerRadius: 9)
                                                    .frame(width: 110, height: 162)
                                                Text(part.media.title).font(.caption.weight(.semibold)).lineLimit(2)
                                                if let year = part.media.year, !year.isEmpty {
                                                    Text(year).font(.caption2).foregroundStyle(.secondary)
                                                }
                                            }.frame(width: 110, alignment: .leading)
                                        }.buttonStyle(CinemaPressStyle())
                                    }
                                }
                            }
                        } header: { Text("Part of \(franchise.name)").font(.title3.bold()) }
                    }

                    if !title.related.isEmpty {
                        Section {
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 12) {
                                    ForEach(title.related) { other in
                                        NavigationLink { CatalogueDetail(item: other, history: history, play: play) } label: {
                                            VStack(alignment: .leading, spacing: 4) {
                                                CatalogueImage(other.media.poster, cornerRadius: 9)
                                                    .frame(width: 110, height: 162)
                                                Text(other.media.title).font(.caption.weight(.semibold)).lineLimit(2)
                                            }.frame(width: 110, alignment: .leading)
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }
                        } header: { Text("More Like This").font(.title3.bold()) }
                    }

                    if !error.isEmpty { Text(error).foregroundStyle(.orange) }
                }.padding(.horizontal).padding(.bottom, 24)
            }
        }
        .background(ProfileTheme.color(history.themes.active.background))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard details == nil else { return }
            do {
                let full = try await Catalogue.details(item)
                guard !Task.isCancelled else { return }
                details = full
                season = full.seasons.first { $0 > 0 } ?? full.seasons.first
                if let cid = full.collectionID, let loaded = try? await Catalogue.collection(id: cid), !Task.isCancelled {
                    franchise = loaded
                }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .task(id: season) {
            guard let season, loadedSeason != season else { return }
            episodeError = ""
            do {
                let loaded = try await Catalogue.episodes(title, season: season)
                if !Task.isCancelled, self.season == season { episodes = loaded; loadedSeason = season }
            } catch { if !Task.isCancelled, self.season == season { episodeError = error.localizedDescription } }
        }
    }

    private var hero: some View {
        let bg = ProfileTheme.color(history.themes.active.background)
        return ZStack(alignment: .bottomLeading) {
            CatalogueImage(title.media.backdrop ?? title.media.poster, cornerRadius: 0)
            LinearGradient(colors: [.clear, .black.opacity(0.45), bg], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 6) {
                StudioLogoView(address: title.logo, fallback: title.media.title, maxHeight: 82)
                let runtimeText = title.media.runtime.map { mins -> String in
                    let m = Int(mins)
                    return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
                }
                Text([title.media.year, runtimeText, title.media.genres?.prefix(3).joined(separator: " · ")]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
                if let rating = title.media.rating, rating > 0 {
                    Label(rating.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.yellow)
                }
            }.padding(.horizontal, 18).padding(.bottom, 14)
        }.frame(height: 360)
    }

    private func watched(_ playback: HistoryEntry.Playback) -> some View {
        let complete = history.isWatched(playback)
        return Button(complete ? "Mark unwatched" : "Mark watched") { history.setWatched(playback, complete: !complete) }
    }
}

@MainActor
private struct ActorCredits: View {
    let actor: CatalogueActor
    let history: HistoryStore
    let play: (HistoryEntry.Playback, Bool) -> Void
    @State private var person: CataloguePerson?
    @State private var kind = "all"
    @State private var expandedBio = false
    @State private var error = ""

    var body: some View {
        let bg = ProfileTheme.color(history.themes.active.background)
        let topBackdrop = person?.titles.compactMap(\.media.backdrop).first ?? actor.photo
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ZStack(alignment: .bottomLeading) {
                    CatalogueImage(topBackdrop, cornerRadius: 0)
                        .blur(radius: 14)
                        .opacity(0.45)
                    LinearGradient(colors: [.clear, .black.opacity(0.55), bg], startPoint: .top, endPoint: .bottom)
                    HStack(alignment: .bottom, spacing: 14) {
                        CatalogueImage(actor.photo, cornerRadius: 44)
                            .frame(width: 88, height: 88)
                            .clipShape(.circle)
                            .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1.5))
                            .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(actor.name).font(.title.bold())
                            if let role = actor.role, !role.isEmpty {
                                Text(role).font(.subheadline.weight(.medium))
                                    .foregroundStyle(ProfileTheme.readableAccent(history.themes.active.accent))
                            }
                        }
                    }
                    .padding(.horizontal, 18).padding(.bottom, 14)
                }
                .frame(height: 220)

                VStack(alignment: .leading, spacing: 16) {
                    if let person {
                        if !person.biography.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(person.biography)
                                    .font(.callout).foregroundStyle(.secondary)
                                    .lineLimit(expandedBio ? nil : 4)
                                Button(expandedBio ? "Show less" : "Read more") { expandedBio.toggle() }
                                    .font(.caption.weight(.semibold))
                            }
                        }

                        let knownFor = Array(person.titles.sorted { ($0.media.rating ?? 0) > ($1.media.rating ?? 0) }.prefix(8))
                        if knownFor.count >= 3 {
                            Text("Known For").font(.title3.bold())
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 12) {
                                    ForEach(knownFor) { item in
                                        NavigationLink { CatalogueDetail(item: item, history: history, play: play) } label: {
                                            VStack(alignment: .leading, spacing: 4) {
                                                CatalogueImage(item.media.poster, cornerRadius: 9).frame(width: 108, height: 160)
                                                Text(item.media.title).font(.caption.weight(.semibold)).lineLimit(1)
                                            }.frame(width: 108, alignment: .leading)
                                        }.buttonStyle(CinemaPressStyle())
                                    }
                                }
                            }
                        }

                        Picker("Credits", selection: $kind) {
                            Text("All").tag("all"); Text("Movies").tag("movie"); Text("TV Shows").tag("tv")
                        }.pickerStyle(.segmented)

                        let titles = person.titles.filter { kind == "all" || $0.media.kind == kind }
                        if titles.isEmpty {
                            Text("No titles found.").foregroundStyle(.secondary)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 12)], alignment: .leading, spacing: 16) {
                                ForEach(titles) { item in
                                    NavigationLink { CatalogueDetail(item: item, history: history, play: play) } label: {
                                        VStack(alignment: .leading, spacing: 5) {
                                            CatalogueImage(item.media.poster, cornerRadius: 10).aspectRatio(2 / 3, contentMode: .fit)
                                            Text(item.media.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                            if let year = item.media.year, !year.isEmpty {
                                                Text(year).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.buttonStyle(CinemaPressStyle())
                                }
                            }
                        }
                    } else if !error.isEmpty {
                        Text(error).foregroundStyle(.orange)
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal).padding(.bottom, 24)
            }
        }
        .background(bg)
        .navigationTitle(actor.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { person = try await Catalogue.person(actor) }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

@MainActor
private struct HomeSkeletonView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ShimmerBox(cornerRadius: 20)
                .frame(height: 360)
                .padding(.horizontal)
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    ShimmerBox(cornerRadius: 6).frame(width: 150, height: 18).padding(.horizontal)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(0..<5, id: \.self) { _ in
                                VStack(alignment: .leading, spacing: 6) {
                                    ShimmerBox(cornerRadius: 10).frame(width: 118, height: 176)
                                    ShimmerBox(cornerRadius: 4).frame(width: 96, height: 12)
                                }
                            }
                        }.padding(.horizontal)
                    }
                }
            }
        }
    }
}
