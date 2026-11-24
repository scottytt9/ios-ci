import CoreGraphics
import Foundation

/// One piece of catalogue artwork at the size it is displayed.
struct ArtworkRequest: Hashable, Sendable {
    /// TMDB widths, narrowest first. TMDB serves each of them for every image.
    static let widths = [92, 154, 185, 300, 342, 500, 780, 1280]

    /// The stored address. Profiles keep canonical w500 and w1280 addresses.
    let url: URL
    /// The right-sized rendition that is downloaded.
    let fetchURL: URL
    let maxPixels: Int

    init?(_ address: String?, size: CGSize, scale: CGFloat) {
        guard let url = Self.allowed(address) else { return nil }
        let pixels = max(size.width, size.height) * scale
        guard pixels.isFinite, pixels > 1 else { return nil }
        self.url = url
        maxPixels = Int((min(pixels, 1536) / 64).rounded(.up)) * 64
        // A portrait poster filling the frame needs about two thirds of the frame's height in width.
        let width = max(size.width, size.height * 0.67) * scale
        fetchURL = Self.rendition(of: url, width: Self.widths.first { Double($0) >= Double(width) * 0.92 } ?? 1280) ?? url
    }

    static func allowed(_ address: String?) -> URL? {
        guard let address else { return nil }
        #if canImport(interlude_ffiFFI)
        guard artworkIsAllowedUrl(address: address) else { return nil }
        return URL(string: address)
        #else
        guard let url = URL(string: address), url.scheme == "https",
              (url.host == "image.tmdb.org" && url.path.hasPrefix("/t/p/")) || url.host == "static.tvmaze.com" else { return nil }
        return url
        #endif
    }

    /// `url` at another TMDB width, or nil for other hosts.
    static func rendition(of url: URL, width: Int) -> URL? {
        guard url.host == "image.tmdb.org" else { return nil }
        #if canImport(interlude_ffiFFI)
        return URL(string: artworkSized(address: url.absoluteString, pixels: UInt32(max(0, width))))
        #else
        let parts = url.path.split(separator: "/")
        guard parts.count == 4, parts[0] == "t", parts[1] == "p" else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w\(width)/\(parts[3])")
        #endif
    }

    /// About 60% of the downloaded width, for slow or failing connections.
    var smallerURL: URL? {
        #if canImport(interlude_ffiFFI)
        guard let smaller = artworkSmaller(address: fetchURL.absoluteString) else { return nil }
        return URL(string: smaller)
        #else
        let size = fetchURL.path.split(separator: "/").dropFirst(2).first ?? ""
        guard size.hasPrefix("w"), let current = Int(size.dropFirst()),
              let smaller = Self.widths.last(where: { Double($0) <= Double(current) * 0.62 && $0 >= 154 }) else { return nil }
        return Self.rendition(of: fetchURL, width: smaller)
        #endif
    }

    var cacheKey: NSString { "\(maxPixels):\(fetchURL.absoluteString)" as NSString }
}
