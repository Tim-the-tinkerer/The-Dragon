import Foundation

enum Wing: String, CaseIterable, Identifiable {
    case curve
    case scale
    case fold
    case reel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .curve: return "Dragon Curve"
        case .scale: return "Dragonscale"
        case .fold: return "Dragonfold"
        case .reel: return "Dragonreel"
        }
    }

    var detail: String {
        switch self {
        case .curve: return "Notes and files"
        case .scale: return "Pictures"
        case .fold: return "Audio"
        case .reel: return "Movies"
        }
    }

    var windowTitle: String { "The Dragon — \(title)" }

    static func forURL(_ url: URL) -> Wing {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return .curve
        }
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "tif", "tiff", "gif", "heic", "heif", "webp", "bmp":
            return .scale
        case "wav", "aiff", "aif", "aifc", "mp3", "m4a", "aac", "caf", "flac":
            return .fold
        case "mp4", "mov", "m4v", "mpg", "mpeg", "avi":
            return .reel
        default:
            return .curve
        }
    }
}
