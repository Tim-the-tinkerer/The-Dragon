import Foundation

/// Preview keeps the start of a movie. Full movie keeps the file when the
/// temporary copies will fit.
enum ReelSpan: String, CaseIterable, Identifiable {
    case preview
    case full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preview: return "Preview"
        case .full: return "Full movie"
        }
    }

    var detail: String {
        switch self {
        case .preview:
            return "The first 20 seconds, or \(AppInfo.maxFrames) frames. It stops sooner when the frame cache is full."
        case .full:
            return "The whole movie, when the temporary files for the loaded frames, the folded frames, and the sound will fit."
        }
    }
}

/// Where a read stops. A full movie has no frame or time stop. Its picture
/// budget is the raw size set aside before the read began.
struct ReadLimit: Equatable {
    var maxSeconds: Double?
    var maxFrames: Int?
    var maxCacheBytes: Int?
    var frameBudget: Int64?

    static func make(_ span: ReelSpan, frameBudget: Int64?) -> ReadLimit {
        switch span {
        case .preview:
            return ReadLimit(
                maxSeconds: AppInfo.maxSeconds,
                maxFrames: AppInfo.maxFrames,
                maxCacheBytes: AppInfo.maxCacheBytes,
                frameBudget: nil
            )
        case .full:
            return ReadLimit(
                maxSeconds: nil,
                maxFrames: nil,
                maxCacheBytes: nil,
                frameBudget: frameBudget
            )
        }
    }
}

enum StorageBudget {
    struct Job: Equatable {
        var frames: Int
        var seconds: Double
        /// One picture store, every frame kept raw. The fold writes a second store.
        var pictureBytes: Int64
        /// One PCM file. Zero when there is no sound, or the sound stays in memory.
        var soundBytes: Int64
        var total: Int64

        var holdsSoundOnDisk: Bool { soundBytes > 0 }
    }

    /// Nil when the length cannot be measured, or the raw size does not fit in an integer.
    static func job(
        width: Int,
        height: Int,
        fps: Double,
        seconds: Double,
        sampleRate: Int,
        channels: Int,
        hasSound: Bool
    ) -> Job? {
        guard width > 0, height > 0, fps.isFinite, fps > 0, seconds.isFinite, seconds > 0 else {
            return nil
        }
        let counted = (seconds * fps).rounded(.up)
        guard counted.isFinite, counted >= 1, counted < Double(Int.max) else { return nil }
        let frames = Int(counted)
        guard let picture = product(Int64(width), Int64(height), 4, Int64(frames)) else { return nil }
        var sound: Int64 = 0
        if hasSound, sampleRate > 0, channels > 0 {
            let sampleFrames = (seconds * Double(sampleRate)).rounded(.up)
            if sampleFrames.isFinite, sampleFrames >= 1, sampleFrames < Double(Int64.max),
               let bytes = product(Int64(sampleFrames), Int64(channels), 2),
               bytes > Int64(AppInfo.memorySoundBytes) {
                sound = bytes
            }
        }
        guard let pictures = product(picture, 2), let sounds = product(max(sound, 1), sound == 0 ? 1 : 2) else {
            return nil
        }
        let soundTotal = sound == 0 ? 0 : sounds
        guard let total = add(pictures, soundTotal) else { return nil }
        return Job(frames: frames, seconds: seconds, pictureBytes: picture, soundBytes: sound, total: total)
    }

    /// Nil when the job fits in the free space, after a reserve is left unused.
    static func refusal(_ job: Job, free: Int64?) -> String? {
        guard let free else {
            return "The free space could not be read, so the full movie was not loaded."
        }
        let reserve = min(Int64(2_000_000_000), max(free / 10, Int64(512_000_000)))
        let room = free > reserve ? free - reserve : 0
        guard job.total > room else { return nil }
        let what = job.holdsSoundOnDisk
            ? "the loaded frames, the folded frames, and the sound"
            : "the loaded frames and the folded frames"
        return "The full movie needs about \(AppInfo.bytes(job.total)) of temporary space for \(what). About \(AppInfo.bytes(room)) can be used. The load was not started."
    }

    static func freeBytes() -> Int64? {
        let url = FileManager.default.temporaryDirectory
        return try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    private static func product(_ parts: Int64...) -> Int64? {
        var total: Int64 = 1
        for part in parts {
            if part < 0 { return nil }
            if part > 0, total > Int64.max / part { return nil }
            total *= part
        }
        return total
    }

    private static func add(_ left: Int64, _ right: Int64) -> Int64? {
        if right > 0, left > Int64.max - right { return nil }
        return left + right
    }
}
