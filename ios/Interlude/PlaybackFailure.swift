import AVFoundation
import Foundation

enum PlaybackFailure {
    case format, connection, access, missing, protected, unknown

    init(error: Error?, status: Int?, local: Bool) {
        if let status {
            switch status {
            case 401, 403, 410: self = .access; return
            case 404: self = .missing; return
            case 408, 429, 500...599: self = .connection; return
            default: break
            }
        }
        var cause = error as NSError?
        var candidate = Self.unknown
        for _ in 0..<5 {
            guard let current = cause else { break }
            switch current.domain {
            case NSURLErrorDomain:
                switch URLError.Code(rawValue: current.code) {
                case .fileDoesNotExist: self = .missing
                case .noPermissionsToReadFile, .userAuthenticationRequired: self = .access
                default: self = .connection
                }
                return
            case NSCocoaErrorDomain where local:
                if current.code == NSFileReadNoPermissionError { self = .access; return }
                if current.code == NSFileReadNoSuchFileError { self = .missing; return }
            case AVFoundationErrorDomain:
                switch AVError.Code(rawValue: current.code) {
                case .contentIsProtected: self = .protected; return
                case .contentIsNotAuthorized, .applicationIsNotAuthorized: self = .access; return
                case .decoderNotFound, .decodeFailed, .fileFormatNotRecognized, .formatUnsupported, .fileFailedToParse,
                     .incompatibleAsset, .operationNotSupportedForAsset:
                    candidate = .format
                default: break
                }
            default: break
            }
            cause = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        self = candidate
    }

    var canTryAnotherDecoder: Bool { self == .format || self == .unknown }

    static func prefersCompatibility(_ filename: String) -> Bool {
        ["mkv", "webm", "avi", "m2ts", "ts", "flv", "wmv", "mpg", "mpeg", "ogv"].contains((filename as NSString).pathExtension.lowercased())
    }

    func message(local: Bool, compatibility: Bool) -> String {
        switch self {
        case .access: return local ? "The iPhone couldn’t read this file. Reopen it from Files." :
            "The source denied access or the link expired. Retry to reopen the source."
        case .missing: return local ? "The file is missing or hasn’t finished downloading in Files." :
            "The video is no longer available at this source."
        case .connection: return "The video source couldn’t be reached. Check your connection and retry."
        case .protected: return "This video is protected and requires its original playback app."
        case .format, .unknown:
            return compatibility ? "The compatibility player couldn’t open this video. Try another file or source." :
                "The iPhone player couldn’t open this video."
        }
    }
}
