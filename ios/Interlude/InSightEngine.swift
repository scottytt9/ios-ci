import AVFoundation
import SwiftUI
import UIKit
import Vision

/// On-device Apple Vision & subtitle dialogue InSight engine (0 KB external dependencies).
/// Matches faces in the current video frame against TMDB cast headshots using
/// VNDetectFaceRectanglesRequest + VNGenerateImageFeaturePrintRequest.
enum InSightEngine {
    struct SceneMatch: Identifiable {
        let actor: CatalogueActor
        let source: MatchSource
        var id: Int { actor.id }
    }

    enum MatchSource {
        case visionFace
        case dialogue
    }

    static func matchFaces(in frame: CGImage, candidates: [CatalogueActor]) async -> [CatalogueActor] {
        let withPhotos = Array(candidates.filter { $0.photo != nil }.prefix(10))
        guard !withPhotos.isEmpty else { return [] }

        return await Task.detached(priority: .userInitiated) {
            let scenePrints = extractFacePrints(from: frame, maxFaces: 4)
            guard !scenePrints.isEmpty else { return [] }

            var scored: [(actor: CatalogueActor, distance: Float)] = []
            for actor in withPhotos {
                if Task.isCancelled { break }
                guard let photo = actor.photo,
                      let headshot = await ArtworkCache.shared.rawImage(address: photo, maxPixels: 320),
                      let actorPrint = extractPrimaryPrint(from: headshot) else { continue }

                var bestDist: Float = .greatestFiniteMagnitude
                for scenePrint in scenePrints {
                    var distance: Float = .greatestFiniteMagnitude
                    if (try? scenePrint.computeDistance(&distance, to: actorPrint)) != nil {
                        bestDist = min(bestDist, distance)
                    }
                }
                // Calibrated Apple Vision VNFeaturePrint cosine/Euclidean distance threshold
                if bestDist < 0.72 {
                    scored.append((actor, bestDist))
                }
            }
            return scored.sorted { $0.distance < $1.distance }.prefix(4).map(\.actor)
        }.value
    }

    static func matchDialogue(_ dialogue: String, candidates: [CatalogueActor]) -> [CatalogueActor] {
        let lowered = dialogue.lowercased()
        guard !lowered.isEmpty else { return [] }
        var matched: [CatalogueActor] = []
        var seen = Set<Int>()
        for actor in candidates {
            guard let role = actor.role, role.count >= 3 else { continue }
            let tokens = role.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            if tokens.contains(where: { $0.count >= 4 && lowered.contains($0) }), seen.insert(actor.id).inserted {
                matched.append(actor)
            }
        }
        return matched
    }

    private static func extractFacePrints(from image: CGImage, maxFaces: Int) -> [VNFeaturePrintObservation] {
        let faceRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([faceRequest])
        let faces = (faceRequest.results ?? []).prefix(maxFaces)
        guard !faces.isEmpty else { return [] }
        return faces.compactMap { face in
            guard let cropped = crop(image: image, normalizedBox: face.boundingBox, padding: 0.22) else { return nil }
            return featurePrint(for: cropped)
        }
    }

    private static func extractPrimaryPrint(from headshot: CGImage) -> VNFeaturePrintObservation? {
        let faceRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: headshot, options: [:])
        try? handler.perform([faceRequest])
        if let face = faceRequest.results?.first,
           let cropped = crop(image: headshot, normalizedBox: face.boundingBox, padding: 0.22),
           let fp = featurePrint(for: cropped) {
            return fp
        }
        return featurePrint(for: headshot)
    }

    private static func featurePrint(for image: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        return request.results?.first as? VNFeaturePrintObservation
    }

    private static func crop(image: CGImage, normalizedBox: CGRect, padding: CGFloat) -> CGImage? {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let padW = normalizedBox.width * padding
        let padH = normalizedBox.height * padding
        let x = max(0, (normalizedBox.minX - padW) * w)
        let width = min(w - x, (normalizedBox.width + padW * 2) * w)
        // Vision uses bottom-left origin; CGImage uses top-left origin
        let y = max(0, (1 - normalizedBox.maxY - padH) * h)
        let height = min(h - y, (normalizedBox.height + padH * 2) * h)
        let rect = CGRect(x: x, y: y, width: width, height: height).integral
        guard rect.width >= 20, rect.height >= 20 else { return nil }
        return image.cropping(to: rect)
    }
}

@MainActor
struct InSightSheet: View {
    let playback: Playback
    @Environment(\.dismiss) private var dismiss
    @State private var guestStars: [CatalogueActor] = []
    @State private var cast: [CatalogueActor] = []
    @State private var onScreen: [InSightEngine.SceneMatch] = []
    @State private var loading = true
    @State private var scanningVision = false

    var body: some View {
        NavigationStack {
            List {
                if scanningVision {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Scanning frame with Apple Vision…")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                if !onScreen.isEmpty {
                    Section {
                        ForEach(onScreen) { match in
                            actorRow(match.actor, badge: match.source == .visionFace ? "Vision" : "Dialogue")
                        }
                    } header: {
                        Label("On Screen Now", systemImage: "sparkles")
                    }
                }

                if loading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading cast & scene info…").foregroundStyle(.secondary)
                    }
                } else {
                    if !guestStars.isEmpty {
                        Section("Episode Guest Stars") {
                            ForEach(guestStars) { actor in actorRow(actor) }
                        }
                    }
                    if !cast.isEmpty {
                        Section(playback.selection?.media.kind == "tv" ? "Series Cast" : "Cast") {
                            ForEach(cast) { actor in actorRow(actor) }
                        }
                    }
                    if guestStars.isEmpty && cast.isEmpty {
                        ContentUnavailableView("No cast info", systemImage: "person.2",
                                               description: Text("Cast details aren’t available for this title."))
                    }
                }
            }
            .navigationTitle("InSight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await loadInSight() }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.ultraThinMaterial)
    }

    private func actorRow(_ actor: CatalogueActor, badge: String? = nil) -> some View {
        NavigationLink {
            InSightActorPeek(actor: actor)
        } label: {
            HStack(spacing: 12) {
                CatalogueImage(actor.photo, cornerRadius: 23)
                    .frame(width: 46, height: 46)
                    .clipShape(.circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(actor.name).font(.body.weight(.semibold))
                    if let role = actor.role, !role.isEmpty {
                        Text(role).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.22), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    private func loadInSight() async {
        guard let selection = playback.selection, let id = selection.media.id else {
            loading = false
            return
        }
        loading = true
        var loadedGuests: [CatalogueActor] = []
        var loadedCast: [CatalogueActor] = []

        if selection.media.kind == "tv", let ep = selection.episode {
            if let credits = try? await Catalogue.episodeCredits(showID: id, season: ep.season, episode: ep.number) {
                loadedGuests = credits.guestStars
                loadedCast = credits.cast
            }
        }
        if loadedCast.isEmpty {
            if let details = try? await Catalogue.details(CatalogueTitle(snapshot: selection.media)) {
                loadedCast = details.cast
            }
        }
        guard !Task.isCancelled else { return }
        guestStars = loadedGuests
        cast = loadedCast
        loading = false

        let pool = loadedGuests + loadedCast
        guard !pool.isEmpty else { return }

        var matches: [InSightEngine.SceneMatch] = []
        var seen = Set<Int>()

        // 1. Live subtitle dialogue character matching (instant)
        let dialogue = playback.recentCaptionContext()
        for actor in InSightEngine.matchDialogue(dialogue, candidates: pool) where seen.insert(actor.id).inserted {
            matches.append(.init(actor: actor, source: .dialogue))
        }
        onScreen = matches

        // 2. Native Apple Vision on-device face matching on current frame
        if let frame = await playback.currentFrameImage(), !Task.isCancelled {
            scanningVision = true
            let visionMatches = await InSightEngine.matchFaces(in: frame, candidates: pool)
            scanningVision = false
            guard !Task.isCancelled else { return }
            var combined: [InSightEngine.SceneMatch] = []
            var combinedSeen = Set<Int>()
            for actor in visionMatches where combinedSeen.insert(actor.id).inserted {
                combined.append(.init(actor: actor, source: .visionFace))
            }
            for item in matches where combinedSeen.insert(item.actor.id).inserted {
                combined.append(item)
            }
            onScreen = combined
        }
    }
}

@MainActor
private struct InSightActorPeek: View {
    let actor: CatalogueActor
    @State private var person: CataloguePerson?
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    CatalogueImage(actor.photo, cornerRadius: 36)
                        .frame(width: 72, height: 72)
                        .clipShape(.circle)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(actor.name).font(.title2.bold())
                        if let role = actor.role, !role.isEmpty {
                            Text("as \(role)").font(.subheadline).foregroundStyle(Color.accentColor)
                        }
                    }
                }
                if loading {
                    ProgressView("Loading biography…")
                } else if let person {
                    if !person.biography.isEmpty {
                        Text(person.biography).font(.callout).foregroundStyle(.secondary)
                    }
                    if !person.titles.isEmpty {
                        Text("Known For").font(.headline).padding(.top, 4)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 10) {
                                ForEach(person.titles.prefix(8)) { title in
                                    VStack(alignment: .leading, spacing: 4) {
                                        CatalogueImage(title.media.poster, cornerRadius: 8)
                                            .frame(width: 92, height: 136)
                                        Text(title.media.title).font(.caption.weight(.semibold)).lineLimit(2)
                                    }.frame(width: 92, alignment: .leading)
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle(actor.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            person = try? await Catalogue.person(actor)
            loading = false
        }
    }
}
