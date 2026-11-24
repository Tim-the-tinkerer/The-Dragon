import Foundation

enum DragonFiles {
    static func siblingPath(for url: URL, decrypting: Bool) -> URL {
        let name = url.lastPathComponent
        let stem: String
        let suffix: String
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            stem = String(name[..<dot])
            suffix = String(name[dot...])
        } else {
            stem = name
            suffix = ""
        }
        let outName: String
        if decrypting && stem.hasSuffix(".dragon") {
            outName = String(stem.dropLast(".dragon".count)) + suffix
        } else if decrypting && suffix == ".dragon" {
            outName = stem
        } else if decrypting {
            outName = stem + ".plain" + suffix
        } else {
            outName = stem + ".dragon" + suffix
        }
        return url.deletingLastPathComponent().appendingPathComponent(outName)
    }

    static func sameFile(_ left: URL, _ right: URL) -> Bool {
        let a = left.resolvingSymlinksInPath().standardizedFileURL.path
        let b = right.resolvingSymlinksInPath().standardizedFileURL.path
        return a == b
    }

    static func write(
        urls: [URL],
        key: String,
        unit: DragonEngine.Unit,
        passes: Int?,
        header: Bool,
        decrypting: Bool,
        scrambleName: Bool = false,
        output: URL? = nil
    ) throws -> [URL] {
        if urls.isEmpty {
            throw DragonError.message("Drop a file first.")
        }
        if urls.count > 64 {
            throw DragonError.message("Drop up to 64 files at a time.")
        }
        if output != nil && urls.count != 1 {
            throw DragonError.message("One output path needs a single file.")
        }
        if scrambleName && !decrypting && !header {
            throw DragonError.message("A scrambled name needs the version header.")
        }

        var planned: [(source: URL, destination: URL, data: Data, token: String?)] = []
        var seen = Set<String>()
        for url in urls {
            try ensureFile(url)
            let data = try Data(contentsOf: url)
            try checkSize(data, unit: unit, decrypting: decrypting)
            let token: String?
            let destination: URL
            if decrypting {
                if let header = try DragonEngine.readDataHeader(data), let nameToken = header.nameToken {
                    let restored = try DragonEngine.restoreFilename(nameToken, key: key)
                    token = nameToken
                    destination = output ?? url.deletingLastPathComponent().appendingPathComponent(restored)
                } else {
                    token = nil
                    destination = output ?? siblingPath(for: url, decrypting: true)
                }
            } else if scrambleName {
                let scrambled = try DragonEngine.scrambleFilename(url.lastPathComponent, key: key)
                token = scrambled
                destination = output ?? DragonFolder.neutralPath(for: url, token: scrambled)
            } else {
                token = nil
                destination = output ?? siblingPath(for: url, decrypting: false)
            }
            let identity = destination.resolvingSymlinksInPath().standardizedFileURL.path
            if seen.contains(identity) {
                throw DragonError.message("\(destination.lastPathComponent) is already the output of another file")
            }
            seen.insert(identity)
            if sameFile(url, destination) {
                throw DragonError.message("output would replace the input file \(url.lastPathComponent)")
            }
            if DragonFolder.kind(destination) != .missing {
                throw DragonError.message("\(destination.lastPathComponent) already exists. Move it, or choose another name.")
            }
            planned.append((url, destination, data, token))
        }

        var jobs: [(URL, Data)] = []
        for item in planned {
            let result: Data
            if decrypting {
                result = try DragonEngine.openFile(item.data, key: key, unit: unit, passes: passes)
            } else {
                result = try DragonEngine.encodeData(
                    item.data,
                    key: key,
                    unit: unit,
                    passes: passes,
                    header: header,
                    nameToken: item.token
                )
            }
            jobs.append((item.destination, result))
        }

        var written: [URL] = []
        for (destination, result) in jobs {
            try writeAtomically(result, to: destination)
            written.append(destination)
        }
        return written
    }

    static func runSelfTest() -> [DragonEngine.Failure] {
        var failures: [DragonEngine.Failure] = []
        func expect(_ name: String, _ got: String, _ want: String) {
            if got != want {
                failures.append(.init(name: name, expected: want, actual: got))
            }
        }
        expect(
            "sibling encrypt",
            siblingPath(for: URL(fileURLWithPath: "/tmp/note.txt"), decrypting: false).lastPathComponent,
            "note.dragon.txt"
        )
        expect(
            "sibling decrypt",
            siblingPath(for: URL(fileURLWithPath: "/tmp/note.dragon.txt"), decrypting: true).lastPathComponent,
            "note.txt"
        )
        expect(
            "suffix decrypt",
            siblingPath(for: URL(fileURLWithPath: "/tmp/file.dragon"), decrypting: true).lastPathComponent,
            "file"
        )
        expect(
            "plain decrypt",
            siblingPath(for: URL(fileURLWithPath: "/tmp/readme"), decrypting: true).lastPathComponent,
            "readme.plain"
        )
        expect(
            "photo encrypt",
            siblingPath(for: URL(fileURLWithPath: "/tmp/photo.bin"), decrypting: false).lastPathComponent,
            "photo.dragon.bin"
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dragon-curve-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = directory.appendingPathComponent("photo.bin")
            var payload = Data()
            for value in 0..<256 {
                payload.append(UInt8(value))
            }
            payload.append(contentsOf: [0, 255])
            try payload.write(to: source)
            let folded = try write(
                urls: [source],
                key: "x",
                unit: .bit,
                passes: 4,
                header: true,
                decrypting: false
            )
            let sealed = try Data(contentsOf: folded[0])
            let restoredURL = directory.appendingPathComponent("recovered.bin")
            let opened = try write(
                urls: folded,
                key: "x",
                unit: .byte,
                passes: nil,
                header: true,
                decrypting: true,
                output: restoredURL
            )
            let restored = try Data(contentsOf: opened[0])
            if restored != payload {
                failures.append(.init(name: "file round trip", expected: "photo.bin", actual: "\(restored.count) bytes"))
            }
            if try Data(contentsOf: source) != payload {
                failures.append(.init(name: "original kept", expected: "unchanged", actual: "changed"))
            }
            if !sealed.starts(with: Data("DRAGON-CURVE-DATA/3 ".utf8)) {
                failures.append(.init(name: "file header", expected: "v3 header", actual: "missing"))
            }
            let hidden = try write(
                urls: [source],
                key: "paper",
                unit: .byte,
                passes: 4,
                header: true,
                decrypting: false,
                scrambleName: true,
                output: directory.appendingPathComponent("named.dragon")
            )
            let hiddenData = try Data(contentsOf: hidden[0])
            guard let token = try DragonEngine.readDataHeader(hiddenData)?.nameToken else {
                failures.append(.init(name: "scramble header", expected: "name token", actual: "missing"))
                return failures
            }
            if (try? DragonEngine.restoreFilename(token, key: "paper")) != "photo.bin" {
                failures.append(.init(name: "scramble name", expected: "photo.bin", actual: token))
            }
            let recoveredName = directory.appendingPathComponent("photo-restored.bin")
            _ = try write(
                urls: hidden,
                key: "paper",
                unit: .byte,
                passes: nil,
                header: true,
                decrypting: true,
                output: recoveredName
            )
            if try Data(contentsOf: recoveredName) != payload {
                failures.append(.init(name: "scramble round trip", expected: "photo.bin", actual: "mismatch"))
            }
            do {
                _ = try write(
                    urls: [source],
                    key: "x",
                    unit: .byte,
                    passes: 1,
                    header: true,
                    decrypting: false
                )
                failures.append(.init(name: "refuse existing", expected: "throw", actual: "wrote"))
            } catch {
                // The folded file is already beside the original.
            }
        } catch {
            failures.append(.init(name: "file self-test", expected: "round trip", actual: error.localizedDescription))
        }
        return failures
    }

    private static func ensureFile(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw DragonError.message("\(url.lastPathComponent) is missing")
        }
        if isDirectory.boolValue {
            throw DragonError.message("\(url.lastPathComponent) is a directory")
        }
    }

    private static func checkSize(_ data: Data, unit: DragonEngine.Unit, decrypting: Bool) throws {
        if data.count > DragonEngine.Unit.byte.maxBytes {
            throw DragonError.message(
                "Dragon Curve stops at \(DragonEngine.Unit.byte.maxBytes) bytes. This file has \(data.count)."
            )
        }
        if decrypting, let described = DragonEngine.describedInput(data) {
            if described.count > described.unit.maxBytes {
                throw DragonError.message(
                    "\(described.unit.title) mode stops at \(described.unit.maxBytes) bytes. This file has \(described.count)."
                )
            }
            return
        }
        if data.count > unit.maxBytes {
            throw DragonError.message(
                "\(unit.title) mode stops at \(unit.maxBytes) bytes. This file has \(data.count)."
            )
        }
    }

    private static func writeAtomically(_ data: Data, to destination: URL) throws {
        let folder = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw DragonError.message("\(destination.lastPathComponent) already exists. Move it, or choose another name.")
        }
        let temp = folder.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temp, options: .atomic)
        do {
            try FileManager.default.moveItem(at: temp, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw DragonError.message("could not write \(destination.lastPathComponent)")
        }
    }
}
