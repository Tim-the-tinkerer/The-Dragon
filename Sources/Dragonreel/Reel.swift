import AppKit
import CoreGraphics
import Foundation

enum ReelAxis: Int, CaseIterable, Identifiable {
    case scale = 1
    case fold = 2
    case both = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .scale: return "Scale"
        case .fold: return "Fold"
        case .both: return "Both"
        }
    }

    var detail: String {
        switch self {
        case .scale:
            return "The same tiles move on every frame. The picture stays scrambled. Motion stays continuous. The sound inside each frame is rearranged with those tiles."
        case .fold:
            return "Runs of frames trade places. A longer run keeps the motion inside it, and the sound inside it. One frame at a time flickers."
        case .both:
            return "The sound inside each frame moves with the tiles. Runs of frames carry their sound through time."
        }
    }

    var usesTiles: Bool { self != .fold }
    var usesRuns: Bool { self != .scale }
}

struct ReelMark: Equatable {
    var axis: ReelAxis
    var tile: Int
    var run: Int
    var passes: Int
    var keyed: Bool
    var width: Int
    var height: Int
    var frames: Int

    var unitLine: String {
        switch axis {
        case .scale: return "scale, tile \(tile)"
        case .fold: return "fold, run \(run)"
        case .both: return "both, tile \(tile), run \(run)"
        }
    }

    /// One line in the movie's description. The phrase is not in it.
    var note: String {
        "DRL1 a=\(axis.rawValue) t=\(tile) r=\(run) p=\(passes) k=\(keyed ? 1 : 0) w=\(width) h=\(height) n=\(frames)"
    }

    static func parse(_ text: String) -> ReelMark? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("DRL1 ") else { return nil }
        var fields: [String: Int] = [:]
        for part in trimmed.split(separator: " ").dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, let value = Int(pair[1]) else { return nil }
            fields[String(pair[0])] = value
        }
        guard let axisRaw = fields["a"], let axis = ReelAxis(rawValue: axisRaw),
              let tile = fields["t"], let run = fields["r"],
              let passes = fields["p"], let keyed = fields["k"],
              let width = fields["w"], let height = fields["h"], let frames = fields["n"],
              (1...7).contains(passes), keyed == 0 || keyed == 1,
              width > 0, height > 0, frames > 0,
              tile >= 0, run >= 0 else {
            return nil
        }
        return ReelMark(
            axis: axis,
            tile: tile,
            run: run,
            passes: passes,
            keyed: keyed == 1,
            width: width,
            height: height,
            frames: frames
        )
    }
}

enum FrameFit {
    /// Fit inside 1920×1080. Even width and height. Smaller frames stay their size.
    static func size(width: Int, height: Int) -> (width: Int, height: Int, fitted: Bool) {
        guard width > 0, height > 0 else { return (0, 0, false) }
        var w = width
        var h = height
        var fitted = false
        if w > AppInfo.maxWidth || h > AppInfo.maxHeight {
            let scale = min(Double(AppInfo.maxWidth) / Double(w), Double(AppInfo.maxHeight) / Double(h))
            w = max(1, Int((Double(width) * scale).rounded(.down)))
            h = max(1, Int((Double(height) * scale).rounded(.down)))
            fitted = true
        }
        if w % 2 == 1 {
            w = max(2, w - 1)
            fitted = true
        }
        if h % 2 == 1 {
            h = max(2, h - 1)
            fitted = true
        }
        if w < 2 { w = 2; fitted = true }
        if h < 2 { h = 2; fitted = true }
        if w != width || h != height { fitted = true }
        return (w, h, fitted)
    }
}

/// 16-bit interleaved sound for the loaded span. Nil when the movie has no sound.
/// A short soundtrack stays in memory. A long one is a temporary file, so a fold
/// does not keep a second copy of the whole soundtrack in memory.
struct Soundtrack: Equatable {
    var sampleRate: Int
    var channels: Int
    private var held: [Int16]
    private var file: SoundStore?

    init(sampleRate: Int, channels: Int, samples: [Int16]) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.held = samples
        self.file = nil
    }

    init(sampleRate: Int, channels: Int, file: SoundStore) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.held = []
        self.file = file
    }

    var frames: Int {
        if let file { return file.frames }
        guard channels > 0 else { return 0 }
        return held.count / channels
    }

    /// In-memory samples. Empty when the sound lives in a temporary file.
    var samples: [Int16] { held }

    var keepsFile: Bool { file != nil }

    func readSamples(frame: Int, count: Int) throws -> [Int16] {
        guard count > 0 else { return [] }
        if let file {
            return try file.read(frame: frame, count: count)
        }
        let begin = frame * channels
        let end = begin + count * channels
        guard frame >= 0, begin >= 0, end <= held.count else {
            throw FoldError(message: "The sound could not be read.")
        }
        return Array(held[begin..<end])
    }

    static func == (lhs: Soundtrack, rhs: Soundtrack) -> Bool {
        if lhs.sampleRate != rhs.sampleRate || lhs.channels != rhs.channels || lhs.frames != rhs.frames {
            return false
        }
        if lhs.file == nil, rhs.file == nil { return lhs.held == rhs.held }
        return lhs.file === rhs.file
    }

    var summary: String {
        let kind = channels <= 1 ? "mono" : "stereo"
        if sampleRate == 44_100 { return "\(kind) 44.1 kHz" }
        if sampleRate == 48_000 { return "\(kind) 48 kHz" }
        if sampleRate >= 1_000, sampleRate % 1_000 == 0 { return "\(kind) \(sampleRate / 1_000) kHz" }
        return "\(kind) \(sampleRate) Hz"
    }
}

final class Reel {
    let width: Int
    let height: Int
    let fps: Double
    let name: String
    let reduced: Bool
    /// Why the load stopped before the end of the file. Nil when the opened span was kept.
    var clipped: String?
    var mark: ReelMark?
    var sound: Soundtrack?
    private var memory: [[UInt8]]?
    private var store: FrameStore?
    private var closed = false

    var count: Int { store?.count ?? memory?.count ?? 0 }
    var duration: Double {
        guard fps > 0 else { return 0 }
        return Double(count) / fps
    }
    var byteCount: Int { width * height * 4 }

    private init(
        width: Int,
        height: Int,
        fps: Double,
        name: String,
        reduced: Bool,
        clipped: String?,
        memory: [[UInt8]]?,
        store: FrameStore?
    ) {
        self.width = width
        self.height = height
        self.fps = fps
        self.name = name
        self.reduced = reduced
        self.clipped = clipped
        self.memory = memory
        self.store = store
    }

    deinit { close() }

    static func memory(
        frames: [[UInt8]],
        width: Int,
        height: Int,
        fps: Double,
        name: String,
        reduced: Bool = false,
        clipped: String? = nil
    ) -> Reel {
        Reel(
            width: width,
            height: height,
            fps: fps,
            name: name,
            reduced: reduced,
            clipped: clipped,
            memory: frames,
            store: nil
        )
    }

    static func store(width: Int, height: Int, fps: Double, name: String, reduced: Bool, clipped: String?) throws -> Reel {
        let store = try FrameStore(width: width, height: height)
        return Reel(
            width: width,
            height: height,
            fps: fps,
            name: name,
            reduced: reduced,
            clipped: clipped,
            memory: nil,
            store: store
        )
    }

    /// A small reel stays in memory. A long one, or one whose length is not known yet, goes to the frame cache.
    /// The byte count is not `width * height * frames`: that product overflows when the count is only a stand-in for "unknown".
    static func receiving(width: Int, height: Int, frames: Int?, fps: Double, name: String, reduced: Bool, clipped: String?) throws -> Reel {
        if keepsFramesInMemory(width: width, height: height, frames: frames) {
            return memory(frames: [], width: width, height: height, fps: fps, name: name, reduced: reduced, clipped: clipped)
        }
        return try store(width: width, height: height, fps: fps, name: name, reduced: reduced, clipped: clipped)
    }

    var keepsFramesOnDisk: Bool { store != nil }

    static func keepsFramesInMemory(width: Int, height: Int, frames: Int?) -> Bool {
        guard let frames else { return false }
        if frames <= 0 { return true }
        guard width > 0, height > 0 else { return true }
        let frameBytes = Int64(width) * Int64(height) * 4
        guard frameBytes > 0 else { return true }
        return Int64(frames) <= Int64(AppInfo.memoryFrameBytes) / frameBytes
    }

    var storedBytes: Int { store?.storedBytes ?? (byteCount * count) }

    func append(_ pixels: [UInt8]) throws {
        if let store {
            try store.append(pixels)
            return
        }
        if memory == nil { memory = [] }
        memory?.append(pixels)
    }

    func pixels(at index: Int) throws -> [UInt8] {
        var buffer = [UInt8]()
        try read(into: &buffer, at: index)
        return buffer
    }

    func read(into buffer: inout [UInt8], at index: Int) throws {
        if let store {
            try store.read(into: &buffer, at: index)
            return
        }
        guard let frame = memory?[safe: index] else {
            throw FoldError(message: "That frame is outside the reel.")
        }
        if buffer.count != frame.count {
            buffer = frame
            return
        }
        buffer.withUnsafeMutableBytes { dst in
            frame.withUnsafeBytes { src in
                dst.copyMemory(from: src)
            }
        }
    }

    func image(at index: Int = 0) -> NSImage? {
        guard let pixels = try? pixels(at: index) else { return nil }
        return FrameImage.nsImage(pixels: pixels, width: width, height: height)
    }

    func close() {
        guard !closed else { return }
        closed = true
        store?.destroy()
        store = nil
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

enum FrameImage {
    static func nsImage(pixels: [UInt8], width: Int, height: Int) -> NSImage? {
        guard let cg = cgImage(pixels: pixels, width: width, height: height) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: width, height: height))
        image.isTemplate = false
        return image
    }

    static func cgImage(pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, pixels.count == width * height * 4 else { return nil }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.last.rawValue)
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: info,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

enum ReelFold {
    static let tiles = [8, 16, 32, 64, 128]
    static let runs = [1, 2, 4, 8, 15, 30]

    struct Spatial {
        var columns: Int
        var rows: Int
        var side: Int
        var units: Int
        var edgeRight: Int
        var edgeBottom: Int
        var single: Bool
    }

    struct Temporal {
        var units: Int
        var run: Int
        var tail: Int
    }

    static func tileSide(_ tile: Int) -> Int {
        min(AppInfo.maxTile, max(1, tile))
    }

    static func runLength(_ run: Int) -> Int {
        min(AppInfo.maxRun, max(1, run))
    }

    static func spatialLayout(width: Int, height: Int, tile: Int) -> Spatial {
        guard width > 0, height > 0 else {
            return Spatial(columns: 0, rows: 0, side: 1, units: 0, edgeRight: 0, edgeBottom: 0, single: true)
        }
        let side = tileSide(tile)
        if width < side || height < side {
            return Spatial(columns: 1, rows: 1, side: side, units: 1, edgeRight: 0, edgeBottom: 0, single: true)
        }
        let columns = width / side
        let rows = height / side
        return Spatial(
            columns: columns,
            rows: rows,
            side: side,
            units: columns * rows,
            edgeRight: width % side,
            edgeBottom: height % side,
            single: false
        )
    }

    static func temporalLayout(frames: Int, run: Int) -> Temporal {
        guard frames > 0 else { return Temporal(units: 0, run: 1, tail: 0) }
        let size = runLength(run)
        if frames <= size {
            return Temporal(units: 1, run: frames, tail: 0)
        }
        return Temporal(units: frames / size, run: size, tail: frames % size)
    }

    static func limitMessage(width: Int, height: Int, frames: Int, axis: ReelAxis, tile: Int, run: Int) -> String? {
        if axis.usesTiles {
            let placed = spatialLayout(width: width, height: height, tile: tile)
            if placed.units > AppInfo.maxUnits {
                return "Tile \(tileSide(tile)) still makes \(AppInfo.grouped(placed.units)) segments. The curve stops at \(AppInfo.grouped(AppInfo.maxUnits)). Choose a larger tile."
            }
        }
        if axis.usesRuns {
            let placed = temporalLayout(frames: frames, run: run)
            if placed.units > AppInfo.maxUnits {
                return "Run \(runLength(run)) still makes \(AppInfo.grouped(placed.units)) segments. The curve stops at \(AppInfo.grouped(AppInfo.maxUnits)). Choose a longer run."
            }
        }
        return nil
    }

    /// Scale and fold commute when every frame uses the same tile map.
    /// Forward reads a source frame (time) and then gathers tiles (space).
    static func permute(
        source: Reel,
        axis: ReelAxis,
        tile: Int,
        run: Int,
        key: String,
        passes: Int?,
        reverse: Bool,
        onProgress: ((String) -> Void)? = nil
    ) throws -> Reel {
        guard source.count > 0, source.width > 0, source.height > 0 else {
            throw FoldError(message: "That reel has no frames.")
        }
        if let limit = limitMessage(
            width: source.width,
            height: source.height,
            frames: source.count,
            axis: axis,
            tile: tile,
            run: run
        ) {
            throw FoldError(message: limit)
        }
        let plan = try Curve.plan(key: key, passes: passes)
        let spatial = axis.usesTiles ? spatialLayout(width: source.width, height: source.height, tile: tile) : nil
        let temporal = axis.usesRuns ? temporalLayout(frames: source.count, run: run) : nil
        let tileMap = try map(count: spatial?.units ?? 0, passes: plan, reverse: reverse, active: spatial?.single == false)
        let runMap = try map(count: temporal?.units ?? 0, passes: plan, reverse: reverse, active: (temporal?.units ?? 0) > 1)
        let destination = try Reel.receiving(
            width: source.width,
            height: source.height,
            frames: source.count,
            fps: source.fps,
            name: source.name,
            reduced: source.reduced,
            clipped: source.clipped
        )
        var input = [UInt8](repeating: 0, count: source.byteCount)
        var output = [UInt8](repeating: 0, count: source.byteCount)
        let total = source.count
        for index in 0..<total {
            if index % 8 == 0 || index + 1 == total {
                onProgress?("Frame \(index + 1) of \(total)")
            }
            let sourceIndex = frameIndex(output: index, temporal: temporal, map: runMap)
            try source.read(into: &input, at: sourceIndex)
            if let spatial, let tileMap, !spatial.single {
                gather(into: &output, from: input, width: source.width, layout: spatial, map: tileMap)
                try destination.append(output)
            } else {
                try destination.append(input)
            }
        }
        destination.sound = try permuteSound(
            source.sound,
            videoFrames: source.count,
            spatial: spatial,
            temporal: temporal,
            tileMap: tileMap,
            runMap: runMap,
            plan: plan,
            reverse: reverse
        )
        destination.mark = ReelMark(
            axis: axis,
            tile: axis.usesTiles ? tileSide(tile) : 0,
            run: axis.usesRuns ? runLength(run) : 0,
            passes: plan.count,
            keyed: !key.isEmpty,
            width: source.width,
            height: source.height,
            frames: source.count
        )
        return destination
    }

    static func restore(
        source: Reel,
        mark: ReelMark,
        phrase: String,
        onProgress: ((String) -> Void)? = nil
    ) throws -> Reel {
        if mark.keyed != !phrase.isEmpty {
            throw FoldError(message: mark.keyed
                ? "This fold used a phrase."
                : "This fold used no phrase. Clear the phrase and restore again.")
        }
        if mark.width != source.width || mark.height != source.height || mark.frames != source.count {
            throw FoldError(message: "The fold note does not match this reel.")
        }
        let restored = try permute(
            source: source,
            axis: mark.axis,
            tile: max(mark.tile, 1),
            run: max(mark.run, 1),
            key: phrase,
            passes: mark.passes,
            reverse: true,
            onProgress: onProgress
        )
        restored.mark = nil
        return restored
    }

    static func edgeSentence(_ layout: Spatial) -> String? {
        let right = layout.edgeRight
        let bottom = layout.edgeBottom
        if right == 0, bottom == 0 { return nil }
        if right > 0, bottom > 0 {
            return "A \(right)-pixel strip on the right and a \(bottom)-pixel strip on the bottom stay put."
        }
        if right > 0 { return "A \(right)-pixel strip on the right stays put." }
        return "A \(bottom)-pixel strip on the bottom stays put."
    }

    struct AudioPieces {
        var perFrame: Int
        var tail: Int
        /// Pieces inside one frame. 0 means those samples stay in order.
        var pieces: Int
        var grain: Int
        var edge: Int
    }

    /// Each video frame owns an equal run of samples. A short tail stays at the end.
    /// Inside a frame, Scale and Both cut that run into the same number of pieces as tiles
    /// when there are enough samples. Otherwise each sample is a piece.
    static func soundLayout(sampleFrames: Int, videoFrames: Int, tiles: Int?) -> AudioPieces {
        guard videoFrames > 0, sampleFrames > 0 else {
            return AudioPieces(perFrame: 0, tail: max(0, sampleFrames), pieces: 0, grain: 0, edge: 0)
        }
        let perFrame = sampleFrames / videoFrames
        let tail = sampleFrames % videoFrames
        guard let tiles, tiles > 1, perFrame > 1 else {
            return AudioPieces(perFrame: perFrame, tail: tail, pieces: 0, grain: perFrame, edge: 0)
        }
        let pieces: Int
        let grain: Int
        let edge: Int
        if perFrame >= tiles {
            pieces = tiles
            grain = perFrame / tiles
            edge = perFrame % tiles
        } else {
            pieces = perFrame
            grain = 1
            edge = 0
        }
        if pieces > AppInfo.maxUnits {
            return AudioPieces(perFrame: perFrame, tail: tail, pieces: 0, grain: perFrame, edge: 0)
        }
        return AudioPieces(perFrame: perFrame, tail: tail, pieces: pieces, grain: grain, edge: edge)
    }

    static func soundClause(sound: Soundtrack?, videoFrames: Int, axis: ReelAxis, spatial: Spatial?) -> String? {
        guard let sound, sound.frames > 0, videoFrames > 0 else { return nil }
        let tiles = (axis.usesTiles && spatial?.single == false) ? spatial?.units : nil
        let layout = soundLayout(sampleFrames: sound.frames, videoFrames: videoFrames, tiles: tiles)
        if layout.perFrame < 1 {
            return "The sound is shorter than one sample a frame, so it stays put"
        }
        var bits: [String] = []
        if axis.usesRuns {
            bits.append("each frame's sound moves with that frame")
        }
        if axis.usesTiles {
            if layout.pieces > 1, let tiles, layout.pieces == tiles {
                bits.append("\(layout.pieces) pieces of \(layout.grain) sample\(layout.grain == 1 ? "" : "s") inside each frame")
            } else if layout.pieces > 1 {
                bits.append("each sample inside the frame moves")
            } else {
                bits.append("the sound inside a frame stays in order")
            }
        }
        if layout.tail > 0 {
            bits.append("\(layout.tail) sample\(layout.tail == 1 ? "" : "s") stay at the end")
        }
        guard let first = bits.first else { return nil }
        return first.prefix(1).uppercased() + first.dropFirst() + bits.dropFirst().map { ", \($0)" }.joined()
    }

    static func runSentence(_ layout: Temporal) -> String {
        if layout.run <= 1, layout.tail == 0 {
            return "One frame at a time. The picture flickers."
        }
        var line = "Runs of \(layout.run) frame\(layout.run == 1 ? "" : "s"). Motion inside each run stays in order."
        if layout.tail > 0 {
            line += " The last \(layout.tail) frame\(layout.tail == 1 ? "" : "s") stay at the end."
        }
        return line
    }

    private static func map(count: Int, passes: [Curve.Pass], reverse: Bool, active: Bool) throws -> [Int]? {
        guard active, count > 1 else { return nil }
        return try Curve.indexMap(count: count, passes: passes, reverse: reverse)
    }

    private static func frameIndex(output: Int, temporal: Temporal?, map: [Int]?) -> Int {
        guard let temporal, let map, temporal.units > 1 else { return output }
        let span = temporal.units * temporal.run
        if output >= span { return output }
        let piece = output / temporal.run
        let offset = output % temporal.run
        return map[piece] * temporal.run + offset
    }

    private static func permuteSound(
        _ sound: Soundtrack?,
        videoFrames: Int,
        spatial: Spatial?,
        temporal: Temporal?,
        tileMap: [Int]?,
        runMap: [Int]?,
        plan: [Curve.Pass],
        reverse: Bool
    ) throws -> Soundtrack? {
        guard let sound, sound.channels == 1 || sound.channels == 2, sound.frames > 0, videoFrames > 0 else {
            return sound
        }
        let tiles = (spatial?.single == false) ? spatial?.units : nil
        let layout = soundLayout(sampleFrames: sound.frames, videoFrames: videoFrames, tiles: tiles)
        guard layout.perFrame > 0 else { return sound }
        let pieceMap: [Int]?
        if layout.pieces > 1 {
            if layout.pieces == spatial?.units, let tileMap {
                pieceMap = tileMap
            } else {
                pieceMap = try Curve.indexMap(count: layout.pieces, passes: plan, reverse: reverse)
            }
        } else {
            pieceMap = nil
        }
        let channels = sound.channels
        if sound.keepsFile {
            let dest = try SoundStore(channels: channels)
            func copy(sampleFrame: Int, count: Int) throws {
                var left = count
                var frame = sampleFrame
                while left > 0 {
                    let take = min(16_384, left)
                    let chunk = try sound.readSamples(frame: frame, count: take)
                    guard chunk.count == take * channels else {
                        throw FoldError(message: "The sound could not be folded.")
                    }
                    try dest.append(chunk)
                    frame += take
                    left -= take
                }
            }
            try laySound(
                videoFrames: videoFrames, layout: layout, pieceMap: pieceMap,
                temporal: temporal, runMap: runMap, copy: copy
            )
            guard dest.frames == sound.frames else {
                throw FoldError(message: "The sound could not be folded.")
            }
            return Soundtrack(sampleRate: sound.sampleRate, channels: channels, file: dest)
        }
        let samples = sound.samples
        var out = [Int16](repeating: 0, count: samples.count)
        var cursor = 0
        func copy(sampleFrame: Int, count: Int) throws {
            let values = count * channels
            let begin = sampleFrame * channels
            guard count > 0, begin >= 0, begin + values <= samples.count, cursor + values <= out.count else {
                throw FoldError(message: "The sound could not be folded.")
            }
            out.withUnsafeMutableBufferPointer { destination in
                samples.withUnsafeBufferPointer { source in
                    destination.baseAddress!.advanced(by: cursor).update(
                        from: source.baseAddress!.advanced(by: begin),
                        count: values
                    )
                }
            }
            cursor += values
        }
        try laySound(
            videoFrames: videoFrames, layout: layout, pieceMap: pieceMap,
            temporal: temporal, runMap: runMap, copy: copy
        )
        guard cursor == out.count else {
            throw FoldError(message: "The sound could not be folded.")
        }
        return Soundtrack(sampleRate: sound.sampleRate, channels: channels, samples: out)
    }

    private static func laySound(
        videoFrames: Int,
        layout: AudioPieces,
        pieceMap: [Int]?,
        temporal: Temporal?,
        runMap: [Int]?,
        copy: (_ sampleFrame: Int, _ count: Int) throws -> Void
    ) throws {
        for index in 0..<videoFrames {
            let sourceIndex = frameIndex(output: index, temporal: temporal, map: runMap)
            let base = sourceIndex * layout.perFrame
            if let pieceMap, layout.grain > 0 {
                for dest in 0..<pieceMap.count {
                    try copy(base + pieceMap[dest] * layout.grain, layout.grain)
                }
                if layout.edge > 0 {
                    try copy(base + layout.pieces * layout.grain, layout.edge)
                }
            } else {
                try copy(base, layout.perFrame)
            }
        }
        let tailStart = videoFrames * layout.perFrame
        let sampleFrames = tailStart + layout.tail
        if tailStart < sampleFrames, layout.tail > 0 {
            try copy(tailStart, layout.tail)
        }
    }

    private static func gather(into output: inout [UInt8], from input: [UInt8], width: Int, layout: Spatial, map: [Int]) {
        let side = layout.side
        let columns = layout.columns
        let rowBytes = width * 4
        input.withUnsafeBytes { srcRaw in
            output.withUnsafeMutableBytes { dstRaw in
                guard let src = srcRaw.baseAddress, let dst = dstRaw.baseAddress else { return }
                dst.copyMemory(from: src, byteCount: input.count)
                let tileBytes = side * 4
                for dest in 0..<map.count {
                    let source = map[dest]
                    let sCol = source % columns
                    let sRow = source / columns
                    let dCol = dest % columns
                    let dRow = dest / columns
                    let sx = sCol * side
                    let sy = sRow * side
                    let dx = dCol * side
                    let dy = dRow * side
                    for row in 0..<side {
                        let from = (sy + row) * rowBytes + sx * 4
                        let to = (dy + row) * rowBytes + dx * 4
                        dst.advanced(by: to).copyMemory(from: src.advanced(by: from), byteCount: tileBytes)
                    }
                }
            }
        }
    }
}
