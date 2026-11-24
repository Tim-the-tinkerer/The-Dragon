import AppKit
import AVKit
import SwiftUI


struct UsageError: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

enum CLI {
    static let usage = """
    Dragonreel — fold a movie on the Heighway dragon

    Usage:
      Dragonreel
      Dragonreel --self-test
      Dragonreel --version
      Dragonreel --reel --out reel.dragon.mp4
      Dragonreel --input clip.mp4 --out clip.dragon.mp4
      Dragonreel --input clip.mp4 --key paper --passes 4 --axis both --tile 16 --run 8 --out clip.dragon.mp4
      Dragonreel --restore --input clip.dragon.mp4 --key paper --out clip.restored.mp4

    Options:
      --reel              Fold the built-in reel instead of a file.
      --input PATH        Movie to read.
      --out PATH          MP4 to write. Must end in .mp4. Replaces a file already there.
      --key PHRASE        Case sensitive. Empty is the plain curve.
      --passes N          1 through 7. Omit it and the phrase decides.
      --axis scale|fold|both
                          Scale moves tiles. Fold moves runs of frames. Both does both.
      --tile N            Pixels on a side for Scale and Both. Default 16.
      --run N             Frames in a run for Fold and Both. Default 8. 1 flickers.
      --span preview|full Preview keeps the first 20 seconds or 600 frames.
                          Full keeps the whole movie when the temporary files fit.
                          Restore reads the whole movie unless this is preview.
      --restore           Put a folded file back. The note supplies the settings.
      --plain             Write the folded movie without the fold note.

    This version fits each frame inside 1920×1080. Preview is the default.
    Full movie checks free temporary space before it reads, and counts both
    the loaded frames and the folded frames. The original file is never the
    output. A folded movie plays in any player. The phrase is not stored.
    Restore needs the same phrase. The movie is H.264, so the restored picture
    carries the codec's change.
    """

    static func isJob(_ args: [String]) -> Bool {
        args.contains("--out") || args.contains("--input") || args.contains("--reel")
            || args.contains("--restore") || args.contains("--plain") || args.contains("--key")
            || args.contains("--passes") || args.contains("--axis") || args.contains("--tile")
            || args.contains("--run") || args.contains("--span")
            || args.contains { $0.hasPrefix("--key=") || $0.hasPrefix("--out=") || $0.hasPrefix("--input=") }
    }

    static func perform(_ args: [String]) throws -> String {
        var reel = false
        var restore = false
        var plainNote = false
        var input: String?
        var out: String?
        var key = ""
        var passes: Int?
        var axis = ReelAxis.scale
        var tile = AppInfo.defaultTile
        var run = AppInfo.defaultRun
        var span: ReelSpan = .preview
        var spanChosen = false

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
            case "--reel":
                reel = true
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
            case "--axis":
                axis = try parseAxis(try take(arg))
            case _ where arg.hasPrefix("--axis="):
                axis = try parseAxis(try take("--axis"))
            case "--tile":
                tile = Int(try take(arg)) ?? 0
            case _ where arg.hasPrefix("--tile="):
                tile = Int(try take("--tile")) ?? 0
            case "--run":
                run = Int(try take(arg)) ?? 0
            case _ where arg.hasPrefix("--run="):
                run = Int(try take("--run")) ?? 0
            case "--span":
                span = try parseSpan(try take(arg))
                spanChosen = true
            case _ where arg.hasPrefix("--span="):
                span = try parseSpan(try take("--span"))
                spanChosen = true
            default:
                if arg == "--self-test" || arg == "--help" || arg == "-h" || arg == "--version" {
                    break
                }
                throw UsageError(message: "unknown argument \(arg)")
            }
            index += 1
        }

        guard let out else { throw UsageError(message: "--out needs a file path") }
        if reel && input != nil { throw UsageError(message: "Use either --reel or --input.") }
        if restore && reel { throw UsageError(message: "Restore reads --input.") }
        if !reel && input == nil { throw UsageError(message: "Choose --reel or --input.") }
        if let passes, !(1...7).contains(passes) {
            throw UsageError(message: "--passes must be 1 through 7.")
        }
        if tile < 1 || tile > AppInfo.maxTile {
            throw UsageError(message: "--tile must be from 1 to \(AppInfo.maxTile).")
        }
        if run < 1 || run > AppInfo.maxRun {
            throw UsageError(message: "--run must be from 1 to \(AppInfo.maxRun).")
        }
        let outURL = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        guard outURL.pathExtension.lowercased() == "mp4" else {
            throw UsageError(message: "--out must be a .mp4 file.")
        }

        if restore {
            guard let input else { throw UsageError(message: "Restore needs --input.") }
            if !spanChosen { span = .full }
            return try restoreFile(
                input: input, out: outURL, key: key, axis: axis, tile: tile, run: run, passes: passes, span: span
            )
        }

        let source: Reel
        let opened: URL?
        if reel {
            source = DemoReel.make()
            opened = nil
        } else {
            let url = URL(fileURLWithPath: (input ?? "").expandingTildeIfNeeded)
            opened = url
            let loaded = try MovieIO.load(url, span: span) { _ in }
            if loaded.mark != nil {
                throw FoldError(message: "That file is already folded. Use --restore.")
            }
            source = loaded
        }
        let folded = try ReelFold.permute(
            source: source,
            axis: axis,
            tile: tile,
            run: run,
            key: key,
            passes: passes,
            reverse: false
        )
        let note = plainNote ? nil : folded.mark?.note
        let warning = try MovieIO.write(reel: folded, note: note, to: outURL, replacing: opened)
        var line = "Wrote \(outURL.path) · \(folded.width)×\(folded.height) · \(folded.count) frames · \(folded.mark?.passes ?? 0) passes · \(folded.mark?.unitLine ?? "")"
        line += note == nil ? " · no fold note" : " · fold note kept"
        if let warning { line += " · \(warning)" }
        if let clipped = source.clipped { line += " · \(clipped)" }
        return line
    }

    private static func restoreFile(
        input: String,
        out: URL,
        key: String,
        axis: ReelAxis,
        tile: Int,
        run: Int,
        passes: Int?,
        span: ReelSpan
    ) throws -> String {
        let url = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
        let loaded = try MovieIO.load(url, span: span) { _ in }
        let restored: Reel
        if let mark = loaded.mark {
            restored = try ReelFold.restore(source: loaded, mark: mark, phrase: key)
        } else {
            let plan = try Curve.plan(key: key, passes: passes)
            let mark = ReelMark(
                axis: axis,
                tile: axis.usesTiles ? ReelFold.tileSide(tile) : 0,
                run: axis.usesRuns ? ReelFold.runLength(run) : 0,
                passes: plan.count,
                keyed: !key.isEmpty,
                width: loaded.width,
                height: loaded.height,
                frames: loaded.count
            )
            restored = try ReelFold.restore(source: loaded, mark: mark, phrase: key)
        }
        _ = try MovieIO.write(reel: restored, note: nil, to: out, replacing: url)
        return "Wrote \(out.path) · restored · \(restored.width)×\(restored.height) · \(restored.count) frames"
    }

    private static func parsePasses(_ text: String) throws -> Int {
        guard let value = Int(text) else {
            throw UsageError(message: "--passes must be 1 through 7.")
        }
        return value
    }

    private static func parseSpan(_ text: String) throws -> ReelSpan {
        switch text.lowercased() {
        case "preview": return .preview
        case "full": return .full
        default: throw UsageError(message: "--span must be preview or full.")
        }
    }

    private static func parseAxis(_ text: String) throws -> ReelAxis {
        switch text.lowercased() {
        case "scale": return .scale
        case "fold": return .fold
        case "both": return .both
        default: throw UsageError(message: "--axis must be scale, fold, or both.")
        }
    }
}

private extension String {
    var expandingTildeIfNeeded: String { (self as NSString).expandingTildeInPath }
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
                fputs("Dragonreel: \(error.message)\n\(usage)\n", stderr)
                return 2
            } catch {
                fputs("Dragonreel: \(error.localizedDescription)\n", stderr)
                return 1
            }
        }
        return nil
    }
}
