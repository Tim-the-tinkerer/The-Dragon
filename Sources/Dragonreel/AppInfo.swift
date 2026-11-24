import Foundation

enum AppInfo {
    static let name = "Dragonreel"
    static let version = "1.2.0"
    static let build = "4"
    static let bundleID = "com.tim.dragonreel"

    /// The curve picture draws at most this many segments of the chosen pass.
    static let drawSegments = 4_096
    /// One segment per pixel of a 1080p frame, with a little room past 1920×1080.
    static let maxUnits = 2_200_000

    /// This version fits every frame inside 1080p. Nothing is scaled up.
    static let maxWidth = 1_920
    static let maxHeight = 1_080

    /// Preview keeps the start of the movie, then stops at the first cap it hits.
    /// A full movie has no frame or time cap. Free temporary space is the limit.
    static let maxSeconds = 20.0
    static let maxFrames = 600
    /// Preview frame cache. A 1080p frame that does not shrink is about 8 MB,
    /// so this holds roughly eight seconds of 1080p, and longer when the picture is smaller.
    static let maxCacheBytes = 2_000_000_000
    /// A reel or a soundtrack under this size stays in memory. Past it, a temporary file is used.
    static let memoryFrameBytes = 64_000_000
    static let memorySoundBytes = 64_000_000

    static let defaultTile = 16
    static let defaultRun = 8
    static let maxTile = 512
    static let maxRun = 300

    static func grouped(_ value: Int) -> String {
        let digits = String(abs(value))
        var out = value < 0 ? "-" : ""
        for (offset, character) in digits.enumerated() {
            if offset > 0, (digits.count - offset) % 3 == 0 {
                out.append(",")
            }
            out.append(character)
        }
        return out
    }

    static func seconds(_ value: Double) -> String {
        if value < 10 {
            return String(format: "%.1f s", value)
        }
        return String(format: "%.0f s", value)
    }

    static func bytes(_ value: Int64) -> String {
        let magnitude = value < 0 ? -value : value
        if magnitude < 1_000_000 {
            return "\(grouped(Int(magnitude / 1_000))) KB"
        }
        if magnitude < 1_000_000_000 {
            return "\(grouped(Int(magnitude / 1_000_000))) MB"
        }
        let gigabytes = Double(magnitude) / 1_000_000_000
        if gigabytes < 10 {
            return String(format: "%.1f GB", gigabytes)
        }
        return "\(grouped(Int(gigabytes.rounded()))) GB"
    }
}
