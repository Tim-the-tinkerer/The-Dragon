import Foundation

enum CurveCLI {
    static func failureReport() -> String? {
        var failures = DragonEngine.runSelfTest()
        failures.append(contentsOf: DragonFiles.runSelfTest())
        failures.append(contentsOf: DragonFolder.runSelfTest())
        if failures.isEmpty { return nil }
        var lines = ["SELF-TEST FAILED (\(failures.count))"]
        for failure in failures {
            lines.append("  \(failure.name)\n    expected: \(failure.expected)\n    actual:   \(failure.actual)")
        }
        return lines.joined(separator: "\n")
    }

    /// Runs a command-line job. `nil` means these arguments asked for the window.
    static func dispatch(_ arguments: [String]) -> Int32? {
        let args = Array(arguments.dropFirst())
        if args.contains("--self-test") {
            if let report = failureReport() {
                fputs(report + "\n", stderr)
                return 1
            }
            print("SELF-TEST OK")
            print("Hello → olleH. Key paper → loeHl.")
            return 0
        }
        if args.contains("--help") || args.contains("-h") {
            print(helpText)
            return 0
        }
        if args.contains("--version") {
            print("Dragon Curve \(DragonEngine.version) (\(DragonEngine.build))")
            return 0
        }
        if args.contains("--encrypt") || args.contains("--decrypt")
            || args.contains("--encrypt-file") || args.contains("--decrypt-file")
            || args.contains("--encrypt-folder") || args.contains("--decrypt-folder") {
            return runCLI(args)
        }
        if args.contains(where: { $0.hasPrefix("-") }) {
            fputs("DragonCurve: unknown option\n\(usage)\n", stderr)
            return 2
        }
        LaunchFiles.urls = args.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        return nil
    }

    static let usage = """
    usage: DragonCurve [--encrypt | --decrypt] [--key PHRASE] [--passes N] [--header] [--map] [TEXT]
           DragonCurve [--encrypt-file | --decrypt-file] [--unit character|hex|byte|bit] [--passes N] [--key PHRASE] [--no-header] [--scramble-name] [--output PATH] FILE
           DragonCurve [--encrypt-folder | --decrypt-folder] [--unit byte|hex|bit] [--passes N] [--key PHRASE] [--compression deflate|store] [--cross-weave] [--scramble-name] [--output PATH] FOLDER
    """

    static let helpText = """
    Dragon Curve — a paperfolding transposition

    \(usage)

    DragonCurve
    DragonCurve --self-test
    DragonCurve --encrypt Hello
    DragonCurve --encrypt --key paper Hello
    DragonCurve --decrypt --key paper loeHl
    DragonCurve --encrypt-file --unit byte --key paper --scramble-name note.txt
    DragonCurve --encrypt-folder --compression store --cross-weave --key paper Folder

    A phrase makes 4 to 7 passes. An empty phrase is one pass on the plain curve.
    Text is the modern character permutation. --header writes DRAGON-CURVE-DATA/3.
    TEXT/1 and TEXT/2 are retired. File mode writes DRAGON-CURVE-DATA/3 unless --no-header is set.
    --scramble-name stores the original name in the header and writes a dc- name.
    A folder becomes DRAGON-CURVE-FOLDER/1, or /2 when --cross-weave is set.
    The phrase is not stored. The original is never replaced.
    This rearranges the message. It is not a substitute for FileVault.
    """

    static func runCLI(_ args: [String]) -> Int32 {
        do {
            let parsed = try ParsedArgs(args)
            if parsed.map {
                let plain = parsed.decrypt ? "" : parsed.words.joined(separator: " ")
                if !plain.isEmpty {
                    fputs(DragonEngine.describeCurve(key: parsed.key, passes: parsed.passes) + "\n", stderr)
                }
            }
            if parsed.encryptFolder || parsed.decryptFolder {
                guard let file = parsed.file else {
                    throw DragonError.message("give a folder")
                }
                let source = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
                let output = parsed.output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                let written: URL
                if parsed.decryptFolder {
                    written = try DragonFolder.decode(source: source, output: output, key: parsed.key)
                } else {
                    let unit = parsed.unit ?? .byte
                    guard unit != .character else {
                        throw DragonError.message("folder mode must be byte, hex, or bit")
                    }
                    written = try DragonFolder.encode(
                        source: source,
                        output: output,
                        key: parsed.key,
                        unit: unit,
                        passes: parsed.passes,
                        scrambleName: parsed.scrambleName,
                        compression: parsed.compression,
                        crossWeave: parsed.crossWeave
                    )
                }
                print(written.path)
                return 0
            }
            if parsed.encryptFile || parsed.decryptFile {
                let unit = parsed.unit ?? .byte
                guard let file = parsed.file else {
                    throw DragonError.message("give a file")
                }
                let source = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
                let output = parsed.output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                let written = try DragonFiles.write(
                    urls: [source],
                    key: parsed.key,
                    unit: unit,
                    passes: parsed.passes,
                    header: !parsed.noHeader,
                    decrypting: parsed.decryptFile,
                    scrambleName: parsed.scrambleName,
                    output: output
                )
                for url in written {
                    print(url.path)
                }
                return 0
            }
            let text = parsed.words.joined(separator: " ")
            let result: String
            if parsed.decrypt {
                result = try DragonEngine.decryptDocument(data: text, key: parsed.key, passes: parsed.passes)
            } else {
                result = try DragonEngine.encryptDocument(
                    text: text,
                    key: parsed.key,
                    header: parsed.header,
                    passes: parsed.passes
                )
            }
            if let output = parsed.output {
                let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
                try Data(result.utf8).write(to: url, options: .atomic)
                fputs("DragonCurve: wrote \(url.path)\n", stderr)
            }
            print(result)
            return 0
        } catch {
            fputs("DragonCurve: \(error.localizedDescription)\n", stderr)
            if let dragon = error as? DragonError, dragon.isUsage {
                fputs(usage + "\n", stderr)
                return 2
            }
            return 1
        }
    }
}

private struct ParsedArgs {
    var encrypt = false
    var decrypt = false
    var encryptFile = false
    var decryptFile = false
    var encryptFolder = false
    var decryptFolder = false
    var header = false
    var noHeader = false
    var map = false
    var scrambleName = false
    var crossWeave = false
    var compression = DragonFolder.Compression.deflate
    var key = ""
    var unit: DragonEngine.Unit?
    var passes: Int?
    var output: String?
    var file: String?
    var words: [String] = []

    init(_ args: [String]) throws {
        var index = 0
        var seenKey = false
        func fail(_ text: String) throws -> Never {
            throw DragonError.usage(text)
        }
        func value(for flag: String, inline: String?) throws -> String {
            if let inline {
                if inline.isEmpty { try fail("\(flag) needs a value") }
                return inline
            }
            guard index + 1 < args.count else { try fail("\(flag) needs a value") }
            index += 1
            let next = args[index]
            if next.hasPrefix("-") { try fail("\(flag) needs a value") }
            return next
        }

        while index < args.count {
            let arg = args[index]
            if arg == "--" {
                words.append(contentsOf: args[(index + 1)...])
                break
            }
            switch arg {
            case "--encrypt": encrypt = true
            case "--decrypt": decrypt = true
            case "--encrypt-file": encryptFile = true
            case "--decrypt-file": decryptFile = true
            case "--encrypt-folder": encryptFolder = true
            case "--decrypt-folder": decryptFolder = true
            case "--classic": try fail("the version 1 key is retired")
            case "--header": header = true
            case "--no-header": noHeader = true
            case "--map": map = true
            case "--scramble-name": scrambleName = true
            case "--cross-weave": crossWeave = true
            case "--key":
                if seenKey { try fail("--key was given more than once") }
                key = try value(for: "--key", inline: nil)
                seenKey = true
            case "--unit":
                if unit != nil { try fail("--unit was given more than once") }
                let name = try value(for: "--unit", inline: nil)
                guard let parsed = DragonEngine.Unit(rawValue: name) else {
                    try fail("--unit must be character, hex, byte, or bit")
                }
                unit = parsed
            case "--passes":
                if passes != nil { try fail("--passes was given more than once") }
                let raw = try value(for: "--passes", inline: nil)
                guard let number = Int(raw), (1...7).contains(number) else {
                    try fail("--passes must be 1 through 7")
                }
                passes = number
            case "--compression":
                let name = try value(for: "--compression", inline: nil)
                guard let parsed = DragonFolder.Compression(rawValue: name) else {
                    try fail("--compression must be deflate or store")
                }
                compression = parsed
            case "--output":
                if output != nil { try fail("--output was given more than once") }
                output = try value(for: "--output", inline: nil)
            case "--file":
                if file != nil { try fail("--file was given more than once") }
                file = try value(for: "--file", inline: nil)
            default:
                if let inline = inlineValue(arg, flag: "--key") {
                    if seenKey { try fail("--key was given more than once") }
                    if inline.isEmpty { try fail("--key needs a value") }
                    key = inline
                    seenKey = true
                } else if let inline = inlineValue(arg, flag: "--unit") {
                    if unit != nil { try fail("--unit was given more than once") }
                    guard let parsed = DragonEngine.Unit(rawValue: inline) else {
                        try fail("--unit must be character, hex, byte, or bit")
                    }
                    unit = parsed
                } else if let inline = inlineValue(arg, flag: "--passes") {
                    if passes != nil { try fail("--passes was given more than once") }
                    guard let number = Int(inline), (1...7).contains(number) else {
                        try fail("--passes must be 1 through 7")
                    }
                    passes = number
                } else if let inline = inlineValue(arg, flag: "--compression") {
                    guard let parsed = DragonFolder.Compression(rawValue: inline) else {
                        try fail("--compression must be deflate or store")
                    }
                    compression = parsed
                } else if let inline = inlineValue(arg, flag: "--output") {
                    if output != nil { try fail("--output was given more than once") }
                    if inline.isEmpty { try fail("--output needs a value") }
                    output = inline
                } else if let inline = inlineValue(arg, flag: "--file") {
                    if file != nil { try fail("--file was given more than once") }
                    if inline.isEmpty { try fail("--file needs a value") }
                    file = inline
                } else if arg.hasPrefix("-") {
                    try fail("unknown option \(arg)")
                } else {
                    words.append(arg)
                }
            }
            index += 1
        }

        let fileMode = encryptFile || decryptFile
        let folderMode = encryptFolder || decryptFolder
        let textMode = encrypt || decrypt
        let modes = [fileMode, folderMode, textMode].filter { $0 }.count
        if modes != 1 { try fail("choose text, a file, or a folder") }
        if encrypt && decrypt { try fail("choose encrypt or decrypt") }
        if encryptFile && decryptFile { try fail("choose encrypt or decrypt") }
        if encryptFolder && decryptFolder { try fail("choose encrypt or decrypt") }
        if header && noHeader { try fail("choose --header or --no-header") }
        if header && (decrypt || decryptFile || decryptFolder) {
            try fail("--header is for encryption. Decryption reads the header.")
        }
        if noHeader && !encryptFile { try fail("--no-header is for file encryption") }
        if scrambleName && (decrypt || decryptFile || decryptFolder) {
            try fail("--scramble-name is only for encryption")
        }
        if scrambleName && noHeader { try fail("--scramble-name needs the version header") }
        if crossWeave && !encryptFolder { try fail("--cross-weave is only for folder encryption") }
        if compression != .deflate && !encryptFolder {
            try fail("--compression is only for folder encryption")
        }
        if folderMode && (passes != nil || unit != nil) && decryptFolder {
            try fail("--unit and --passes are read from the folder package")
        }
        if fileMode || folderMode {
            if file == nil {
                if words.count == 1 {
                    file = words[0]
                    words = []
                } else {
                    try fail("give one file")
                }
            } else if !words.isEmpty {
                try fail("give text or a file, not both")
            }
        }
    }

    private func inlineValue(_ arg: String, flag: String) -> String? {
        let prefix = flag + "="
        guard arg.hasPrefix(prefix) else { return nil }
        return String(arg.dropFirst(prefix.count))
    }
}
