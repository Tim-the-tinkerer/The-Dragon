import AppKit
import SwiftUI


struct UsageError: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

enum CLI {
    static let usage = """
    Dragonscale — fold a picture on the Heighway dragon

    Usage:
      Dragonscale
      Dragonscale --self-test
      Dragonscale --version
      Dragonscale --card --out card.dragon.png
      Dragonscale --input photo.png --out photo.dragon.png
      Dragonscale --input photo.png --key paper --passes 4 --tile 16 --out photo.dragon.png
      Dragonscale --input photo.png --mate other.png --pair --key paper --out photo.dragon.png
      Dragonscale --card --pair --out card.dragon.png
      Dragonscale --restore --input photo.dragon.png --key paper --out photo.restored.png

    Options:
      --card              Fold the built-in card instead of a file.
      --input PATH        Image to read. PNG, JPEG, TIFF, GIF, HEIC, and WebP.
      --out PATH          PNG to write. Must end in .png. Replaces a file already there.
      --key PHRASE        Case sensitive. Empty is the plain curve.
      --passes N          1 through 7. Omit it and the phrase decides.
      --unit pixel|tile|row|column
                          Default tile. row and column are strips.
      --tile N            Pixels on a side, or the thickness of a strip. Default 16.
      --spin              In tile mode, turn each square with the pen.
      --split             In pixel mode, give red, green, and blue their own curves.
      --pair              Mix a second picture through the same dragon.
      --mate PATH         The second picture. Fitted to the first. With --card, the night card is used when this is omitted.
      --restore           Put a folded file back. The note supplies the settings.
      --plain             Write the folded PNG without the fold note.

    The original file is never the output. A folded PNG opens in any viewer.
    The phrase is not stored. Restore needs the same phrase.
    """

    static func isJob(_ args: [String]) -> Bool {
        args.dropFirst().contains { arg in
            switch arg {
            case "--card", "--restore", "--plain", "--input", "--out", "--key", "--passes",
                 "--unit", "--tile", "--spin", "--split", "--pair", "--mate":
                return true
            default:
                return arg.hasPrefix("--input=") || arg.hasPrefix("--out=") || arg.hasPrefix("--key=")
                    || arg.hasPrefix("--passes=") || arg.hasPrefix("--unit=") || arg.hasPrefix("--tile=")
                    || arg.hasPrefix("--mate=")
            }
        }
    }

    static func perform(_ args: [String]) throws -> String {
        var card = false
        var restore = false
        var plainNote = false
        var input: String?
        var out: String?
        var key = ""
        var passes: Int?
        var unit = ImageUnit.tile
        var tile = AppInfo.defaultTile
        var spin = false
        var split = false
        var pair = false
        var mate: String?

        var index = 1
        while index < args.count {
            let arg = args[index]
            func take(_ name: String) throws -> String {
                if let range = arg.range(of: "="), arg.hasPrefix(name + "=") {
                    return String(arg[range.upperBound...])
                }
                guard index + 1 < args.count else {
                    throw UsageError(message: "\(name) needs a value")
                }
                index += 1
                return args[index]
            }
            switch arg {
            case "--card":
                card = true
            case "--restore":
                restore = true
            case "--plain":
                plainNote = true
            case "--input":
                input = try take(arg)
            case _ where arg.hasPrefix("--input="):
                input = try take("--input")
            case "--out":
                out = try take(arg)
            case _ where arg.hasPrefix("--out="):
                out = try take("--out")
            case "--key":
                key = try take(arg)
            case _ where arg.hasPrefix("--key="):
                key = try take("--key")
            case "--passes":
                passes = try parsePasses(try take(arg))
            case _ where arg.hasPrefix("--passes="):
                passes = try parsePasses(try take("--passes"))
            case "--unit":
                unit = try parseUnit(try take(arg))
            case _ where arg.hasPrefix("--unit="):
                unit = try parseUnit(try take("--unit"))
            case "--tile":
                tile = Int(try take(arg)) ?? 0
            case _ where arg.hasPrefix("--tile="):
                tile = Int(try take("--tile")) ?? 0
            case "--spin":
                spin = true
            case "--split":
                split = true
            case "--pair":
                pair = true
            case "--mate":
                mate = try take(arg)
            case _ where arg.hasPrefix("--mate="):
                mate = try take("--mate")
            default:
                if arg == "--self-test" || arg == "--help" || arg == "-h" || arg == "--version" {
                    break
                }
                throw UsageError(message: "unknown argument \(arg)")
            }
            index += 1
        }

        if mate != nil { pair = true }
        guard let out else { throw UsageError(message: "--out needs a file path") }
        if card && input != nil { throw UsageError(message: "Use either --card or --input.") }
        if restore && card { throw UsageError(message: "Restore reads --input.") }
        if restore && mate != nil { throw UsageError(message: "Restore reads one stacked PNG. Leave out --mate.") }
        if !card && input == nil { throw UsageError(message: "Choose --card or --input.") }
        if pair && mate == nil && !card && !restore {
            throw UsageError(message: "--pair needs --mate, or use --card.")
        }
        if let passes, !(1...7).contains(passes) {
            throw UsageError(message: "--passes must be 1 through 7.")
        }
        if tile < 1 || tile > AppInfo.maxTile {
            throw UsageError(message: "--tile must be from 1 to \(AppInfo.maxTile).")
        }
        let outURL = URL(fileURLWithPath: out)
        guard outURL.pathExtension.lowercased() == "png" else {
            throw UsageError(message: "--out must be a .png file.")
        }

        if restore {
            guard let input else { throw UsageError(message: "Restore needs --input.") }
            return try restoreFile(input: input, out: outURL, key: key, unit: unit, tile: tile, passes: passes, spin: spin, split: split, pair: pair)
        }

        let source: Picture
        let opened: URL?
        let sourceWarning: String?
        if card {
            source = Card.make()
            opened = nil
            sourceWarning = nil
        } else {
            let url = URL(fileURLWithPath: input ?? "")
            opened = url
            let loaded = try PictureLoader.load(url: url)
            if loaded.picture.mark != nil {
                throw FoldError(message: "That file is already folded. Use --restore.")
            }
            source = loaded.picture
            sourceWarning = loaded.warning
        }
        if pair {
            return try foldPair(
                source: source,
                opened: opened,
                matePath: mate,
                card: card,
                out: outURL,
                key: key,
                passes: passes,
                unit: unit,
                tile: tile,
                spin: spin,
                split: split,
                plainNote: plainNote,
                sourceWarning: sourceWarning
            )
        }
        let folded = try ImageFold.permute(
            pixels: source.pixels,
            width: source.width,
            height: source.height,
            unit: unit,
            tile: tile,
            key: key,
            passes: passes,
            spin: spin,
            split: split,
            reverse: false
        )
        var picture = source
        picture.pixels = folded.pixels
        picture.mark = plainNote ? nil : folded.mark
        let data = try PNGFile.fileData(picture: picture, includeNote: !plainNote && picture.mark != nil)
        try PNGFile.write(data, to: outURL, replacing: opened)
        let note = picture.mark == nil ? "no fold note" : "fold note kept"
        let turned = folded.mark.spin ? " · tiles turned" : ""
        let channels = folded.mark.split ? " · channels split" : ""
        return "Wrote \(outURL.path) · \(picture.width)×\(picture.height) · \(folded.mark.passes) passes · \(folded.mark.unitLine)\(turned)\(channels) · \(note)\(warningSuffix(sourceWarning))"
    }

    private static func restoreFile(
        input: String,
        out: URL,
        key: String,
        unit: ImageUnit,
        tile: Int,
        passes: Int?,
        spin: Bool,
        split: Bool,
        pair: Bool
    ) throws -> String {
        let url = URL(fileURLWithPath: input)
        let loaded = try PictureLoader.load(url: url)
        let picture = loaded.picture
        let warned = warningSuffix(loaded.warning)
        if picture.mark?.pair == true || (picture.mark == nil && pair) {
            guard let halves = ImageFold.halves(picture) else {
                throw FoldError(message: "Pair restore needs the two pictures stacked, with an even height.")
            }
            let mark: FoldMark
            if let existing = picture.mark, existing.pair {
                mark = existing
            } else {
                let plan = try Curve.plan(key: key, passes: passes)
                let placed = ImageFold.layout(width: halves.0.width, height: halves.0.height, unit: unit, tile: tile)
                mark = FoldMark(
                    unit: unit,
                    tile: ImageFold.tileSide(unit: unit, tile: tile),
                    passes: plan.count,
                    keyed: !key.isEmpty,
                    spin: ImageFold.turnsTiles(spin, unit: unit, layout: placed),
                    split: ImageFold.splitsChannels(split, unit: unit),
                    pair: true
                )
            }
            let back = try ImageFold.restorePair(first: halves.0, second: halves.1, mark: mark, phrase: key)
            let stacked = try ImageFold.stack(top: back.0, bottom: back.1, mark: nil)
            let data = try PNGFile.fileData(picture: stacked, includeNote: false)
            try PNGFile.write(data, to: out, replacing: url)
            return "Wrote \(out.path) · restored · two pictures · \(stacked.width)×\(stacked.height)\(warned)"
        }
        let pixels: [UInt8]
        if let mark = picture.mark {
            pixels = try ImageFold.restore(
                pixels: picture.pixels,
                width: picture.width,
                height: picture.height,
                mark: mark,
                phrase: key
            )
        } else {
            let folded = try ImageFold.permute(
                pixels: picture.pixels,
                width: picture.width,
                height: picture.height,
                unit: unit,
                tile: tile,
                key: key,
                passes: passes,
                spin: spin,
                split: split,
                reverse: true
            )
            pixels = folded.pixels
        }
        var plain = picture
        plain.pixels = pixels
        plain.mark = nil
        let data = try PNGFile.fileData(picture: plain, includeNote: false)
        try PNGFile.write(data, to: out, replacing: url)
        return "Wrote \(out.path) · restored · \(plain.width)×\(plain.height)\(warned)"
    }

    private static func warningSuffix(_ warning: String?) -> String {
        guard let warning, !warning.isEmpty else { return "" }
        return " · " + warning
    }

    private static func foldPair(
        source: Picture,
        opened: URL?,
        matePath: String?,
        card: Bool,
        out: URL,
        key: String,
        passes: Int?,
        unit: ImageUnit,
        tile: Int,
        spin: Bool,
        split: Bool,
        plainNote: Bool,
        sourceWarning: String?
    ) throws -> String {
        let secondSource: Picture
        let mateURL: URL?
        let mateWarning: String?
        if let matePath {
            let url = URL(fileURLWithPath: matePath)
            mateURL = url
            let loaded = try PictureLoader.load(url: url)
            if loaded.picture.mark != nil {
                throw FoldError(message: "The second file is already folded. Use --restore on the stacked PNG.")
            }
            secondSource = loaded.picture
            mateWarning = loaded.warning
        } else if card {
            secondSource = Card.mate()
            mateURL = nil
            mateWarning = nil
        } else {
            throw UsageError(message: "--pair needs --mate, or use --card.")
        }
        if let mateURL, PNGFile.sameFile(out, mateURL) {
            throw FoldError(message: "Dragonscale leaves the original file alone.")
        }
        let second = try ImageFold.fit(secondSource, width: source.width, height: source.height)
        let mixed = try ImageFold.permutePair(
            first: source,
            second: second,
            unit: unit,
            tile: tile,
            key: key,
            passes: passes,
            spin: spin,
            split: split,
            reverse: false
        )
        let kept: FoldMark? = plainNote ? nil : mixed.mark
        let stacked = try ImageFold.stack(top: mixed.first, bottom: mixed.second, mark: kept)
        let data = try PNGFile.fileData(picture: stacked, includeNote: kept != nil)
        try PNGFile.write(data, to: out, replacing: opened)
        let note = kept == nil ? "no fold note" : "fold note kept"
        let turned = mixed.mark.spin ? " · tiles turned" : ""
        let channels = mixed.mark.split ? " · channels split" : ""
        let fitted = second.reduced ? " · second fitted" : ""
        return "Wrote \(out.path) · \(stacked.width)×\(stacked.height) · \(mixed.mark.passes) passes · \(mixed.mark.unitLine)\(turned)\(channels)\(fitted) · \(note)\(warningSuffix(sourceWarning))\(warningSuffix(mateWarning))"
    }

    private static func parsePasses(_ text: String) throws -> Int {
        guard let value = Int(text) else {
            throw UsageError(message: "--passes must be 1 through 7.")
        }
        return value
    }

    private static func parseUnit(_ text: String) throws -> ImageUnit {
        switch text.lowercased() {
        case "pixel": return .pixel
        case "tile": return .tile
        case "row", "rows": return .row
        case "column", "columns": return .column
        default: throw UsageError(message: "--unit must be pixel, tile, row, or column.")
        }
    }
}

extension CLI {
    /// Runs a command-line job. `nil` means these arguments asked for the window.
    static func command(_ args: [String]) -> Int32? {
        if args.contains("--self-test") {
            if let err = SelfTest.run() {
                fputs("SELF-TEST FAILED:\n\(err)\n", stderr)
                return 1
            }
            print("SELF-TEST OK")
            return 0
        }
        if args.contains("--help") || args.contains("-h") {
            print(usage)
            return 0
        }
        if args.contains("--version") {
            print("\(AppInfo.name) \(AppInfo.version) (\(AppInfo.build))")
            return 0
        }
        if isJob(args) {
            do {
                print(try perform(args))
                return 0
            } catch let error as UsageError {
                fputs("Dragonscale: \(error.message)\n\(usage)\n", stderr)
                return 2
            } catch {
                fputs("Dragonscale: \(error.localizedDescription)\n", stderr)
                return 1
            }
        }
        return nil
    }
}
