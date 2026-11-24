import Foundation

enum AppInfo {
    static let name = "Dragonfold"
    static let version = "1.3.0"
    static let build = "4"
    static let bundleID = "com.tim.dragonfold"

    /// Loaded audio keeps at most this much. The rest is not read.
    static let maxSongSeconds = 600.0
    /// One dragon segment per sample of one channel.
    /// Ten minutes of 192 kHz is under this. A longer file needs Frame or Grain.
    static let maxUnits = 120_000_000

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
    /// The picture draws at most this many segments of the chosen pass.
    static let drawSegments = 4_096
    static let toneSeconds = 2.0
    static let toneRate = 44_100.0
    static let defaultGrain = 1_024
}
