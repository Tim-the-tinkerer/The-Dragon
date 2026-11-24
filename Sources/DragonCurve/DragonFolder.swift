import CryptoKit
import Darwin
import Foundation

// Folder packages follow dragon_curve.py.
// The folder is zipped, optionally woven across 16 stripes, then each chunk
// is rearranged on the dragon curve. FOLDER/1 has no weave. FOLDER/2 does.
// A SHA-256 of the zip detects a wrong phrase or a changed byte. It is not a MAC.

enum DragonFolder {
    static let lanes = 16
    static let maxUnits = 16_384

    enum Compression: String, CaseIterable, Identifiable {
        case deflate
        case store

        var id: String { rawValue }

        var title: String {
            switch self {
            case .deflate: return "Deflate"
            case .store: return "Store"
            }
        }

        var detail: String {
            switch self {
            case .deflate: return "ZIP compresses the folder, then the curve rearranges it."
            case .store: return "ZIP stores the bytes as they are, then the curve rearranges them."
            }
        }
    }

    enum Kind {
        case file
        case directory
        case symlink
        case special
        case missing
    }

    static func kind(_ url: URL) -> Kind {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .missing }
        let mode = info.st_mode & S_IFMT
        if mode == S_IFLNK { return .symlink }
        if mode == S_IFDIR { return .directory }
        if mode == S_IFREG { return .file }
        return .special
    }

    static func chunkBytes(for unit: DragonEngine.Unit) -> Int? {
        switch unit {
        case .byte: return 16_384
        case .hex: return 8_192
        case .bit: return 2_048
        case .character: return nil
        }
    }

    static func neutralPath(for source: URL, token: String) -> URL {
        let digest = SHA256.hash(data: Data(token.utf8))
        let hex = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return source.deletingLastPathComponent().appendingPathComponent("dc-\(hex).dragon")
    }

    static func defaultEncodedPath(for source: URL, key: String, scramble: Bool) throws -> URL {
        if scramble {
            let token = try DragonEngine.scrambleFilename(source.lastPathComponent, key: key)
            return neutralPath(for: source, token: token)
        }
        return source.deletingLastPathComponent().appendingPathComponent(source.lastPathComponent + ".dragon")
    }

    static func encode(
        source: URL,
        output: URL? = nil,
        key: String = "",
        unit: DragonEngine.Unit = .byte,
        passes: Int? = nil,
        scrambleName: Bool = false,
        compression: Compression = .deflate,
        crossWeave: Bool = false
    ) throws -> URL {
        guard let chunk = chunkBytes(for: unit) else {
            throw DragonError.message("Folder mode uses byte, hex digit, or bit. Character is for a single file.")
        }
        guard kind(source) == .directory else {
            throw DragonError.message("\(source.lastPathComponent) is not a folder.")
        }
        _ = try DragonEngine.validateFilename(source.lastPathComponent)
        let count = try DragonEngine.resolvedPassCount(key: key, passes: passes)
        let destination = try output ?? defaultEncodedPath(for: source, key: key, scramble: scrambleName)
        if isInside(destination, of: source) {
            throw DragonError.message("The package has to be saved outside the folder.")
        }
        try ensureFree(destination)
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temp = parent.appendingPathComponent(".dragon-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temp) }

        let archive = temp.appendingPathComponent("source.zip")
        let members = try collect(source)
        try DragonZip.write(
            members: members,
            to: archive,
            method: compression == .deflate ? .deflate : .store
        )
        let digest = try sha256Hex(archive)
        let totalSize = try fileSize(archive)
        guard totalSize > 0 else {
            throw DragonError.message("The folder archive is empty.")
        }
        let token = scrambleName ? try DragonEngine.scrambleFilename(source.lastPathComponent, key: key) : nil
        let version = crossWeave ? 2 : 1
        let weaveField = crossWeave ? " weave=\(lanes)" : ""
        let nameField = token.map { " name=\($0)" } ?? ""
        let header = "DRAGON-CURVE-FOLDER/\(version) mode=\(unit.rawValue) passes=\(count) key=\(key.isEmpty ? 0 : 1) chunk=\(chunk) bytes=\(totalSize) sha256=\(digest)\(weaveField)\(nameField)\n"
        guard Data(header.utf8).count <= 2048 else {
            throw DragonError.message("The folder header does not fit.")
        }

        var transformInput = archive
        if crossWeave {
            transformInput = temp.appendingPathComponent("woven.tmp")
            try weave(
                source: archive,
                destination: transformInput,
                key: key,
                passes: count,
                chunkBytes: chunk,
                originalBytes: totalSize,
                reverse: false
            )
        }
        let staged = temp.appendingPathComponent("package.tmp")
        FileManager.default.createFile(atPath: staged.path, contents: nil)
        do {
            let outputHandle = try FileHandle(forWritingTo: staged)
            let inputHandle = try FileHandle(forReadingFrom: transformInput)
            defer {
                try? outputHandle.close()
                try? inputHandle.close()
            }
            try outputHandle.write(contentsOf: Data(header.utf8))
            var index = 0
            while true {
                guard let block = try inputHandle.read(upToCount: chunk), !block.isEmpty else { break }
                let piece = try transform(block, key: key, index: index, unit: unit, passes: count, reverse: false)
                try outputHandle.write(contentsOf: piece)
                index += 1
            }
        }
        try commitFile(staged, to: destination)
        return destination
    }

    static func decode(source: URL, output: URL? = nil, key: String = "") throws -> URL {
        guard kind(source) == .file else {
            throw DragonError.message("\(source.lastPathComponent) is not a folder package.")
        }
        let parent = output?.deletingLastPathComponent() ?? source.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temp = parent.appendingPathComponent(".dragon-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temp) }

        let archive = temp.appendingPathComponent("restored.zip")
        let restoredName = try unpack(source: source, key: key, archive: archive)
        let listing = try DragonZip.members(in: archive)
        let root = try checkedRoot(listing)
        if let restoredName, restoredName != root {
            throw DragonError.message("The stored folder name does not match the archive.")
        }
        let destination = output ?? source.deletingLastPathComponent().appendingPathComponent(root)
        try ensureFree(destination)
        let stage = temp.appendingPathComponent("restored_folder", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        try extract(listing, from: archive, into: stage)
        try ensureFree(destination)
        try FileManager.default.moveItem(at: stage, to: destination)
        return destination
    }

    static func runSelfTest() -> [DragonEngine.Failure] {
        var failures: [DragonEngine.Failure] = []
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dragon-folder-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = directory.appendingPathComponent("Lab Folder", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: source.appendingPathComponent("Empty", isDirectory: true),
                withIntermediateDirectories: true
            )
            try Data("café Δ\n".utf8).write(to: source.appendingPathComponent("Readme.md"))
            try Data([0x00, 0xFF, 0x01]).write(to: source.appendingPathComponent(".hidden"))
            var bulky = Data(repeating: 0x61, count: 20_000)
            bulky.append(contentsOf: (0..<256).map { UInt8($0) })
            try bulky.write(to: source.appendingPathComponent("bulk.bin"))

            let plain = try encode(source: source, key: "Dragon_Curve", unit: .byte, passes: 4, compression: .deflate)
            if try Data(contentsOf: plain).starts(with: Data("DRAGON-CURVE-FOLDER/1 ".utf8)) == false {
                failures.append(.init(name: "folder header", expected: "FOLDER/1", actual: "missing"))
            }
            let restored = try decode(source: plain, output: directory.appendingPathComponent("back"), key: "Dragon_Curve")
            if try Data(contentsOf: restored.appendingPathComponent("bulk.bin")) != bulky {
                failures.append(.init(name: "folder bytes", expected: "bulk.bin", actual: "mismatch"))
            }
            if !FileManager.default.fileExists(atPath: restored.appendingPathComponent("Empty").path) {
                failures.append(.init(name: "empty dir", expected: "kept", actual: "missing"))
            }
            if try Data(contentsOf: source.appendingPathComponent("Readme.md")) != Data("café Δ\n".utf8) {
                failures.append(.init(name: "original folder", expected: "unchanged", actual: "changed"))
            }

            let woven = try encode(
                source: source,
                key: "Dragon_Curve",
                unit: .bit,
                passes: 7,
                scrambleName: true,
                compression: .store,
                crossWeave: true
            )
            if !woven.lastPathComponent.hasPrefix("dc-") || woven.pathExtension != "dragon" {
                failures.append(.init(name: "scrambled package", expected: "dc-….dragon", actual: woven.lastPathComponent))
            }
            let wovenBytes = try Data(contentsOf: woven)
            if !wovenBytes.starts(with: Data("DRAGON-CURVE-FOLDER/2 ".utf8)) || !wovenBytes.contains(Data(" weave=16".utf8)) {
                failures.append(.init(name: "weave header", expected: "FOLDER/2 weave=16", actual: "missing"))
            }
            let revived = try decode(source: woven, output: directory.appendingPathComponent("woven-back"), key: "Dragon_Curve")
            if try Data(contentsOf: revived.appendingPathComponent("Readme.md")) != Data("café Δ\n".utf8) {
                failures.append(.init(name: "weave text", expected: "Readme.md", actual: "mismatch"))
            }
            if try Data(contentsOf: revived.appendingPathComponent(".hidden")) != Data([0x00, 0xFF, 0x01]) {
                failures.append(.init(name: "weave hidden", expected: "3 bytes", actual: "mismatch"))
            }

            let scratch = directory.appendingPathComponent("weave.bin")
            let wovenFile = directory.appendingPathComponent("weave.out")
            let backFile = directory.appendingPathComponent("weave.back")
            let sample = Data(repeating: 0x41, count: 100) + Data(repeating: 0x42, count: 50)
            try sample.write(to: scratch)
            try weave(source: scratch, destination: wovenFile, key: "Key", passes: 3, chunkBytes: 2048, originalBytes: UInt64(sample.count), reverse: false)
            try weave(source: wovenFile, destination: backFile, key: "Key", passes: 3, chunkBytes: 2048, originalBytes: UInt64(sample.count), reverse: true)
            if try Data(contentsOf: backFile) != sample {
                failures.append(.init(name: "weave pad", expected: "round trip", actual: "mismatch"))
            }

            do {
                _ = try decode(source: plain, output: directory.appendingPathComponent("wrong"), key: "nope")
                failures.append(.init(name: "folder wrong key", expected: "throw", actual: "restored"))
            } catch {
                if kind(directory.appendingPathComponent("wrong")) != .missing {
                    failures.append(.init(name: "folder wrong key leftover", expected: "absent", actual: "present"))
                }
            }
        } catch {
            failures.append(.init(name: "folder self-test", expected: "round trip", actual: error.localizedDescription))
        }
        return failures
    }

    // MARK: - Chunks

    static func transform(
        _ block: Data,
        key: String,
        index: Int,
        unit: DragonEngine.Unit,
        passes: Int,
        reverse: Bool
    ) throws -> Data {
        let values = try units(of: block, unit: unit)
        let count = values.count
        if count == 0 { return Data() }
        let pair = try DragonEngine.folderPermutation(length: count, key: key, passes: passes)
        let span = index % count
        let rotate = (span * 7919) % count
        let mixed: [UInt8]
        if reverse {
            let shifted = rotate == 0 ? values : Array(values[(count - rotate)...]) + Array(values[..<(count - rotate)])
            mixed = (0..<count).map { shifted[pair.inverse[$0]] }
        } else {
            var arranged = (0..<count).map { values[pair.forward[$0]] }
            if rotate != 0 {
                arranged = Array(arranged[rotate...]) + Array(arranged[..<rotate])
            }
            mixed = arranged
        }
        return try pack(mixed, unit: unit)
    }

    private static func units(of block: Data, unit: DragonEngine.Unit) throws -> [UInt8] {
        switch unit {
        case .byte:
            return [UInt8](block)
        case .hex:
            var nibbles: [UInt8] = []
            nibbles.reserveCapacity(block.count * 2)
            for byte in block {
                nibbles.append(byte >> 4)
                nibbles.append(byte & 0x0F)
            }
            return nibbles
        case .bit:
            var bits: [UInt8] = []
            bits.reserveCapacity(block.count * 8)
            for byte in block {
                for shift in stride(from: 7, through: 0, by: -1) {
                    bits.append((byte >> shift) & 1)
                }
            }
            return bits
        case .character:
            throw DragonError.message("Folder mode uses byte, hex digit, or bit.")
        }
    }

    private static func pack(_ values: [UInt8], unit: DragonEngine.Unit) throws -> Data {
        switch unit {
        case .byte:
            return Data(values)
        case .hex:
            guard values.count.isMultiple(of: 2) else {
                throw DragonError.message("The folder chunk is an odd number of hex digits.")
            }
            var out = Data(count: values.count / 2)
            for index in stride(from: 0, to: values.count, by: 2) {
                out[index / 2] = (values[index] << 4) | values[index + 1]
            }
            return out
        case .bit:
            guard values.count.isMultiple(of: 8) else {
                throw DragonError.message("The folder chunk is not a whole number of bytes.")
            }
            var out = Data(count: values.count / 8)
            for index in stride(from: 0, to: values.count, by: 8) {
                var byte: UInt8 = 0
                for bit in 0..<8 {
                    byte |= values[index + bit] << (7 - bit)
                }
                out[index / 8] = byte
            }
            return out
        case .character:
            throw DragonError.message("Folder mode uses byte, hex digit, or bit.")
        }
    }

    static func weave(
        source: URL,
        destination: URL,
        key: String,
        passes: Int,
        chunkBytes: Int,
        originalBytes: UInt64,
        reverse: Bool
    ) throws {
        guard chunkBytes > 0, chunkBytes.isMultiple(of: lanes) else {
            throw DragonError.message("The weave chunk size is not usable.")
        }
        guard originalBytes > 0, originalBytes <= UInt64(Int.max) else {
            throw DragonError.message("The folder archive length is not usable.")
        }
        let original = Int(originalBytes)
        let chunks = (original + chunkBytes - 1) / chunkBytes
        let (padded, overflow) = chunks.multipliedReportingOverflow(by: chunkBytes)
        guard !overflow, padded > 0 else {
            throw DragonError.message("The folder archive is too large to weave.")
        }
        let stripe = chunkBytes / lanes
        let offsets = try weaveOffsets(chunks: chunks, key: key, passes: passes)
        let expectedInput = reverse ? padded : original
        guard try fileSize(source) == UInt64(expectedInput) else {
            throw DragonError.message("The weave length does not match the header.")
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let incoming = try FileHandle(forReadingFrom: source)
        let outgoing = try FileHandle(forUpdating: destination)
        defer {
            try? incoming.close()
            try? outgoing.close()
        }
        try outgoing.truncate(atOffset: UInt64(padded))
        for row in 0..<chunks {
            var block = try readUpTo(incoming, chunkBytes)
            if block.count != chunkBytes {
                if reverse || row != chunks - 1 {
                    throw DragonError.message("The weave data ended early.")
                }
                block.append(Data(repeating: 0, count: chunkBytes - block.count))
            }
            for (lane, displacement) in offsets.enumerated() {
                let target = reverse
                    ? (row - displacement) % chunks
                    : (row + displacement) % chunks
                let normalized = target < 0 ? target + chunks : target
                let start = lane * stripe
                try outgoing.seek(toOffset: UInt64(normalized * chunkBytes + start))
                try outgoing.write(contentsOf: block.subdata(in: start..<(start + stripe)))
            }
        }
        if reverse {
            if padded > original {
                try outgoing.seek(toOffset: UInt64(original))
                let tail = try readUpTo(outgoing, padded - original)
                if tail.count != padded - original || tail.contains(where: { $0 != 0 }) {
                    throw DragonError.message("Wrong key, or the weave padding is damaged.")
                }
                try outgoing.truncate(atOffset: UInt64(original))
            }
        }
    }

    private static func weaveOffsets(chunks: Int, key: String, passes: Int) throws -> [Int] {
        guard chunks >= 1 else {
            throw DragonError.message("The folder archive length is not usable.")
        }
        var step = max(1, chunks / lanes)
        while gcd(step, chunks) != 1 {
            step += 1
        }
        let digest = DragonEngine.fnv1a64(Data(("Dragon-Curve-Folder/v2/weave:" + key).utf8))
        let base = Int(digest % UInt64(chunks))
        let order = try DragonEngine.folderPermutation(length: lanes, key: key + "/weave", passes: passes).forward
        return order.map { lane in
            Int((Int64(base) + Int64(step) * Int64(lane)) % Int64(chunks))
        }
    }

    // MARK: - Package

    private struct Header {
        var mode: DragonEngine.Unit
        var passes: Int
        var keyed: Bool
        var chunkBytes: Int
        var totalBytes: UInt64
        var sha256: String
        var nameToken: String?
        var woven: Bool
    }

    private static func unpack(source: URL, key: String, archive: URL) throws -> String? {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let probe = try readUpTo(input, 2048)
        guard let newline = probe.firstIndex(of: 0x0A) else {
            throw DragonError.message("The folder header is missing or too long.")
        }
        let line = probe[..<newline]
        guard let text = String(data: line, encoding: .ascii) else {
            throw DragonError.message("The folder header is not readable.")
        }
        let header = try parseHeader(text)
        if header.keyed != !key.isEmpty {
            throw DragonError.message("The key does not match the folder header. Leave the phrase empty only when the folder had none.")
        }
        try input.seek(toOffset: UInt64(newline + 1))
        let padded = ((header.totalBytes + UInt64(header.chunkBytes) - 1) / UInt64(header.chunkBytes)) * UInt64(header.chunkBytes)
        let expected = header.woven ? padded : header.totalBytes
        let transformed = header.woven ? archive.deletingLastPathComponent().appendingPathComponent("chunks.tmp") : archive
        FileManager.default.createFile(atPath: transformed.path, contents: nil)
        var total: UInt64 = 0
        do {
            let sink = try FileHandle(forWritingTo: transformed)
            defer { try? sink.close() }
            var index = 0
            while true {
                guard let block = try input.read(upToCount: header.chunkBytes), !block.isEmpty else { break }
                let piece = try transform(block, key: key, index: index, unit: header.mode, passes: header.passes, reverse: true)
                total += UInt64(piece.count)
                if total > expected {
                    throw DragonError.message("The folder is longer than its header says.")
                }
                try sink.write(contentsOf: piece)
                index += 1
            }
        }
        if total != expected {
            throw DragonError.message("The folder length does not match its header.")
        }
        if header.woven {
            try weave(
                source: transformed,
                destination: archive,
                key: key,
                passes: header.passes,
                chunkBytes: header.chunkBytes,
                originalBytes: header.totalBytes,
                reverse: true
            )
        }
        let digest = try sha256Hex(archive)
        if digest != header.sha256 {
            throw DragonError.message("Wrong key, or the folder package is damaged.")
        }
        if let token = header.nameToken {
            return try DragonEngine.restoreFilename(token, key: key)
        }
        return nil
    }

    private static func parseHeader(_ text: String) throws -> Header {
        let pattern = #"^DRAGON-CURVE-FOLDER/([12]) mode=(byte|hex|bit) passes=([1-7]) key=([01]) chunk=([0-9]{1,5}) bytes=([0-9]{1,20}) sha256=([0-9a-f]{64})( weave=16)?(?: name=([A-Za-z0-9_-]{1,1000}))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            throw DragonError.message("The folder header is not a Dragon Curve folder package.")
        }
        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swift = Range(range, in: text) else { return nil }
            return String(text[swift])
        }
        guard let version = group(1),
              let modeName = group(2),
              let mode = DragonEngine.Unit(rawValue: modeName),
              let passes = group(3).flatMap(Int.init),
              let keyed = group(4),
              let chunk = group(5).flatMap(Int.init),
              let bytes = group(6).flatMap(UInt64.init),
              let digest = group(7) else {
            throw DragonError.message("The folder header is not a Dragon Curve folder package.")
        }
        let woven = group(8) != nil
        if woven != (version == "2") {
            throw DragonError.message("The folder weave flag does not match the package version.")
        }
        guard chunkBytes(for: mode) == chunk else {
            throw DragonError.message("The folder chunk size is not one this app reads.")
        }
        guard bytes > 0 else {
            throw DragonError.message("The folder archive length is not usable.")
        }
        return Header(
            mode: mode,
            passes: passes,
            keyed: keyed == "1",
            chunkBytes: chunk,
            totalBytes: bytes,
            sha256: digest,
            nameToken: group(9),
            woven: woven
        )
    }

    private static func collect(_ folder: URL) throws -> [(url: URL, name: String, isDirectory: Bool)] {
        let root = try DragonEngine.validateFilename(folder.lastPathComponent)
        var entries: [(URL, String, Bool)] = []
        func visit(current: URL, relative: String) throws {
            entries.append((current, relative + "/", true))
            let children = try FileManager.default.contentsOfDirectory(at: current, includingPropertiesForKeys: nil)
            for child in children.sorted(by: { nameLess($0.lastPathComponent, $1.lastPathComponent) }) {
                let childName = child.lastPathComponent
                _ = try DragonEngine.validateFilename(childName)
                switch kind(child) {
                case .symlink:
                    throw DragonError.message("Symbolic links are not supported: \(childName)")
                case .directory:
                    try visit(current: child, relative: relative + "/" + childName)
                case .file:
                    entries.append((child, relative + "/" + childName, false))
                case .missing:
                    throw DragonError.message("\(childName) disappeared while the folder was read.")
                case .special:
                    throw DragonError.message("\(childName) is not a regular file.")
                }
            }
        }
        try visit(current: folder, relative: root)
        return entries
    }

    private static func checkedRoot(_ members: [DragonZip.Member]) throws -> String {
        if members.isEmpty {
            throw DragonError.message("The folder archive is empty.")
        }
        var roots = Set<String>()
        var found = Set<String>()
        var files = Set<String>()
        var folders = Set<String>()
        for member in members {
            let raw = member.name
            if raw.isEmpty || raw.hasPrefix("/") || raw.contains("\\") || raw.contains("\0") {
                throw DragonError.message("The archive contains an unsafe path.")
            }
            let components = raw.hasSuffix("/") ? String(raw.dropLast()).split(separator: "/", omittingEmptySubsequences: false) : raw.split(separator: "/", omittingEmptySubsequences: false)
            if components.isEmpty || components.contains(where: { $0.isEmpty }) {
                throw DragonError.message("The archive contains an empty path component.")
            }
            for component in components {
                _ = try DragonEngine.validateFilename(String(component))
            }
            let stripped = components.joined(separator: "/")
            if found.contains(stripped) {
                throw DragonError.message("The archive repeats a path.")
            }
            found.insert(stripped)
            roots.insert(String(components[0]))
            if roots.count > 1 {
                throw DragonError.message("The archive contains more than one top folder.")
            }
            let mode = member.externalAttr >> 16
            let format = mode & 0o170000
            if format == 0o120000 {
                throw DragonError.message("The archive contains a symbolic link.")
            }
            if member.isDirectory {
                if format != 0 && format != 0o040000 {
                    throw DragonError.message("The archive contains a directory that is not a directory.")
                }
                folders.insert(stripped)
            } else {
                if format != 0 && format != 0o100000 {
                    throw DragonError.message("The archive contains a file Dragon Curve does not restore.")
                }
                files.insert(stripped)
            }
        }
        guard let root = roots.first, folders.contains(root) else {
            throw DragonError.message("The archive does not start with a folder.")
        }
        for name in found {
            let parts = name.split(separator: "/").map(String.init)
            if parts.count > 1 {
                for index in 1..<parts.count {
                    let parent = parts.prefix(index).joined(separator: "/")
                    if files.contains(parent) {
                        throw DragonError.message("The archive uses a file as a folder.")
                    }
                }
            }
        }
        return root
    }

    private static func extract(_ members: [DragonZip.Member], from archive: URL, into stage: URL) throws {
        // POSIX create keeps the archive's Unicode spelling. URL path helpers
        // rewrite it to the decomposed form macOS uses for display.
        let root = stage.path
        for member in members {
            let parts = Array(member.name.split(separator: "/").map(String.init).dropFirst())
            if parts.isEmpty { continue }
            let path = exactPath(root, parts)
            if member.isDirectory {
                try makeDirectories(path)
            } else {
                try makeDirectories(parentExact(path))
                try DragonZip.extract(member, from: archive, toPath: path)
            }
        }
    }

    private static func exactPath(_ root: String, _ parts: [String]) -> String {
        var path = root
        if path.hasSuffix("/") { path.removeLast() }
        for part in parts {
            path += "/" + part
        }
        return path
    }

    private static func parentExact(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        let parent = path[..<slash]
        return parent.isEmpty ? "/" : String(parent)
    }

    private static func makeDirectories(_ path: String) throws {
        var built = ""
        for part in path.split(separator: "/", omittingEmptySubsequences: false) {
            if part.isEmpty {
                built = ""
                continue
            }
            built += "/" + part
            try makeDirectory(built)
        }
    }

    private static func makeDirectory(_ path: String) throws {
        let created = path.withCString { mkdir($0, 0o755) }
        if created != 0 && errno != EEXIST {
            throw DragonError.message("Could not create a folder from the archive.")
        }
    }

    // MARK: - Paths

    private static func isInside(_ destination: URL, of source: URL) -> Bool {
        let root = source.resolvingSymlinksInPath().standardizedFileURL.path
        let dest = destination.resolvingSymlinksInPath().standardizedFileURL.path
        if dest == root { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return dest.hasPrefix(prefix)
    }

    private static func ensureFree(_ url: URL) throws {
        if kind(url) != .missing {
            throw DragonError.message("\(url.lastPathComponent) already exists. Move it, or choose another name.")
        }
    }

    private static func commitFile(_ staged: URL, to destination: URL) throws {
        try ensureFree(destination)
        do {
            try FileManager.default.linkItem(at: staged, to: destination)
            return
        } catch {
            let fd = open(destination.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            guard fd >= 0 else {
                throw DragonError.message("\(destination.lastPathComponent) already exists. Move it, or choose another name.")
            }
            let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                let input = try FileHandle(forReadingFrom: staged)
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                }
            } catch {
                try? output.close()
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }
    }

    private static func fileSize(_ url: URL) throws -> UInt64 {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw DragonError.message("\(url.lastPathComponent) could not be read.")
        }
        return UInt64(info.st_size)
    }

    private static func sha256Hex(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func readUpTo(_ handle: FileHandle, _ count: Int) throws -> Data {
        if count <= 0 { return Data() }
        return try handle.read(upToCount: count) ?? Data()
    }

    private static func nameLess(_ left: String, _ right: String) -> Bool {
        let a = Array(left.unicodeScalars)
        let b = Array(right.unicodeScalars)
        for index in 0..<min(a.count, b.count) where a[index].value != b[index].value {
            return a[index].value < b[index].value
        }
        return a.count < b.count
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = abs(a)
        var y = abs(b)
        while y != 0 {
            let next = x % y
            x = y
            y = next
        }
        return x
    }
}
