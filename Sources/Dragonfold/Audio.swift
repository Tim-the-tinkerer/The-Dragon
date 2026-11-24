import AVFoundation
import Foundation

enum AudioUnit: Int, CaseIterable, Identifiable {
    case sample = 1
    case frame = 2
    case grain = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .sample: return "Sample"
        case .frame: return "Frame"
        case .grain: return "Grain"
        }
    }

    var detail: String {
        switch self {
        case .sample:
            return "Each channel walks the phrase on its own dragon. The right side is the mirror, so the stereo stays wide. A long song can take a minute."
        case .frame:
            return "One moment, both channels, moves together."
        case .grain:
            return "A short block of the recording moves together."
        }
    }
}

struct FoldMark: Equatable {
    var unit: AudioUnit
    var grain: Int
    var passes: Int
    var keyed: Bool
    /// Grain mode only. A segment plays backward when that step of the curve turns right.
    var reverseRight: Bool = false
    /// Stereo sample mode. Left walks the phrase. Right walks the mirror.
    /// Older notes leave this off and keep both channels on one dragon.
    var ownDragon: Bool = false

    var unitLine: String {
        switch unit {
        case .sample: return ownDragon ? "sample, each channel" : "sample"
        case .frame: return "frame"
        case .grain: return "grain \(grain)"
        }
    }
}

struct Clip {
    var samples: [Int16]
    var frames: Int
    var channels: Int
    var sampleRate: Double
    var name: String
    var truncated: Bool
    var mark: FoldMark?

    var duration: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(frames) / sampleRate
    }

    var isStereo: Bool { channels > 1 }
}

struct WavePeaks {
    var minL: [Float]
    var maxL: [Float]
    var minR: [Float]
    var maxR: [Float]

    static let empty = WavePeaks(minL: [], maxL: [], minR: [], maxR: [])

    var isEmpty: Bool { minL.isEmpty }
}

enum AudioFold {
    static let grains = [64, 256, 1_024, 4_096, 16_384]

    /// How the clip sits on the curve.
    /// A short remainder at the end is not a segment. It stays where it is,
    /// so every segment is the same length and the fold can be undone.
    struct Layout {
        var units: Int
        var blockFrames: Int
        var tailFrames: Int
    }

    static func grainSize(unit: AudioUnit, grain: Int) -> Int {
        switch unit {
        case .sample, .frame: return 1
        case .grain: return min(1_048_576, max(1, grain))
        }
    }

    static func layout(frames: Int, channels: Int, unit: AudioUnit, grain: Int) -> Layout {
        guard frames > 0, channels > 0 else {
            return Layout(units: 0, blockFrames: 1, tailFrames: 0)
        }
        if unit == .sample {
            // One dragon per channel. A mono file has one channel, so this is every sample.
            return Layout(units: frames, blockFrames: 1, tailFrames: 0)
        }
        let size = grainSize(unit: unit, grain: grain)
        if frames <= size {
            return Layout(units: 1, blockFrames: frames, tailFrames: 0)
        }
        return Layout(units: frames / size, blockFrames: size, tailFrames: frames % size)
    }

    static func unitCount(frames: Int, channels: Int, unit: AudioUnit, grain: Int) -> Int {
        layout(frames: frames, channels: channels, unit: unit, grain: grain).units
    }

    static func limitMessage(frames: Int, channels: Int, unit: AudioUnit, grain: Int) -> String? {
        let count = unitCount(frames: frames, channels: channels, unit: unit, grain: grain)
        guard count > AppInfo.maxUnits else { return nil }
        let cap = AppInfo.grouped(AppInfo.maxUnits)
        let amount = AppInfo.grouped(count)
        if unit == .sample {
            if channels > 1 {
                return "Each channel has \(amount) samples. Sample mode stops at \(cap). Frame or Grain will fold it."
            }
            return "This recording has \(amount) samples. Sample mode stops at \(cap). Frame or Grain will fold it."
        }
        if unit == .frame {
            return "This recording has \(amount) moments. Frame mode stops at \(cap). A larger grain will fold it."
        }
        return "Grain \(grain) still makes \(amount) segments. The curve stops at \(cap). Choose a larger grain."
    }

    static func permute(
        samples: [Int16],
        frames: Int,
        channels: Int,
        unit: AudioUnit,
        grain: Int,
        key: String,
        passes: Int?,
        reverseRight: Bool = false,
        channelDragons: Bool? = nil,
        reverse: Bool,
        onPass: ((Int, Int) -> Void)? = nil
    ) throws -> (samples: [Int16], mark: FoldMark) {
        guard frames > 0, channels > 0, samples.count == frames * channels else {
            throw FoldError(message: "That audio has no samples.")
        }
        if let limit = limitMessage(frames: frames, channels: channels, unit: unit, grain: grain) {
            throw FoldError(message: limit)
        }
        let plan = try Curve.plan(key: key, passes: passes)
        // A new sample fold gives each channel its own walk. Restore of an
        // older note passes channelDragons: false and keeps the single dragon.
        let split = unit == .sample && channels > 1 && (channelDragons ?? !reverse)
        let turns = reverseRight && unit == .grain
        let folded: [Int16]
        if split {
            folded = try reorderStereoSamples(
                samples: samples,
                frames: frames,
                passes: plan,
                reverse: reverse,
                onPass: onPass
            )
        } else {
            var placed = layout(frames: frames, channels: channels, unit: unit, grain: grain)
            if unit == .sample && channels > 1 {
                placed = Layout(units: frames * channels, blockFrames: 1, tailFrames: 0)
            }
            // Each pass is applied, then its order is dropped. A song-length index
            // map would be another copy of the recording in pointer width.
            folded = try reorder(
                samples: samples,
                channels: channels,
                unit: unit,
                layout: placed,
                passes: plan,
                reverseRight: turns && placed.blockFrames > 1,
                reverse: reverse,
                onPass: onPass
            )
        }
        let mark = FoldMark(
            unit: unit,
            grain: unit == .grain ? grainSize(unit: unit, grain: grain) : 1,
            passes: plan.count,
            keyed: !key.isEmpty,
            reverseRight: turns,
            ownDragon: split
        )
        return (folded, mark)
    }

    static func restore(
        samples: [Int16],
        frames: Int,
        channels: Int,
        mark: FoldMark,
        phrase: String,
        onPass: ((Int, Int) -> Void)? = nil
    ) throws -> [Int16] {
        if mark.keyed != !phrase.isEmpty {
            throw FoldError(message: mark.keyed
                ? "This fold used a phrase."
                : "This fold used no phrase. Clear the phrase and restore again.")
        }
        let result = try permute(
            samples: samples,
            frames: frames,
            channels: channels,
            unit: mark.unit,
            grain: mark.grain,
            key: phrase,
            passes: mark.passes,
            reverseRight: mark.reverseRight,
            channelDragons: mark.ownDragon,
            reverse: true,
            onPass: onPass
        )
        return result.samples
    }

    static func peaks(of clip: Clip, buckets: Int = 700) -> WavePeaks {
        let columns = max(1, min(buckets, clip.frames))
        guard clip.frames > 0, clip.channels > 0 else { return .empty }
        var minL = [Float](repeating: 0, count: columns)
        var maxL = [Float](repeating: 0, count: columns)
        var minR = [Float](repeating: 0, count: columns)
        var maxR = [Float](repeating: 0, count: columns)
        for column in 0..<columns {
            let start = column * clip.frames / columns
            let end = max(start + 1, (column + 1) * clip.frames / columns)
            var loL: Float = 1
            var hiL: Float = -1
            var loR: Float = 1
            var hiR: Float = -1
            for frame in start..<end {
                let l = Float(clip.samples[frame * clip.channels]) / 32768
                loL = min(loL, l)
                hiL = max(hiL, l)
                let rIndex = frame * clip.channels + (clip.channels > 1 ? 1 : 0)
                let r = Float(clip.samples[rIndex]) / 32768
                loR = min(loR, r)
                hiR = max(hiR, r)
            }
            minL[column] = loL
            maxL[column] = hiL
            minR[column] = loR
            maxR[column] = hiR
        }
        return WavePeaks(minL: minL, maxL: maxL, minR: minR, maxR: maxR)
    }

    /// Forward writes `next[rank] = current[order[rank]]`.
    /// Reverse writes `next[order[rank]] = current[rank]`, which undoes that pass.
    /// A right turn then reverses the frames inside that grain. Doing it again puts them back.
    private static func reorder(
        samples: [Int16],
        channels: Int,
        unit: AudioUnit,
        layout: Layout,
        passes: [Curve.Pass],
        reverseRight: Bool,
        reverse: Bool,
        onPass: ((Int, Int) -> Void)?
    ) throws -> [Int16] {
        let count = layout.units
        let sequence = reverse ? Array(passes.reversed()) : passes
        let spin = reverseRight && unit == .grain && layout.blockFrames > 1
        guard count > 1 else {
            guard count == 1, spin else {
                for number in sequence.indices {
                    onPass?(number + 1, sequence.count)
                }
                return samples
            }
            var only = samples
            only.reserveCapacity(only.count + 1)
            only.append(0)
            only.removeLast()
            for (offset, pass) in sequence.enumerated() {
                onPass?(offset + 1, sequence.count)
                guard playsBackward(pass, segment: 0) else { continue }
                only.withUnsafeMutableBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return }
                    reverseFrames(base, frames: layout.blockFrames, channels: channels)
                }
            }
            return only
        }
        var current = samples
        current.reserveCapacity(current.count + 1)
        current.append(0)
        current.removeLast()
        var scratch = [Int16](repeating: 0, count: samples.count)
        let block = layout.blockFrames * channels
        let tail = layout.tailFrames * channels
        for (offset, pass) in sequence.enumerated() {
            onPass?(offset + 1, sequence.count)
            let order = try Curve.segmentOrder(count: count, pass: pass)
            if unit == .sample {
                moveSamples(from: current, to: &scratch, order: order, reverse: reverse)
            } else {
                let backward: [Bool]? = spin ? (0..<count).map { playsBackward(pass, segment: $0) } : nil
                moveBlocks(
                    from: current,
                    to: &scratch,
                    order: order,
                    block: block,
                    frames: layout.blockFrames,
                    channels: channels,
                    tail: tail,
                    backward: backward,
                    reverse: reverse
                )
            }
            swap(&current, &scratch)
        }
        return current
    }

    /// Left keeps the phrase's dragon. Right walks the same passes with the fold turned over.
    private static func mirror(_ pass: Curve.Pass) -> Curve.Pass {
        Curve.Pass(fold: -pass.fold, heading: pass.heading, skip: pass.skip, view: pass.view)
    }

    private static func reorderStereoSamples(
        samples: [Int16],
        frames: Int,
        passes: [Curve.Pass],
        reverse: Bool,
        onPass: ((Int, Int) -> Void)?
    ) throws -> [Int16] {
        let sequence = reverse ? Array(passes.reversed()) : passes
        guard frames > 1 else {
            for number in sequence.indices {
                onPass?(number + 1, sequence.count)
            }
            return samples
        }
        var left = [Int16](repeating: 0, count: frames)
        var right = [Int16](repeating: 0, count: frames)
        for frame in 0..<frames {
            left[frame] = samples[frame * 2]
            right[frame] = samples[frame * 2 + 1]
        }
        var leftScratch = [Int16](repeating: 0, count: frames)
        var rightScratch = [Int16](repeating: 0, count: frames)
        for (offset, pass) in sequence.enumerated() {
            onPass?(offset + 1, sequence.count)
            let leftOrder = try Curve.segmentOrder(count: frames, pass: pass)
            let rightOrder = try Curve.segmentOrder(count: frames, pass: mirror(pass))
            moveSamples(from: left, to: &leftScratch, order: leftOrder, reverse: reverse)
            moveSamples(from: right, to: &rightScratch, order: rightOrder, reverse: reverse)
            swap(&left, &leftScratch)
            swap(&right, &rightScratch)
        }
        var out = [Int16](repeating: 0, count: samples.count)
        for frame in 0..<frames {
            out[frame * 2] = left[frame]
            out[frame * 2 + 1] = right[frame]
        }
        return out
    }

    /// The turn after this segment. Right on the page is backward.
    private static func playsBackward(_ pass: Curve.Pass, segment: Int) -> Bool {
        let turn = Curve.paperTurn(pass.skip &+ UInt64(segment) &+ 1)
        return pass.fold * turn == -1
    }

    private static func moveSamples(
        from: [Int16],
        to: inout [Int16],
        order: [UInt32],
        reverse: Bool
    ) {
        from.withUnsafeBufferPointer { src in
            to.withUnsafeMutableBufferPointer { dst in
                order.withUnsafeBufferPointer { map in
                    let count = map.count
                    if reverse {
                        for rank in 0..<count {
                            dst[Int(map[rank])] = src[rank]
                        }
                    } else {
                        for rank in 0..<count {
                            dst[rank] = src[Int(map[rank])]
                        }
                    }
                }
            }
        }
    }

    private static func moveBlocks(
        from: [Int16],
        to: inout [Int16],
        order: [UInt32],
        block: Int,
        frames: Int,
        channels: Int,
        tail: Int,
        backward: [Bool]?,
        reverse: Bool
    ) {
        from.withUnsafeBufferPointer { src in
            to.withUnsafeMutableBufferPointer { dst in
                order.withUnsafeBufferPointer { map in
                    guard let source = src.baseAddress, let destination = dst.baseAddress else { return }
                    let count = map.count
                    if reverse {
                        for rank in 0..<count {
                            let segment = Int(map[rank])
                            let at = segment * block
                            destination.advanced(by: at).update(from: source.advanced(by: rank * block), count: block)
                            if backward?[segment] == true {
                                reverseFrames(destination.advanced(by: at), frames: frames, channels: channels)
                            }
                        }
                    } else {
                        for rank in 0..<count {
                            let segment = Int(map[rank])
                            let at = rank * block
                            destination.advanced(by: at).update(from: source.advanced(by: segment * block), count: block)
                            if backward?[segment] == true {
                                reverseFrames(destination.advanced(by: at), frames: frames, channels: channels)
                            }
                        }
                    }
                    if tail > 0 {
                        let start = count * block
                        destination.advanced(by: start).update(from: source.advanced(by: start), count: tail)
                    }
                }
            }
        }
    }

    /// Reverse frames in place. Channels inside a frame stay in their order.
    private static func reverseFrames(_ samples: UnsafeMutablePointer<Int16>, frames: Int, channels: Int) {
        guard frames > 1, channels > 0 else { return }
        var lo = 0
        var hi = frames - 1
        while lo < hi {
            let left = samples.advanced(by: lo * channels)
            let right = samples.advanced(by: hi * channels)
            for channel in 0..<channels {
                let sample = left[channel]
                left[channel] = right[channel]
                right[channel] = sample
            }
            lo += 1
            hi -= 1
        }
    }
}

enum Tone {
    /// Four short notes on the left, the harmony on the right.
    /// Grain mode cuts these into pieces the curve can reshuffle.
    static func make(seconds: Double = AppInfo.toneSeconds, rate: Double = AppInfo.toneRate) -> Clip {
        let length = max(1, Int((seconds * rate).rounded()))
        let leftNotes: [Double] = [261.6256, 329.6276, 391.9954, 523.2511]
        let rightNotes: [Double] = [329.6276, 391.9954, 493.8833, 659.2551]
        var samples = [Int16](repeating: 0, count: length * 2)
        var phaseL = 0.0
        var phaseR = 0.0
        let noteLength = Double(length) / 4
        for frame in 0..<length {
            let note = min(3, Int(Double(frame) / noteLength))
            let place = Double(frame) - Double(note) * noteLength
            let env = fade(place, noteLength: noteLength, rate: rate)
            let left = sin(phaseL) * 0.62 * env
            let right = sin(phaseR) * 0.62 * env
            samples[frame * 2] = quantize(Float(left))
            samples[frame * 2 + 1] = quantize(Float(right))
            phaseL += 2 * Double.pi * leftNotes[note] / rate
            phaseR += 2 * Double.pi * rightNotes[note] / rate
        }
        return Clip(
            samples: samples,
            frames: length,
            channels: 2,
            sampleRate: rate,
            name: "Tone",
            truncated: false,
            mark: nil
        )
    }

    private static func fade(_ place: Double, noteLength: Double, rate: Double) -> Double {
        let edge = min(noteLength / 4, 0.008 * rate)
        if place < edge { return place / edge }
        let remain = noteLength - place
        if remain < edge { return max(0, remain / edge) }
        return 1
    }
}

func quantize(_ x: Float) -> Int16 {
    if !x.isFinite { return 0 }
    let y = min(1, max(-1, x))
    let scaled = Int((Double(y) * 32767.0).rounded())
    return Int16(clamping: scaled)
}

enum WAVFile {
    private static let noteID = "dcaf"
    private static let noteBytes = 24

    static func encode(clip: Clip, includeNote: Bool) throws -> Data {
        guard clip.frames > 0, clip.channels == 1 || clip.channels == 2 else {
            throw FoldError(message: "There is no audio to write.")
        }
        guard clip.samples.count == clip.frames * clip.channels else {
            throw FoldError(message: "The audio buffer is the wrong length.")
        }
        let rate = UInt32(max(1, clip.sampleRate.rounded()))
        let channels = UInt16(clip.channels)
        let bits: UInt16 = 16
        let blockAlign = channels * (bits / 8)
        let byteRate = rate * UInt32(blockAlign)
        let dataBytes = clip.samples.count * 2
        var pcm = Data(capacity: dataBytes)
        for sample in clip.samples {
            var le = sample.littleEndian
            withUnsafeBytes(of: &le) { pcm.append(contentsOf: $0) }
        }
        let note = includeNote ? try notePayload(clip: clip, pcm: pcm, rate: rate) : nil

        var data = Data()
        data.reserveCapacity(44 + pcm.count + (note == nil ? 0 : 8 + noteBytes))
        func ascii(_ s: String) { data.append(contentsOf: s.utf8) }
        func u16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func u32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        let extra = note == nil ? 0 : 8 + noteBytes
        ascii("RIFF")
        u32(UInt32(36 + dataBytes + extra))
        ascii("WAVE")
        ascii("fmt ")
        u32(16)
        u16(1)
        u16(channels)
        u32(rate)
        u32(byteRate)
        u16(blockAlign)
        u16(bits)
        ascii("data")
        u32(UInt32(dataBytes))
        data.append(pcm)
        if let note {
            ascii(noteID)
            u32(UInt32(noteBytes))
            data.append(note)
        }
        return data
    }

    /// A 16-bit PCM WAV. A trailing `dcaf` chunk is the fold note.
    /// The note sits after the audio so a player that expects a plain WAV still plays.
    static func parse(_ data: Data, name: String) -> ParsedWAV? {
        guard data.count >= 44 else { return nil }
        guard readASCII(data, 0, 4) == "RIFF", readASCII(data, 8, 4) == "WAVE" else { return nil }
        var offset = 12
        var format: Format?
        var pcm: Data?
        var note: Data?
        while offset + 8 <= data.count {
            let id = readASCII(data, offset, 4)
            let size = Int(readU32(data, offset + 4))
            let start = offset + 8
            let end = start + size
            guard size >= 0, end <= data.count else { return nil }
            let payload = data.subdata(in: start..<end)
            if id == "fmt " { format = readFormat(payload) }
            if id == "data", pcm == nil { pcm = payload }
            if id == noteID, note == nil { note = payload }
            offset = end + (size % 2 == 1 && end < data.count ? 1 : 0)
        }
        guard let format, format.tag == 1, format.bits == 16, format.channels == 1 || format.channels == 2 else {
            return nil
        }
        guard var pcm, pcm.count >= 2, pcm.count % (Int(format.channels) * 2) == 0 else { return nil }
        var frames = pcm.count / (Int(format.channels) * 2)
        let cap = Int((AppInfo.maxSongSeconds * Double(format.rate)).rounded(.down))
        var truncated = false
        if frames > max(1, cap) {
            // A fold note describes the whole file. Cutting it would make restore lie.
            if note != nil {
                return ParsedWAV(clip: nil, warning: nil, tooLong: true)
            }
            frames = max(1, cap)
            pcm = Data(pcm.prefix(frames * Int(format.channels) * 2))
            truncated = true
        }
        var samples = [Int16]()
        samples.reserveCapacity(frames * Int(format.channels))
        var cursor = 0
        while cursor + 1 < pcm.count {
            samples.append(Int16(bitPattern: readU16(pcm, cursor)))
            cursor += 2
        }
        var mark: FoldMark?
        var warning: String?
        if let note, !truncated {
            switch readNote(note, frames: frames, channels: Int(format.channels), rate: format.rate, pcm: pcm) {
            case .mark(let parsed):
                mark = parsed
            case .warning(let text):
                warning = text
            }
        }
        let clip = Clip(
            samples: samples,
            frames: frames,
            channels: Int(format.channels),
            sampleRate: Double(format.rate),
            name: name,
            truncated: truncated,
            mark: mark
        )
        return ParsedWAV(clip: clip, warning: warning, tooLong: false)
    }

    static func write(_ data: Data, to url: URL, replacing opened: URL?) throws {
        if let opened, sameFile(url, opened) {
            throw FoldError(message: "Dragonfold leaves the original file alone.")
        }
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appendingPathComponent(".dragonfold-\(UUID().uuidString).tmp")
        try data.write(to: temp, options: .atomic)
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw FoldError(message: "Couldn't write \(url.lastPathComponent).")
        }
    }

    static func sameFile(_ left: URL, _ right: URL) -> Bool {
        left.standardizedFileURL.resolvingSymlinksInPath() == right.standardizedFileURL.resolvingSymlinksInPath()
    }

    struct ParsedWAV {
        var clip: Clip?
        var warning: String?
        var tooLong: Bool
    }

    private struct Format {
        var tag: UInt16
        var channels: UInt16
        var rate: UInt32
        var bits: UInt16
    }

    private enum NoteRead {
        case mark(FoldMark)
        case warning(String)
    }

    private static func notePayload(clip: Clip, pcm: Data, rate: UInt32) throws -> Data {
        guard let mark = clip.mark else {
            throw FoldError(message: "There is no fold to write a note for.")
        }
        guard (1...7).contains(mark.passes) else {
            throw FoldError(message: "Passes must be 1 through 7.")
        }
        var note = Data(capacity: noteBytes)
        func u8(_ v: UInt8) { note.append(v) }
        func u16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { note.append(contentsOf: $0) }
        }
        func u32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { note.append(contentsOf: $0) }
        }
        u8(1)
        u8(UInt8(mark.unit.rawValue))
        u8(UInt8(mark.passes))
        var flags: UInt8 = mark.keyed ? 1 : 0
        if mark.reverseRight { flags |= 2 }
        if mark.ownDragon { flags |= 4 }
        u8(flags)
        u32(UInt32(mark.grain))
        u16(UInt16(clip.channels))
        u16(16)
        u32(rate)
        u32(UInt32(clip.frames))
        u32(crc32(pcm))
        return note
    }

    private static func readNote(_ note: Data, frames: Int, channels: Int, rate: UInt32, pcm: Data) -> NoteRead {
        guard note.count == noteBytes, note[0] == 1 else {
            return .warning("This fold note is from a newer Dragonfold. The audio still plays. Restore is not available.")
        }
        guard let unit = AudioUnit(rawValue: Int(note[1])), (1...7).contains(Int(note[2])) else {
            return .warning("The fold note doesn't match this file. The audio still plays.")
        }
        let flags = note[3]
        if flags & ~0x07 != 0 {
            return .warning("The fold note doesn't match this file. The audio still plays.")
        }
        let keyed = flags & 1 != 0
        let reverseRight = flags & 2 != 0
        let ownDragon = flags & 4 != 0
        let grain = Int(readU32(note, 4))
        let noteChannels = Int(readU16(note, 8))
        let bits = readU16(note, 10)
        let noteRate = readU32(note, 12)
        let noteFrames = Int(readU32(note, 16))
        let crc = readU32(note, 20)
        guard grain >= 1, noteChannels == channels, bits == 16, noteRate == rate, noteFrames == frames, crc == crc32(pcm) else {
            return .warning("The fold note doesn't match this audio. The file still plays. Restore is not available.")
        }
        return .mark(FoldMark(
            unit: unit,
            grain: grain,
            passes: Int(note[2]),
            keyed: keyed,
            reverseRight: reverseRight,
            ownDragon: ownDragon
        ))
    }

    private static func readFormat(_ payload: Data) -> Format? {
        guard payload.count >= 16 else { return nil }
        return Format(
            tag: readU16(payload, 0),
            channels: readU16(payload, 2),
            rate: readU32(payload, 4),
            bits: readU16(payload, 14)
        )
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = crcTable[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { index in
            var c = UInt32(index)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    private static func readASCII(_ data: Data, _ offset: Int, _ count: Int) -> String {
        guard offset >= 0, offset + count <= data.count else { return "" }
        let bytes = [UInt8](data[offset..<(offset + count)])
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    private static func readU16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

enum SongError: LocalizedError {
    case unreadable(String)
    case empty
    case tooLong

    var errorDescription: String? {
        switch self {
        case .unreadable(let text): return text
        case .empty: return "That file has no samples."
        case .tooLong: return "That folded file is longer than 10 minutes. Dragonfold left it unopened."
        }
    }
}

enum SongLoader {
    struct Loaded {
        var clip: Clip
        var warning: String?
    }

    static func load(url: URL) throws -> Loaded {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SongError.unreadable("Couldn't read that audio file.")
        }
        let name = url.deletingPathExtension().lastPathComponent
        if let parsed = WAVFile.parse(data, name: name) {
            if parsed.tooLong { throw SongError.tooLong }
            if let clip = parsed.clip {
                return Loaded(clip: clip, warning: parsed.warning)
            }
        }
        let clip = try decode(url: url, name: name)
        return Loaded(clip: clip, warning: nil)
    }

    private static func decode(url: URL, name: String) throws -> Clip {
        if let clip = loadPCMFile(url: url, name: name) {
            return clip
        }
        return try loadCompressedSync(url: url, name: name)
    }

    private static func loadPCMFile(url: URL, name: String) -> Clip? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let rate = format.sampleRate
        guard rate > 0, format.channelCount >= 1, file.length > 0 else { return nil }
        let cap = AVAudioFramePosition((AppInfo.maxSongSeconds * rate).rounded(.down))
        let frames64 = min(file.length, max(1, cap))
        let frames = AVAudioFrameCount(frames64)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        do {
            try file.read(into: buffer, frameCount: frames)
        } catch {
            return nil
        }
        let count = Int(buffer.frameLength)
        guard count > 0, let channels = buffer.floatChannelData else { return nil }
        let channelCount = min(2, Int(format.channelCount))
        var samples = [Int16](repeating: 0, count: count * channelCount)
        for frame in 0..<count {
            samples[frame * channelCount] = quantize(channels[0][frame])
            if channelCount > 1 {
                let right = Int(format.channelCount) > 1 ? channels[1][frame] : channels[0][frame]
                samples[frame * channelCount + 1] = quantize(right)
            }
        }
        return Clip(
            samples: samples,
            frames: count,
            channels: channelCount,
            sampleRate: rate,
            name: name,
            truncated: file.length > frames64,
            mark: nil
        )
    }

    private final class CompressedBox: @unchecked Sendable {
        var clip: Clip?
        var error: Error?
    }

    private static func loadCompressedSync(url: URL, name: String) throws -> Clip {
        let box = CompressedBox()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                box.clip = try await loadCompressed(url, name: name)
            } catch {
                box.error = error
            }
            sem.signal()
        }
        sem.wait()
        if let clip = box.clip { return clip }
        throw box.error ?? SongError.unreadable("Couldn't read that audio file.")
    }

    private static func loadCompressed(_ url: URL, name: String) async throws -> Clip {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw SongError.unreadable("That file has no playable audio.")
        }
        let duration = try await asset.load(.duration)
        var rate = 48_000.0
        var sourceChannels = 2
        if let first = try await track.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(first)?.pointee {
            if asbd.mSampleRate > 0 { rate = asbd.mSampleRate }
            if asbd.mChannelsPerFrame > 0 { sourceChannels = Int(asbd.mChannelsPerFrame) }
        }
        let channelsOut = min(2, max(1, sourceChannels))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channelsOut,
        ]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else {
            throw SongError.unreadable("Couldn't read samples from that file.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw SongError.unreadable("Couldn't read samples from that file.")
        }
        let cap = Int((AppInfo.maxSongSeconds * rate).rounded(.down))
        var samples: [Int16] = []
        samples.reserveCapacity(min(cap, 44_100) * channelsOut)
        var frames = 0
        while frames < cap, let sample = output.copyNextSampleBuffer() {
            append(sample, channels: channelsOut, cap: cap, frames: &frames, samples: &samples)
            CMSampleBufferInvalidate(sample)
        }
        reader.cancelReading()
        guard frames > 0 else { throw SongError.empty }
        let seconds = CMTimeGetSeconds(duration)
        let full = seconds.isFinite && seconds > AppInfo.maxSongSeconds + 0.05
        return Clip(
            samples: samples,
            frames: frames,
            channels: channelsOut,
            sampleRate: rate,
            name: name,
            truncated: full || frames >= cap,
            mark: nil
        )
    }

    private static func append(
        _ sample: CMSampleBuffer,
        channels: Int,
        cap: Int,
        frames: inout Int,
        samples: inout [Int16]
    ) {
        let available = Int(CMSampleBufferGetNumSamples(sample))
        guard available > 0, let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let take = min(available, cap - frames)
        guard take > 0 else { return }
        let byteCount = available * channels * MemoryLayout<Float>.size
        guard CMBlockBufferGetDataLength(block) >= byteCount else { return }
        var pcm = [Float](repeating: 0, count: available * channels)
        let status = pcm.withUnsafeMutableBytes { raw -> OSStatus in
            guard let dest = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: dest)
        }
        guard status == kCMBlockBufferNoErr else { return }
        if channels == 1 {
            for index in 0..<take {
                samples.append(quantize(pcm[index]))
            }
        } else {
            for index in 0..<take {
                samples.append(quantize(pcm[index * channels]))
                samples.append(quantize(pcm[index * channels + 1]))
            }
        }
        frames += take
    }
}

func rateLabel(_ rate: Double) -> String {
    if abs(rate - 44_100) < 1 { return "44.1 kHz" }
    if abs(rate - 48_000) < 1 { return "48 kHz" }
    if abs(rate - 88_200) < 1 { return "88.2 kHz" }
    if abs(rate - 96_000) < 1 { return "96 kHz" }
    if rate >= 1000 { return String(format: "%.1f kHz", rate / 1000) }
    return String(format: "%.0f Hz", rate)
}

func clock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let whole = Int(seconds.rounded(.down))
    return String(format: "%d:%02d", whole / 60, whole % 60)
}

func stemName(from url: URL?) -> String {
    guard let url else { return "Dragonfold" }
    var stem = url.deletingPathExtension().lastPathComponent
    if stem.hasSuffix(".dragon") {
        stem.removeLast(".dragon".count)
    }
    return stem.isEmpty ? "Dragonfold" : stem
}
