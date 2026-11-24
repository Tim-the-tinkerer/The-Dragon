import Compression
import Foundation

/// Lossless frame cache. Each frame is raw RGBA, or LZFSE when that is smaller.
/// The index lives in memory. The file is a scratch file for this session.
final class FrameStore {
    let width: Int
    let height: Int
    let rawCount: Int
    private let directory: URL
    private let handle: FileHandle
    private let lock = NSLock()
    private var entries: [(offset: UInt64, stored: Int, compressed: Bool)] = []
    private var scratch: UnsafeMutablePointer<UInt8>
    private let scratchCount: Int
    private(set) var storedBytes = 0
    private var closed = false

    var count: Int { entries.count }

    init(width: Int, height: Int) throws {
        guard width > 0, height > 0 else {
            throw FoldError(message: "That reel has no picture.")
        }
        self.width = width
        self.height = height
        rawCount = width * height * 4
        scratchCount = rawCount + rawCount / 8 + 256
        scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: scratchCount)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Dragonreel-frames-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("frames.bin")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        self.directory = directory
        handle = try FileHandle(forUpdating: file)
    }

    deinit {
        scratch.deallocate()
        if !closed {
            try? handle.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func append(_ rgba: [UInt8]) throws {
        guard rgba.count == rawCount else {
            throw FoldError(message: "A frame arrived at the wrong size.")
        }
        lock.lock()
        defer { lock.unlock() }
        let compressed = rgba.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(scratch, scratchCount, base, rawCount, nil, COMPRESSION_LZFSE)
        }
        let useCompressed = compressed > 0 && compressed < rawCount
        let stored = useCompressed ? compressed : rawCount
        let offset = try handle.offset()
        if useCompressed {
            try handle.write(contentsOf: Data(bytes: scratch, count: stored))
        } else {
            try handle.write(contentsOf: rgba)
        }
        entries.append((offset, stored, useCompressed))
        storedBytes += stored
    }

    func read(into buffer: inout [UInt8], at index: Int) throws {
        if buffer.count != rawCount {
            buffer = [UInt8](repeating: 0, count: rawCount)
        }
        lock.lock()
        defer { lock.unlock() }
        guard entries.indices.contains(index) else {
            throw FoldError(message: "That frame is outside the reel.")
        }
        let entry = entries[index]
        try handle.seek(toOffset: entry.offset)
        guard let data = try handle.read(upToCount: entry.stored), data.count == entry.stored else {
            throw FoldError(message: "A frame could not be read back.")
        }
        if entry.compressed {
            let decoded = data.withUnsafeBytes { raw -> Int in
                guard let source = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return buffer.withUnsafeMutableBytes { dst -> Int in
                    guard let dest = dst.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(dest, rawCount, source, entry.stored, nil, COMPRESSION_LZFSE)
                }
            }
            guard decoded == rawCount else {
                throw FoldError(message: "A frame could not be read back.")
            }
        } else {
            buffer.withUnsafeMutableBytes { dst in
                data.withUnsafeBytes { src in
                    dst.copyMemory(from: src)
                }
            }
        }
    }

    func destroy() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try? handle.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Interleaved 16-bit sound for one session. The file is scratch, not a format.
final class SoundStore {
    let channels: Int
    private let directory: URL
    private let handle: FileHandle
    private let lock = NSLock()
    private(set) var frames = 0
    private var closed = false

    init(channels: Int) throws {
        guard channels == 1 || channels == 2 else {
            throw FoldError(message: "Could not store the sound.")
        }
        self.channels = channels
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Dragonreel-sound-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("sound.pcm")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        self.directory = directory
        handle = try FileHandle(forUpdating: file)
    }

    deinit {
        if !closed {
            try? handle.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func append(_ samples: [Int16]) throws {
        guard channels > 0, samples.count.isMultiple(of: channels) else {
            throw FoldError(message: "The sound could not be stored.")
        }
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let written = try samples.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            try handle.write(contentsOf: Data(bytes: base, count: raw.count))
            return raw.count
        }
        guard written == samples.count * MemoryLayout<Int16>.size else {
            throw FoldError(message: "The sound could not be stored.")
        }
        frames += samples.count / channels
    }

    func read(frame: Int, count: Int) throws -> [Int16] {
        guard frame >= 0, count > 0, frame + count <= frames else {
            throw FoldError(message: "The sound could not be read.")
        }
        let values = count * channels
        let offset = UInt64(frame) * UInt64(channels) * UInt64(MemoryLayout<Int16>.size)
        lock.lock()
        defer { lock.unlock() }
        try handle.seek(toOffset: offset)
        let byteCount = values * MemoryLayout<Int16>.size
        guard let data = try handle.read(upToCount: byteCount), data.count == byteCount else {
            throw FoldError(message: "The sound could not be read.")
        }
        var out = [Int16](repeating: 0, count: values)
        _ = out.withUnsafeMutableBytes { dst in
            data.copyBytes(to: dst)
        }
        return out
    }

    func destroy() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try? handle.close()
        try? FileManager.default.removeItem(at: directory)
    }
}
