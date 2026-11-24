import Foundation

// Exact 8-bit PNG. Filter-none on the way out, every standard filter on the
// way in, so a folded export round-trips the same bytes. The fold note is a
// private ancillary chunk, dsCl, and the phrase is not in it.

@_silgen_name("compress2")
private func zlibCompress2(
    _ dest: UnsafeMutablePointer<UInt8>,
    _ destLen: UnsafeMutablePointer<UInt>,
    _ source: UnsafePointer<UInt8>,
    _ sourceLen: UInt,
    _ level: Int32
) -> Int32

@_silgen_name("compressBound")
private func zlibCompressBound(_ sourceLen: UInt) -> UInt

@_silgen_name("uncompress")
private func zlibUncompress(
    _ dest: UnsafeMutablePointer<UInt8>,
    _ destLen: UnsafeMutablePointer<UInt>,
    _ source: UnsafePointer<UInt8>,
    _ sourceLen: UInt
) -> Int32

enum PNGFile {
    static let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])
    static let noteType = "dsCl"
    static let noteSize = 18

    enum Decoded {
        case picture(pixels: [UInt8], width: Int, height: Int, note: Data?)
        case tooBig(hasNote: Bool)
        case unsupported(note: Data?)
    }

    static func encode(pixels: [UInt8], width: Int, height: Int, note: Data?) throws -> Data {
        guard width > 0, height > 0, pixels.count == width * height * 4 else {
            throw FoldError(message: "That picture is empty.")
        }
        let raw = scanlines(pixels: pixels, width: width, height: height)
        guard let compressed = compress(raw) else {
            throw FoldError(message: "Could not write the PNG.")
        }

        var ihdr = Data()
        appendBE(&ihdr, UInt32(width))
        appendBE(&ihdr, UInt32(height))
        ihdr.append(8)
        ihdr.append(6)
        ihdr.append(0)
        ihdr.append(0)
        ihdr.append(0)

        var file = Data(signature)
        file.append(chunk("IHDR", ihdr))
        file.append(chunk("sRGB", Data([0])))
        var offset = 0
        let limit = 8 * 1024 * 1024
        while offset < compressed.count {
            let end = min(offset + limit, compressed.count)
            file.append(chunk("IDAT", compressed.subdata(in: offset..<end)))
            offset = end
        }
        if let note {
            file.append(chunk(noteType, note))
        }
        file.append(chunk("IEND", Data()))
        return file
    }

    static func notePayload(mark: FoldMark, width: Int, height: Int, pixels: [UInt8]) -> Data {
        var data = Data()
        var flags: UInt8 = mark.keyed ? 1 : 0
        if mark.pair {
            data.append(4)
            if mark.spin { flags |= 2 }
            if mark.split { flags |= 4 }
        } else if mark.split {
            data.append(3)
            if mark.spin { flags |= 2 }
            flags |= 4
        } else if mark.spin {
            data.append(2)
            flags |= 2
        } else {
            data.append(1)
        }
        data.append(UInt8(mark.unit.rawValue))
        data.append(UInt8(mark.passes))
        data.append(flags)
        data.append(UInt8(mark.tile & 0xFF))
        data.append(UInt8((mark.tile >> 8) & 0xFF))
        appendLE(&data, UInt32(width))
        appendLE(&data, UInt32(height))
        appendLE(&data, crc32(pixels))
        return data
    }

    /// The note is trusted only when the sizes and the pixel CRC match.
    static func mark(from payload: Data, pixels: [UInt8], width: Int, height: Int) -> (FoldMark?, String?) {
        let mismatch = "The fold note doesn't match this picture. Restore is not available from the note."
        guard payload.count == noteSize else {
            return (nil, mismatch)
        }
        let version = payload[0]
        if version != 1 && version != 2 && version != 3 && version != 4 {
            return (nil, "The fold note is from a newer Dragonscale. The picture still opens.")
        }
        guard let unit = ImageUnit(rawValue: Int(payload[1])),
              (1...7).contains(Int(payload[2]))
        else {
            return (nil, mismatch)
        }
        let flags = payload[3]
        let keyed: Bool
        let spin: Bool
        let split: Bool
        let pair: Bool
        if version == 1 {
            guard flags == 0 || flags == 1 else { return (nil, mismatch) }
            keyed = flags == 1
            spin = false
            split = false
            pair = false
        } else if version == 2 {
            guard flags & ~0x03 == 0 else { return (nil, mismatch) }
            keyed = flags & 1 != 0
            spin = flags & 2 != 0
            split = false
            pair = false
        } else if version == 3 {
            guard flags & ~0x07 == 0 else { return (nil, mismatch) }
            keyed = flags & 1 != 0
            spin = flags & 2 != 0
            split = flags & 4 != 0
            pair = false
        } else {
            guard flags & ~0x07 == 0 else { return (nil, mismatch) }
            keyed = flags & 1 != 0
            spin = flags & 2 != 0
            split = flags & 4 != 0
            pair = true
        }
        let tile = Int(payload[4]) | (Int(payload[5]) << 8)
        let noteWidth = Int(readLE(payload, 6))
        let noteHeight = Int(readLE(payload, 10))
        let noteCRC = readLE(payload, 14)
        let tileOK = unit == .pixel ? tile == 1 : (1...AppInfo.maxTile).contains(tile)
        let pairOK = !pair || (height % 2 == 0 && height >= 2)
        guard tileOK, pairOK, noteWidth == width, noteHeight == height, noteCRC == crc32(pixels) else {
            return (nil, mismatch)
        }
        let mark = FoldMark(
            unit: unit,
            tile: tile,
            passes: Int(payload[2]),
            keyed: keyed,
            spin: spin,
            split: split,
            pair: pair
        )
        return (mark, nil)
    }

    static func decode(_ data: Data) -> Decoded {
        guard data.count >= 8, data.prefix(8) == signature else {
            return .unsupported(note: nil)
        }
        var offset = 8
        var width = 0
        var height = 0
        var colorType = -1
        var sawIHDR = false
        var sawIEND = false
        var tooBig = false
        var collect = true
        var idat = Data()
        var note: Data?
        var transparency = false
        while offset + 8 <= data.count {
            let length = Int(readBE(data, offset))
            guard length >= 0, data.count - (offset + 8) >= length + 4 else {
                return .unsupported(note: note)
            }
            let typeStart = offset + 4
            let type = ascii(data, typeStart, 4)
            let payload = data[(offset + 8)..<(offset + 8 + length)]
            let declared = readBE(data, offset + 8 + length)
            let expect = crc32(type: type, payload: payload)
            let crcOK = declared == expect
            if type == "IHDR" || type == "IDAT" || type == "IEND" {
                guard crcOK else { return .unsupported(note: note) }
            }
            switch type {
            case "IHDR":
                guard !sawIHDR, payload.count == 13 else { return .unsupported(note: note) }
                sawIHDR = true
                let base = offset + 8
                width = Int(readBE(data, base))
                height = Int(readBE(data, base + 4))
                let depth = data[base + 8]
                colorType = Int(data[base + 9])
                let compression = data[base + 10]
                let filter = data[base + 11]
                let interlace = data[base + 12]
                let simple = depth == 8 && compression == 0 && filter == 0 && interlace == 0
                    && (colorType == 2 || colorType == 6)
                if width <= 0 || height <= 0 || !simple {
                    collect = false
                } else if width > AppInfo.maxSide || height > AppInfo.maxSide * 2 {
                    // A pair file stacks two pictures, so it may be twice as tall as one.
                    tooBig = true
                    collect = false
                }
            case "IDAT":
                if collect { idat.append(payload) }
            case noteType:
                if crcOK { note = Data(payload) }
            case "tRNS":
                // Color type 2 stores transparency here. The exact path would leave alpha at 255.
                if crcOK { transparency = true }
            case "IEND":
                sawIEND = true
            default:
                break
            }
            offset += 12 + length
            if sawIEND { break }
        }
        guard sawIHDR, sawIEND else { return .unsupported(note: note) }
        if tooBig { return .tooBig(hasNote: note != nil) }
        if transparency { return .unsupported(note: note) }
        guard collect, colorType == 2 || colorType == 6 else {
            return .unsupported(note: note)
        }
        let bpp = colorType == 6 ? 4 : 3
        let row = 1 + width * bpp
        guard row > 0, height <= Int.max / row else { return .unsupported(note: note) }
        let expected = height * row
        guard let raw = decompress(idat, expected: expected),
              let pixels = unfilter(raw, width: width, height: height, bpp: bpp)
        else {
            return .unsupported(note: note)
        }
        return .picture(pixels: pixels, width: width, height: height, note: note)
    }

    static func fileData(picture: Picture, includeNote: Bool) throws -> Data {
        let note: Data?
        if includeNote, let mark = picture.mark {
            note = notePayload(mark: mark, width: picture.width, height: picture.height, pixels: picture.pixels)
        } else {
            note = nil
        }
        return try encode(pixels: picture.pixels, width: picture.width, height: picture.height, note: note)
    }

    static func write(_ data: Data, to url: URL, replacing opened: URL?) throws {
        if let opened, sameFile(url, opened) {
            throw FoldError(message: "Dragonscale leaves the original file alone.")
        }
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appendingPathComponent(".dragonscale-\(UUID().uuidString).tmp")
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
        let a = left.standardizedFileURL.resolvingSymlinksInPath()
        let b = right.standardizedFileURL.resolvingSymlinksInPath()
        if a == b { return true }
        // Two names for one inode. Replacing either one would replace the original.
        guard
            let leftID = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
            let rightID = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        else { return false }
        return (leftID as AnyObject).isEqual(rightID)
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = step(crc, byte)
        }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: - Pixels

    private static func scanlines(pixels: [UInt8], width: Int, height: Int) -> Data {
        let stride = width * 4
        var raw = Data()
        raw.reserveCapacity(height * (stride + 1))
        for y in 0..<height {
            raw.append(0)
            let start = y * stride
            raw.append(contentsOf: pixels[start..<(start + stride)])
        }
        return raw
    }

    private static func unfilter(_ raw: [UInt8], width: Int, height: Int, bpp: Int) -> [UInt8]? {
        let stride = width * bpp
        guard stride > 0, raw.count == height * (stride + 1) else { return nil }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var prev = [UInt8](repeating: 0, count: stride)
        var curr = [UInt8](repeating: 0, count: stride)
        var src = 0
        for y in 0..<height {
            let filter = raw[src]
            src += 1
            guard filter <= 4 else { return nil }
            for x in 0..<stride {
                let filt = raw[src]
                src += 1
                let left: UInt8 = x >= bpp ? curr[x - bpp] : 0
                let up = prev[x]
                let upperLeft: UInt8 = x >= bpp ? prev[x - bpp] : 0
                let value: UInt8
                switch filter {
                case 0: value = filt
                case 1: value = filt &+ left
                case 2: value = filt &+ up
                case 3: value = filt &+ UInt8((Int(left) + Int(up)) / 2)
                default: value = filt &+ paeth(left, up, upperLeft)
                }
                curr[x] = value
            }
            if bpp == 4 {
                let dest = y * stride
                for x in 0..<stride {
                    pixels[dest + x] = curr[x]
                }
            } else {
                for pixel in 0..<width {
                    let dest = (y * width + pixel) * 4
                    pixels[dest] = curr[pixel * 3]
                    pixels[dest + 1] = curr[pixel * 3 + 1]
                    pixels[dest + 2] = curr[pixel * 3 + 2]
                }
            }
            swap(&prev, &curr)
        }
        return pixels
    }

    private static func paeth(_ left: UInt8, _ up: UInt8, _ upperLeft: UInt8) -> UInt8 {
        let a = Int(left)
        let b = Int(up)
        let c = Int(upperLeft)
        let estimate = a + b - c
        let da = abs(estimate - a)
        let db = abs(estimate - b)
        let dc = abs(estimate - c)
        if da <= db && da <= dc { return left }
        if db <= dc { return up }
        return upperLeft
    }

    // MARK: - zlib

    private static func compress(_ source: Data) -> Data? {
        guard !source.isEmpty else { return nil }
        let bound = zlibCompressBound(UInt(source.count))
        guard bound > 0, bound <= UInt(Int.max) else { return nil }
        var dest = [UInt8](repeating: 0, count: Int(bound))
        var destLen = bound
        let status: Int32 = source.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return dest.withUnsafeMutableBufferPointer { buf in
                guard let dst = buf.baseAddress else { return -1 }
                return zlibCompress2(dst, &destLen, base, UInt(source.count), 1)
            }
        }
        guard status == 0, destLen > 0, destLen <= bound else { return nil }
        return Data(dest.prefix(Int(destLen)))
    }

    private static func decompress(_ source: Data, expected: Int) -> [UInt8]? {
        guard expected > 0, !source.isEmpty else { return nil }
        var dest = [UInt8](repeating: 0, count: expected)
        var destLen = UInt(expected)
        let status: Int32 = source.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return dest.withUnsafeMutableBufferPointer { buf in
                guard let dst = buf.baseAddress else { return -1 }
                return zlibUncompress(dst, &destLen, base, UInt(source.count))
            }
        }
        guard status == 0, destLen == UInt(expected) else { return nil }
        return dest
    }

    // MARK: - Chunks and integers

    private static func chunk(_ type: String, _ payload: Data) -> Data {
        var out = Data()
        out.reserveCapacity(payload.count + 12)
        appendBE(&out, UInt32(payload.count))
        out.append(contentsOf: type.utf8)
        out.append(payload)
        appendBE(&out, crc32(type: type, payload: payload))
        return out
    }

    private static func crc32(type: String, payload: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in type.utf8 {
            crc = step(crc, byte)
        }
        for byte in payload {
            crc = step(crc, byte)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static func step(_ crc: UInt32, _ byte: UInt8) -> UInt32 {
        crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { index in
            var c = UInt32(index)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    private static func ascii(_ data: Data, _ offset: Int, _ count: Int) -> String {
        guard offset >= 0, offset + count <= data.count else { return "" }
        let bytes = [UInt8](data[offset..<(offset + count)])
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    private static func readBE(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func readLE(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func appendBE(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func appendLE(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}
