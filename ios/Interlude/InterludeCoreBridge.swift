import Foundation

#if canImport(interlude_ffiFFI)
/// Shared singleton access to the Rust `interlude-core` library via UniFFI on iOS.
enum InterludeCoreBridge {
    static let version: String = coreVersion()

    static let sharedClient: FfiInterludeClient? = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = caches.appendingPathComponent("catalogue", isDirectory: true).path
        guard let client = try? FfiInterludeClient(cacheDir: dir) else { return nil }
        DispatchQueue.global(qos: .utility).async { client.pruneCache() }
        return client
    }()

    static func errorMessage(_ error: Error, fallback: String) -> String {
        guard let ffi = error as? FfiError else { return error.localizedDescription }
        switch ffi {
        case .InvalidInput(let detail),
             .Expired(let detail),
             .TooLarge(let detail),
             .Network(let detail):
            return detail.isEmpty ? fallback : detail
        }
    }
}
#endif
