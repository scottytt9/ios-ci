import ImageIO
import Network
import SwiftUI

enum ArtworkResult: @unchecked Sendable {
    case image(CGImage)
    /// A smaller rendition, shown after the full size failed. It isn't cached, so it upgrades later.
    case fallback(CGImage)
    /// The image doesn't exist or can't be decoded.
    case unavailable
    /// The network failed after retries. Trying again later may work.
    case failed
}

extension ArtworkResult {
    var frame: CGImage? {
        switch self {
        case .image(let frame), .fallback(let frame): return frame
        case .unavailable, .failed: return nil
        }
    }
}

/// Counts the times the device regains a connection, so artwork that failed offline loads again.
final class ArtworkNetwork: ObservableObject {
    static let shared = ArtworkNetwork()
    @Published private(set) var generation = 0
    private let monitor = NWPathMonitor()
    private var online = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            if satisfied, !self.online { self.generation += 1 }
            self.online = satisfied
        }
        monitor.start(queue: .main)
    }
}

actor ArtworkCache {
    static let shared = ArtworkCache()

    func rawImage(address: String, maxPixels: Int = 512) async -> CGImage? {
        guard let req = ArtworkRequest(address, size: CGSize(width: maxPixels, height: maxPixels), scale: 1),
              let frame = await load(req).frame else { return nil }
        return frame
    }

    private struct Pending {
        let generation: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<ArtworkResult, Never>]
    }

    private let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 40 * 1024 * 1024
        return cache
    }()
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 15
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("catalogue-artwork", isDirectory: true)
        configuration.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 150 * 1024 * 1024, directory: directory)
        return URLSession(configuration: configuration)
    }()
    private var pending: [ArtworkRequest: Pending] = [:]
    /// Images that don't exist, so revisiting a screen doesn't request them again.
    private var missing: Set<URL> = []

    func load(_ request: ArtworkRequest) async -> ArtworkResult {
        if let cached = cache.object(forKey: request.cacheKey) { return .image(cached) }
        if missing.contains(request.fetchURL) { return .unavailable }
        let waiter = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: .failed); return }
                if pending[request] != nil {
                    pending[request]?.waiters[waiter] = continuation
                    return
                }
                let generation = UUID()
                let session = self.session
                let task = Task.detached(priority: .utility) {
                    let result = await Self.decode(request, using: session)
                    await self.complete(request, generation: generation, result: result)
                }
                pending[request] = Pending(generation: generation, task: task, waiters: [waiter: continuation])
            }
        } onCancel: {
            Task { await self.cancel(request, waiter: waiter) }
        }
    }

    private func cancel(_ request: ArtworkRequest, waiter: UUID) {
        guard let continuation = pending[request]?.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(returning: .failed)
        if pending[request]?.waiters.isEmpty == true { pending.removeValue(forKey: request)?.task.cancel() }
    }

    private func complete(_ request: ArtworkRequest, generation: UUID, result: ArtworkResult) {
        guard pending[request]?.generation == generation, let job = pending.removeValue(forKey: request) else { return }
        switch result {
        case .image(let frame): cache.setObject(frame, forKey: request.cacheKey, cost: frame.bytesPerRow * frame.height)
        case .unavailable: missing.insert(request.fetchURL)
        case .fallback, .failed: break
        }
        for waiter in job.waiters.values { waiter.resume(returning: result) }
    }

    /// Delays before the second and third attempts.
    private static let retryDelays: [Duration] = [.milliseconds(800), .milliseconds(2500)]

    /// Downloads the rendition with retries, then tries a smaller rendition once.
    private static func decode(_ request: ArtworkRequest, using session: URLSession) async -> ArtworkResult {
        let result = await fetch(request.fetchURL, maxPixels: request.maxPixels, attempts: 3, using: session)
        guard case .failed = result, !Task.isCancelled, let smaller = request.smallerURL else { return result }
        if case .image(let frame) = await fetch(smaller, maxPixels: request.maxPixels, attempts: 1, using: session) { return .fallback(frame) }
        return result
    }

    private static func fetch(_ url: URL, maxPixels: Int, attempts: Int, using session: URLSession) async -> ArtworkResult {
        for attempt in 0..<attempts {
            if attempt > 0 {
                do { try await Task.sleep(for: retryDelays[min(attempt - 1, retryDelays.count - 1)]) } catch { return .failed }
            }
            do {
                let (data, response) = try await session.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 {
                    guard data.count <= 5 * 1024 * 1024, let frame = thumbnail(data, maxPixels: maxPixels) else { return .unavailable }
                    return .image(frame)
                }
                // Other client errors won't change on retry; timeouts and rate limits might.
                if (400..<500).contains(status), status != 408, status != 429 { return .unavailable }
            } catch {
                let code = (error as? URLError)?.code
                if Task.isCancelled || code == .cancelled { return .failed }
                // Offline: wait for ArtworkNetwork to report the connection instead of retrying now.
                if code == .notConnectedToInternet || code == .dataNotAllowed || code == .internationalRoamingOff { return .failed }
            }
        }
        return .failed
    }

    private static func thumbnail(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary)
    }
}

/// Restarts artwork loading when the size, address or connection changes.
private struct ArtworkAttempt: Hashable {
    let request: ArtworkRequest?
    let network: Int
}

struct CatalogueImage: View {
    let address: String?
    var cornerRadius: CGFloat = 9
    @Environment(\.displayScale) private var scale
    @ObservedObject private var network = ArtworkNetwork.shared
    @State private var artwork: (ArtworkRequest, CGImage)?
    @State private var unavailable: ArtworkRequest?
    /// The frame on screen is a smaller rendition shown after the full size failed.
    @State private var fallbackShown = false

    /// Pauses between rounds after a failed load while the view stays on screen.
    private static let laterRetries: [Duration] = [.seconds(10), .seconds(30)]

    init(_ address: String?, cornerRadius: CGFloat = 9) {
        self.address = address
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        GeometryReader { area in
            let request = ArtworkRequest(address, size: area.size, scale: scale)
            Group {
                // A resized view keeps showing the previous frame while the new size loads.
                if let (loaded, frame) = artwork, loaded.url == request?.url {
                    Image(decorative: frame, scale: scale).resizable().scaledToFill()
                        .transition(.opacity.animation(.easeOut(duration: 0.22)))
                } else if ArtworkRequest.allowed(address) == nil || (request != nil && unavailable == request) {
                    ArtworkPlaceholder(cornerRadius: cornerRadius)
                } else {
                    ShimmerBox(cornerRadius: cornerRadius)
                }
            }
            .frame(width: area.size.width, height: area.size.height)
            .clipped()
            .task(id: ArtworkAttempt(request: request, network: network.generation)) {
                guard let request else { return }
                if let (loaded, _) = artwork, loaded == request, !fallbackShown { return }
                for round in 0...Self.laterRetries.count {
                    if round > 0 {
                        do { try await Task.sleep(for: Self.laterRetries[round - 1]) } catch { return }
                    }
                    let result = await ArtworkCache.shared.load(request)
                    guard !Task.isCancelled else { return }
                    switch result {
                    case .image(let frame):
                        artwork = (request, frame)
                        unavailable = nil
                        fallbackShown = false
                        return
                    case .fallback(let frame):
                        // Shows the smaller image now and tries the full size again in the next round.
                        artwork = (request, frame)
                        unavailable = nil
                        fallbackShown = true
                    case .unavailable:
                        if artwork?.0.url != request.url { unavailable = request }
                        return
                    case .failed:
                        if artwork?.0.url != request.url { unavailable = request }
                    }
                }
            }
        }
        .clipShape(.rect(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }
}

/// Shown in place of artwork that doesn't exist or can't be reached.
struct ArtworkPlaceholder: View {
    var cornerRadius: CGFloat = 9

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.primary.opacity(0.08))
            .overlay {
                Image(systemName: "film")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
    }
}

struct StudioLogoView: View {
    let address: String?
    let fallback: String
    var maxHeight: CGFloat = 78
    @Environment(\.displayScale) private var scale
    @State private var logoImage: CGImage?
    @State private var loadedAddress: String?

    var body: some View {
        Group {
            if let logoImage, loadedAddress == address {
                Image(decorative: logoImage, scale: scale)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 260, maxHeight: maxHeight, alignment: .leading)
                    .shadow(color: .black.opacity(0.65), radius: 10, y: 4)
                    .transition(.opacity.animation(.easeOut(duration: 0.22)))
                    .accessibilityLabel(fallback)
            } else {
                Text(fallback)
                    .font(.largeTitle.bold())
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .task(id: address) {
            guard let address, !address.isEmpty else { logoImage = nil; loadedAddress = nil; return }
            if let frame = await ArtworkCache.shared.rawImage(address: address, maxPixels: 640), !Task.isCancelled {
                logoImage = frame
                loadedAddress = address
            }
        }
    }
}

struct ShimmerBox: View {
    var cornerRadius: CGFloat = 9
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -0.7

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.primary.opacity(0.08))
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.14), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .frame(width: geo.size.width * 1.4)
                        .offset(x: phase * geo.size.width)
                    }
                    .clipped()
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) {
                    phase = 1.4
                }
            }
    }
}

struct CinemaPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.22, bounce: 0.15), value: configuration.isPressed)
    }
}

extension ProfileTheme {
    static func readableAccent(_ hex: String) -> Color {
        let rgb = channels(hex).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        let lum = rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722
        if lum >= 0.28 { return color(hex) }
        let raw = channels(hex)
        return Color(red: min(1, (raw[0] + 2) / 3), green: min(1, (raw[1] + 2) / 3), blue: min(1, (raw[2] + 2) / 3))
    }
}
