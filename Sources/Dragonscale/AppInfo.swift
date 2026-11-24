import Foundation

enum AppInfo {
    static let name = "Dragonscale"
    static let version = "1.0.8"
    static let build = "9"
    static let bundleID = "com.tim.dragonscale"

    /// The curve picture draws at most this many segments of the chosen pass.
    static let drawSegments = 4_096
    /// Loaded pictures keep at most this many pixels on the long side.
    static let maxSide = 8_192
    /// Pixel mode covers any picture the window can open: one segment per pixel.
    static let maxUnits = maxSide * maxSide
    static let maxTile = 4_096
    static let defaultTile = 16
    /// Compressed files larger than this are refused.
    static let maxFileBytes = 512 * 1024 * 1024
}
