import CZlib
import Darwin
import Foundation

// A small ZIP reader and writer for folder packages.
// Store and raw deflate only. Names are UTF-8 when they leave ASCII.
// The reader also accepts the cp437 names Python writes for some directories.

enum DragonZip {
    struct Member {
        var name: String
        var isDirectory: Bool
        var method: UInt16
        var crc: UInt32
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var localHeaderOffset: UInt64
        var externalAttr: UInt32
        var flags: UInt16
        var nextOffset: UInt64
    }

    enum Method {
        case store
        case deflate

        var code: UInt16 {
            switch self {
            case .store: return 0
            case .deflate: return 8
            }
        }
    }

    static func write(
        members: [(url: URL, name: String, isDirectory: Bool)],
        to destination: URL,
        method: Method
    ) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        let writer = Writer(handle: handle, method: method)
        for member in members {
            if member.isDirectory {
                try writer.addDirectory(name: member.name, url: member.url)
            } else {
                try writer.addFile(name: member.name, url: member.url)
            }
        }
        try writer.finish()
    }

    static func members(in archive: URL) throws -> [Member] {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        guard let located = try locateCentralDirectory(handle: handle, fileSize: end) else {
            throw DragonError.message("The folder package does not contain a ZIP archive.")
        }
        var records: [Member] = []
        var position = located.offset
        let endOfDirectory = located.offset + located.size
        while position < endOfDirectory {
            if endOfDirectory - position < 46 {
                throw DragonError.message("The archive directory is damaged.")
            }
            try handle.seek(toOffset: position)
            let fixed = try readExact(handle, 46)
            guard fixed.u32(0) == 0x02014B50 else {
                throw DragonError.message("The archive directory is damaged.")
            }
            let flags = fixed.u16(8)
            let method = fixed.u16(10)
            let crc = fixed.u32(16)
            var compressed = UInt64(fixed.u32(20))
            var uncompressed = UInt64(fixed.u32(24))
            let nameLength = Int(fixed.u16(28))
            let extraLength = Int(fixed.u16(30))
            let commentLength = Int(fixed.u16(32))
            let external = fixed.u32(38)
            var localOffset = UInt64(fixed.u32(42))
            let nameBytes = try readExact(handle, nameLength)
            let extra = try readExact(handle, extraLength)
            _ = try readExact(handle, commentLength)
            try applyZip64(extra: extra, fileSize: &uncompressed, compressSize: &compressed, offset: &localOffset)
            let name = try decodeName(nameBytes, utf8: flags & 0x800 != 0)
            records.append(Member(
                name: name,
                isDirectory: name.hasSuffix("/"),
                method: method,
                crc: crc,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                localHeaderOffset: localOffset,
                externalAttr: external,
                flags: flags,
                nextOffset: 0
            ))
            position += UInt64(46 + nameLength + extraLength + commentLength)
        }
        if position != endOfDirectory {
            throw DragonError.message("The archive directory is damaged.")
        }
        let ordered = records.enumerated().sorted { $0.element.localHeaderOffset < $1.element.localHeaderOffset }
        var limits = [Int: UInt64]()
        for (index, item) in ordered.enumerated() {
            let limit = index + 1 < ordered.count ? ordered[index + 1].element.localHeaderOffset : located.offset
            limits[item.offset] = limit
        }
        return records.enumerated().map { index, member in
            var copy = member
            copy.nextOffset = limits[index] ?? located.offset
            return copy
        }
    }

    static func extract(_ member: Member, from archive: URL, toPath path: String) throws {
        if member.flags & 0x01 != 0 || member.flags & 0x40 != 0 {
            throw DragonError.message("Encrypted archive members are not supported.")
        }
        if member.method != 0 && member.method != 8 {
            throw DragonError.message("The archive uses a compression method Dragon Curve does not read.")
        }
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        try handle.seek(toOffset: member.localHeaderOffset)
        let fixed = try readExact(handle, 30)
        guard fixed.u32(0) == 0x04034B50 else {
            throw DragonError.message("The archive file header is damaged.")
        }
        let flags = fixed.u16(6)
        let nameLength = Int(fixed.u16(26))
        let extraLength = Int(fixed.u16(28))
        let nameBytes = try readExact(handle, nameLength)
        _ = try readExact(handle, extraLength)
        let localName = try decodeName(nameBytes, utf8: flags & 0x800 != 0)
        if localName != member.name {
            throw DragonError.message("The archive name does not match its directory.")
        }
        let dataStart = try handle.offset()
        if dataStart + member.compressedSize > member.nextOffset {
            throw DragonError.message("The archive has overlapping entries.")
        }
        if member.isDirectory {
            return
        }
        let fd = path.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY, 0o644) }
        guard fd >= 0 else {
            let name = path.split(separator: "/").last.map(String.init) ?? path
            throw DragonError.message("Could not create \(name).")
        }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let crc: UInt32
        let produced: UInt64
        if member.method == 0 {
            guard member.compressedSize == member.uncompressedSize else {
                throw DragonError.message("The archive stored size does not match.")
            }
            let copied = try copyBytes(from: handle, count: member.compressedSize, to: output)
            crc = copied.crc
            produced = copied.uncompressed
        } else {
            let inflated = try inflateBytes(
                from: handle,
                compressed: member.compressedSize,
                expected: member.uncompressedSize,
                to: output
            )
            crc = inflated.crc
            produced = inflated.count
        }
        if produced != member.uncompressedSize || crc != member.crc {
            throw DragonError.message("The archive checksum does not match.")
        }
    }

    // MARK: - Writer

    private final class Writer {
        let handle: FileHandle
        let method: Method
        var entries: [Written] = []

        init(handle: FileHandle, method: Method) {
            self.handle = handle
            self.method = method
        }

        func addDirectory(name: String, url: URL) throws {
            let info = try fileStat(url)
            let when = dosStamp(info.mtime)
            let nameBytes = try encodedName(name)
            let attr = UInt32(info.mode & 0xFFFF) << 16 | 0x10
            let offset = try handle.offset()
            let header = localHeader(
                name: nameBytes.bytes,
                utf8: nameBytes.utf8,
                method: 0,
                crc: 0,
                compressed: 0,
                uncompressed: 0,
                zip64: false,
                time: when.time,
                date: when.date
            )
            try handle.write(contentsOf: header)
            entries.append(Written(
                name: nameBytes.bytes,
                utf8: nameBytes.utf8,
                method: 0,
                crc: 0,
                compressedSize: 0,
                uncompressedSize: 0,
                localOffset: offset,
                externalAttr: attr,
                zip64: false,
                dosTime: when.time,
                dosDate: when.date
            ))
        }

        func addFile(name: String, url: URL) throws {
            let info = try fileStat(url)
            let when = dosStamp(info.mtime)
            let nameBytes = try encodedName(name)
            let zip64 = info.size > 0xFFFF_FFFF || info.size > (0xFFFF_FFFF * 20) / 21
            let offset = try handle.offset()
            let placeholder = localHeader(
                name: nameBytes.bytes,
                utf8: nameBytes.utf8,
                method: method.code,
                crc: 0,
                compressed: zip64 ? 0xFFFF_FFFF : 0,
                uncompressed: zip64 ? 0xFFFF_FFFF : 0,
                zip64: zip64,
                time: when.time,
                date: when.date
            )
            try handle.write(contentsOf: placeholder)
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            let compressed: (crc: UInt32, uncompressed: UInt64, compressed: UInt64)
            if method == .store {
                compressed = try copyBytes(from: input, count: nil, to: handle)
            } else {
                compressed = try deflateBytes(from: input, to: handle)
            }
            if !zip64 && (compressed.uncompressed > 0xFFFF_FFFF || compressed.compressed > 0xFFFF_FFFF) {
                throw DragonError.message("That file needs ZIP64 and did not reserve it.")
            }
            let end = try handle.offset()
            let header = localHeader(
                name: nameBytes.bytes,
                utf8: nameBytes.utf8,
                method: method.code,
                crc: compressed.crc,
                compressed: compressed.compressed,
                uncompressed: compressed.uncompressed,
                zip64: zip64,
                time: when.time,
                date: when.date
            )
            guard header.count == placeholder.count else {
                throw DragonError.message("Could not finish the archive header.")
            }
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: header)
            try handle.seek(toOffset: end)
            entries.append(Written(
                name: nameBytes.bytes,
                utf8: nameBytes.utf8,
                method: method.code,
                crc: compressed.crc,
                compressedSize: compressed.compressed,
                uncompressedSize: compressed.uncompressed,
                localOffset: offset,
                externalAttr: UInt32(info.mode & 0xFFFF) << 16,
                zip64: zip64,
                dosTime: when.time,
                dosDate: when.date
            ))
        }

        func finish() throws {
            let directoryStart = try handle.offset()
            for entry in entries {
                try handle.write(contentsOf: centralRecord(entry))
            }
            let directoryEnd = try handle.offset()
            let count = UInt64(entries.count)
            let size = directoryEnd - directoryStart
            let needsZip64 = count > 0xFFFF || directoryStart > 0xFFFF_FFFF || size > 0xFFFF_FFFF
            if needsZip64 {
                var record = Data()
                record.appendU32(0x06064B50)
                record.appendU64(44)
                record.appendU16(45)
                record.appendU16(45)
                record.appendU32(0)
                record.appendU32(0)
                record.appendU64(count)
                record.appendU64(count)
                record.appendU64(size)
                record.appendU64(directoryStart)
                try handle.write(contentsOf: record)
                var locator = Data()
                locator.appendU32(0x07064B50)
                locator.appendU32(0)
                locator.appendU64(directoryEnd)
                locator.appendU32(1)
                try handle.write(contentsOf: locator)
            }
            var end = Data()
            end.appendU32(0x06054B50)
            end.appendU16(0)
            end.appendU16(0)
            end.appendU16(UInt16(min(count, 0xFFFF)))
            end.appendU16(UInt16(min(count, 0xFFFF)))
            end.appendU32(UInt32(min(size, 0xFFFF_FFFF)))
            end.appendU32(UInt32(min(directoryStart, 0xFFFF_FFFF)))
            end.appendU16(0)
            try handle.write(contentsOf: end)
        }

        func centralRecord(_ entry: Written) -> Data {
            centralHeader(entry)
        }
    }

    struct Written {
        var name: Data
        var utf8: Bool
        var method: UInt16
        var crc: UInt32
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var localOffset: UInt64
        var externalAttr: UInt32
        var zip64: Bool
        var dosTime: UInt16
        var dosDate: UInt16
    }
}

private struct LocatedDirectory {
    var offset: UInt64
    var size: UInt64
}

private func locateCentralDirectory(handle: FileHandle, fileSize: UInt64) throws -> LocatedDirectory? {
    if fileSize < 22 { return nil }
    let window = min(fileSize, 65_557)
    try handle.seek(toOffset: fileSize - window)
    let tail = try readExact(handle, Int(window))
    var index = tail.count - 22
    while index >= 0 {
        if tail.u32(index) == 0x06054B50 {
            let comment = Int(tail.u16(index + 20))
            if index + 22 + comment == tail.count {
                let absolute = fileSize - window + UInt64(index)
                var count = UInt64(tail.u16(index + 10))
                var size = UInt64(tail.u32(index + 12))
                var offset = UInt64(tail.u32(index + 16))
                if count == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF {
                    guard absolute >= 20 else { return nil }
                    try handle.seek(toOffset: absolute - 20)
                    let locator = try readExact(handle, 20)
                    guard locator.u32(0) == 0x07064B50 else {
                        throw DragonError.message("The archive ZIP64 directory is missing.")
                    }
                    let recordOffset = locator.u64(8)
                    try handle.seek(toOffset: recordOffset)
                    let record = try readExact(handle, 56)
                    guard record.u32(0) == 0x06064B50 else {
                        throw DragonError.message("The archive ZIP64 directory is damaged.")
                    }
                    count = record.u64(32)
                    size = record.u64(40)
                    offset = record.u64(48)
                }
                return LocatedDirectory(offset: offset, size: size)
            }
        }
        index -= 1
    }
    return nil
}

private func applyZip64(extra: Data, fileSize: inout UInt64, compressSize: inout UInt64, offset: inout UInt64) throws {
    var cursor = 0
    while cursor + 4 <= extra.count {
        let tag = extra.u16(cursor)
        let length = Int(extra.u16(cursor + 2))
        let start = cursor + 4
        guard length >= 0, start + length <= extra.count else {
            throw DragonError.message("The archive extra field is damaged.")
        }
        if tag == 1 {
            var field = extra.subdata(in: start..<(start + length))
            func take() throws -> UInt64 {
                guard field.count >= 8 else {
                    throw DragonError.message("The archive ZIP64 field is damaged.")
                }
                let value = field.u64(0)
                field.removeFirst(8)
                return value
            }
            if fileSize == 0xFFFF_FFFF { fileSize = try take() }
            if compressSize == 0xFFFF_FFFF { compressSize = try take() }
            if offset == 0xFFFF_FFFF { offset = try take() }
        }
        cursor = start + length
    }
}

private func localHeader(
    name: Data,
    utf8: Bool,
    method: UInt16,
    crc: UInt32,
    compressed: UInt64,
    uncompressed: UInt64,
    zip64: Bool,
    time: UInt16,
    date: UInt16
) -> Data {
    var extra = Data()
    var storedCompressed = compressed
    var storedUncompressed = uncompressed
    if zip64 {
        extra.appendU16(1)
        extra.appendU16(16)
        extra.appendU64(uncompressed)
        extra.appendU64(compressed)
        storedCompressed = 0xFFFF_FFFF
        storedUncompressed = 0xFFFF_FFFF
    }
    var data = Data()
    data.appendU32(0x04034B50)
    data.appendU16(zip64 ? 45 : 20)
    data.appendU16(utf8 ? 0x0800 : 0)
    data.appendU16(method)
    data.appendU16(time)
    data.appendU16(date)
    data.appendU32(crc)
    data.appendU32(UInt32(storedCompressed))
    data.appendU32(UInt32(storedUncompressed))
    data.appendU16(UInt16(name.count))
    data.appendU16(UInt16(extra.count))
    data.append(name)
    data.append(extra)
    return data
}

private func centralHeader(_ entry: DragonZip.Written) -> Data {
    var extra = Data()
    var compressed = entry.compressedSize
    var uncompressed = entry.uncompressedSize
    var offset = entry.localOffset
    if entry.zip64 || compressed > 0xFFFF_FFFF {
        extra.appendU64(uncompressed)
        uncompressed = 0xFFFF_FFFF
    }
    if entry.zip64 || entry.compressedSize > 0xFFFF_FFFF {
        extra.appendU64(entry.compressedSize)
        compressed = 0xFFFF_FFFF
    }
    if offset > 0xFFFF_FFFF {
        extra.appendU64(entry.localOffset)
        offset = 0xFFFF_FFFF
    }
    if !extra.isEmpty {
        var wrapped = Data()
        wrapped.appendU16(1)
        wrapped.appendU16(UInt16(extra.count))
        wrapped.append(extra)
        extra = wrapped
    }
    let version: UInt16 = extra.isEmpty ? 20 : 45
    var data = Data()
    data.appendU32(0x02014B50)
    data.append(UInt8(version))
    data.append(3)
    data.append(UInt8(version))
    data.append(0)
    data.appendU16(entry.utf8 ? 0x0800 : 0)
    data.appendU16(entry.method)
    data.appendU16(entry.dosTime)
    data.appendU16(entry.dosDate)
    data.appendU32(entry.crc)
    data.appendU32(UInt32(min(compressed, 0xFFFF_FFFF)))
    data.appendU32(UInt32(min(uncompressed, 0xFFFF_FFFF)))
    data.appendU16(UInt16(entry.name.count))
    data.appendU16(UInt16(extra.count))
    data.appendU16(0)
    data.appendU16(0)
    data.appendU16(0)
    data.appendU32(entry.externalAttr)
    data.appendU32(UInt32(min(offset, 0xFFFF_FFFF)))
    data.append(entry.name)
    data.append(extra)
    return data
}

private func encodedName(_ name: String) throws -> (bytes: Data, utf8: Bool) {
    let bytes = Data(name.utf8)
    let ascii = bytes.allSatisfy { $0 < 128 }
    return (bytes, !ascii)
}

private struct FileStat {
    var mode: mode_t
    var size: UInt64
    var mtime: Date
}

private func fileStat(_ url: URL) throws -> FileStat {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
        throw DragonError.message("\(url.lastPathComponent) could not be read.")
    }
    let mode = info.st_mode
    if mode & S_IFMT == S_IFLNK {
        throw DragonError.message("Symbolic links are not supported: \(url.lastPathComponent)")
    }
    let seconds = info.st_mtimespec.tv_sec
    return FileStat(mode: mode, size: UInt64(info.st_size), mtime: Date(timeIntervalSince1970: TimeInterval(seconds)))
}

private func dosStamp(_ date: Date) -> (time: UInt16, date: UInt16) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    var year = parts.year ?? 1980
    if year < 1980 { year = 1980 }
    if year > 2107 { year = 2107 }
    let month = min(max(parts.month ?? 1, 1), 12)
    let day = min(max(parts.day ?? 1, 1), 31)
    let hour = min(max(parts.hour ?? 0, 0), 23)
    let minute = min(max(parts.minute ?? 0, 0), 59)
    let second = min(max(parts.second ?? 0, 0), 59)
    let dosDate = UInt16((year - 1980) << 9 | month << 5 | day)
    let dosTime = UInt16(hour << 11 | minute << 5 | (second / 2))
    return (dosTime, dosDate)
}

private func deflateBytes(from input: FileHandle, to output: FileHandle) throws -> (crc: UInt32, uncompressed: UInt64, compressed: UInt64) {
    var stream: UnsafeMutableRawPointer?
    guard dragon_deflate_init(&stream, DRAGON_Z_DEFAULT_COMPRESSION) == DRAGON_Z_OK, let stream else {
        throw DragonError.message("Could not start compression.")
    }
    defer { dragon_deflate_end(stream) }
    var crc: UInt32 = 0
    var totalIn: UInt64 = 0
    var totalOut: UInt64 = 0
    var inputDone = false
    var pending = Data()
    var outBuf = [UInt8](repeating: 0, count: 65_536)
    while true {
        if pending.isEmpty && !inputDone {
            let chunk = try input.read(upToCount: 65_536) ?? Data()
            if chunk.isEmpty {
                inputDone = true
            } else {
                crc = crc32(crc, chunk)
                totalIn += UInt64(chunk.count)
                pending = chunk
            }
        }
        let finish = inputDone && pending.isEmpty
        var consumed = 0
        var produced = 0
        let rc: Int32 = pending.withUnsafeBytes { raw in
            outBuf.withUnsafeMutableBytes { outRaw in
                dragon_deflate_process(
                    stream,
                    raw.bindMemory(to: UInt8.self).baseAddress,
                    raw.count,
                    &consumed,
                    outRaw.bindMemory(to: UInt8.self).baseAddress,
                    outRaw.count,
                    &produced,
                    finish ? 1 : 0
                )
            }
        }
        if consumed > pending.count { throw DragonError.message("Could not compress the folder.") }
        if consumed > 0 { pending.removeFirst(consumed) }
        if produced > 0 {
            try output.write(contentsOf: Data(outBuf.prefix(produced)))
            totalOut += UInt64(produced)
        }
        if rc == DRAGON_Z_STREAM_END { break }
        if rc != DRAGON_Z_OK && rc != -5 {
            throw DragonError.message("Could not compress the folder.")
        }
        if consumed == 0 && produced == 0 {
            throw DragonError.message("Could not compress the folder.")
        }
    }
    return (crc, totalIn, totalOut)
}

private func inflateBytes(
    from input: FileHandle,
    compressed: UInt64,
    expected: UInt64,
    to output: FileHandle
) throws -> (crc: UInt32, count: UInt64) {
    var stream: UnsafeMutableRawPointer?
    guard dragon_inflate_init(&stream) == DRAGON_Z_OK, let stream else {
        throw DragonError.message("Could not read the archive.")
    }
    defer { dragon_inflate_end(stream) }
    var crc: UInt32 = 0
    var producedTotal: UInt64 = 0
    var consumedTotal: UInt64 = 0
    var pending = Data()
    var outBuf = [UInt8](repeating: 0, count: 65_536)
    var ended = false
    while !ended {
        if pending.isEmpty && consumedTotal < compressed {
            let want = Int(min(UInt64(65_536), compressed - consumedTotal))
            let chunk = try readExact(input, want)
            consumedTotal += UInt64(chunk.count)
            pending = chunk
        }
        var consumed = 0
        var produced = 0
        var streamEnded: Int32 = 0
        let rc: Int32 = pending.withUnsafeBytes { raw in
            outBuf.withUnsafeMutableBytes { outRaw in
                dragon_inflate_process(
                    stream,
                    raw.bindMemory(to: UInt8.self).baseAddress,
                    raw.count,
                    &consumed,
                    outRaw.bindMemory(to: UInt8.self).baseAddress,
                    outRaw.count,
                    &produced,
                    &streamEnded
                )
            }
        }
        if consumed > pending.count { throw DragonError.message("Could not read the archive.") }
        if consumed > 0 { pending.removeFirst(consumed) }
        if produced > 0 {
            let piece = Data(outBuf.prefix(produced))
            producedTotal += UInt64(piece.count)
            if producedTotal > expected {
                throw DragonError.message("The archive expanded past its declared size.")
            }
            crc = crc32(crc, piece)
            try output.write(contentsOf: piece)
        }
        if streamEnded != 0 { ended = true; break }
        if rc != DRAGON_Z_OK && rc != -5 {
            throw DragonError.message("Could not read the archive.")
        }
        if consumed == 0 && produced == 0 {
            throw DragonError.message("Could not read the archive.")
        }
    }
    if !pending.isEmpty || consumedTotal != compressed || producedTotal != expected {
        throw DragonError.message("The archive contents do not match the directory.")
    }
    return (crc, producedTotal)
}

private func copyBytes(from input: FileHandle, count: UInt64?, to output: FileHandle) throws -> (crc: UInt32, uncompressed: UInt64, compressed: UInt64) {
    var crc: UInt32 = 0
    var total: UInt64 = 0
    var remaining = count
    while remaining == nil || remaining! > 0 {
        let want = Int(min(remaining ?? 65_536, 65_536))
        guard let chunk = try input.read(upToCount: want), !chunk.isEmpty else { break }
        crc = crc32(crc, chunk)
        try output.write(contentsOf: chunk)
        total += UInt64(chunk.count)
        if remaining != nil { remaining! -= UInt64(chunk.count) }
    }
    if let count, total != count {
        throw DragonError.message("The archive ended early.")
    }
    return (crc, total, total)
}

private func crc32(_ crc: UInt32, _ data: Data) -> UInt32 {
    data.withUnsafeBytes { raw in
        dragon_crc32(crc, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
    }
}

private func readExact(_ handle: FileHandle, _ count: Int) throws -> Data {
    if count == 0 { return Data() }
    var data = Data()
    data.reserveCapacity(count)
    while data.count < count {
        guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
            throw DragonError.message("The archive ended early.")
        }
        data.append(chunk)
    }
    return data
}

private func decodeName(_ bytes: Data, utf8: Bool) throws -> String {
    if utf8 || bytes.allSatisfy({ $0 < 128 }) {
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw DragonError.message("The archive name is not UTF-8.")
        }
        return text
    }
    var scalars: [Unicode.Scalar] = []
    scalars.reserveCapacity(bytes.count)
    for byte in bytes {
        let value: UInt32
        if byte < 128 {
            value = UInt32(byte)
        } else {
            value = cp437[Int(byte) - 128]
        }
        guard let scalar = Unicode.Scalar(value) else {
            throw DragonError.message("The archive name could not be read.")
        }
        scalars.append(scalar)
    }
    return String(String.UnicodeScalarView(scalars))
}

private let cp437: [UInt32] = [
    199, 252, 233, 226, 228, 224, 229, 231, 234, 235, 232, 239, 238, 236, 196, 197,
    201, 230, 198, 244, 246, 242, 251, 249, 255, 214, 220, 162, 163, 165, 8359, 402,
    225, 237, 243, 250, 241, 209, 170, 186, 191, 8976, 172, 189, 188, 161, 171, 187,
    9617, 9618, 9619, 9474, 9508, 9569, 9570, 9558, 9557, 9571, 9553, 9559, 9565, 9564, 9563, 9488,
    9492, 9524, 9516, 9500, 9472, 9532, 9566, 9567, 9562, 9556, 9577, 9574, 9568, 9552, 9580, 9575,
    9576, 9572, 9573, 9561, 9560, 9554, 9555, 9579, 9578, 9496, 9484, 9608, 9604, 9612, 9616, 9600,
    945, 223, 915, 960, 931, 963, 181, 964, 934, 920, 937, 948, 8734, 966, 949, 8745,
    8801, 177, 8805, 8804, 8992, 8993, 247, 8776, 176, 8729, 183, 8730, 8319, 178, 9632, 160,
]

private extension Data {
    func u16(_ offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func u32(_ offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    func u64(_ offset: Int) -> UInt64 {
        UInt64(u32(offset)) | (UInt64(u32(offset + 4)) << 32)
    }

    mutating func appendU16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendU32(_ value: UInt32) {
        appendU16(UInt16(value & 0xFFFF))
        appendU16(UInt16((value >> 16) & 0xFFFF))
    }

    mutating func appendU64(_ value: UInt64) {
        appendU32(UInt32(value & 0xFFFF_FFFF))
        appendU32(UInt32((value >> 32) & 0xFFFF_FFFF))
    }
}

