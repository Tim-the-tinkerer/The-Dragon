import AppKit
import SwiftUI


struct UsageError: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

enum CLI {
    static let usage = """
    Dragonfold — fold audio on the Heighway dragon

    Usage:
      Dragonfold
      Dragonfold --self-test
      Dragonfold --version
      Dragonfold --tone --out tone.dragon.wav
      Dragonfold --input song.wav --out song.dragon.wav
      Dragonfold --input song.wav --key paper --passes 4 --grain 1024 --out song.dragon.wav
      Dragonfold --restore --input song.dragon.wav --key paper --out song.wav

    Options:
      --tone              Fold the built-in arpeggio instead of a file.
      --seconds N         Tone length, from 0.05 to 30. Default 2.
      --input PATH        Audio to read.
      --out PATH          WAV to write. Replaces a file already there.
      --key PHRASE        Case sensitive. Empty is the plain curve.
      --passes N          1 through 7. Omit it and the phrase decides.
      --unit sample|frame|grain
                          Default grain. Sample gives each channel its own dragon.
      --grain N           Frames per segment in grain mode. Default 1024.
      --reverse-turns     In grain mode, a right turn plays that grain backward.
      --restore           Put a folded file back. The note supplies the settings.
      --plain             Write the folded WAV without the fold note.

    The original file is never the output. A folded WAV plays in any player.
    The phrase is not stored. Restore needs the same phrase.
    """

    static func isJob(_ args: [String]) -> Bool {
        args.contains("--out") || args.contains("--input") || args.contains("--tone")
            || args.contains("--restore") || args.contains("--plain") || args.contains("--key")
            || args.contains("--passes") || args.contains("--unit") || args.contains("--grain")
            || args.contains("--reverse-turns") || args.contains("--seconds")
            || args.contains { $0.hasPrefix("--key=") || $0.hasPrefix("--out=") || $0.hasPrefix("--input=") }
    }

    static func perform(_ args: [String]) throws -> String {
        var tone = false
        var restore = false
        var plainNote = false
        var seconds = AppInfo.toneSeconds
        var input: String?
        var out: String?
        var key = ""
        var passes: Int?
        var unit = AudioUnit.grain
        var grain = AppInfo.defaultGrain
        var reverseRight = false

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
            case "--tone":
                tone = true
            case "--restore":
                restore = true
            case "--plain":
                plainNote = true
            case "--seconds":
                seconds = Double(try take(arg)) ?? .nan
            case _ where arg.hasPrefix("--seconds="):
                seconds = Double(try take("--seconds")) ?? .nan
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
            case "--grain":
                grain = Int(try take(arg)) ?? 0
            case _ where arg.hasPrefix("--grain="):
                grain = Int(try take("--grain")) ?? 0
            case "--reverse-turns":
                reverseRight = true
            default:
                if arg == "--self-test" || arg == "--help" || arg == "-h" || arg == "--version" {
                    break
                }
                throw UsageError(message: "unknown argument \(arg)")
            }
            index += 1
        }

        guard let out else { throw UsageError(message: "--out needs a file path") }
        if tone && input != nil { throw UsageError(message: "Use either --tone or --input.") }
        if restore && tone { throw UsageError(message: "Restore reads --input.") }
        if !tone && input == nil { throw UsageError(message: "Choose --tone or --input.") }
        if !seconds.isFinite || seconds < 0.05 || seconds > 30 {
            throw UsageError(message: "--seconds must be from 0.05 to 30.")
        }
        if let passes, !(1...7).contains(passes) {
            throw UsageError(message: "--passes must be 1 through 7.")
        }
        if grain < 1 || grain > 1_048_576 {
            throw UsageError(message: "--grain must be from 1 to 1048576.")
        }

        let outURL = URL(fileURLWithPath: out)
        if restore {
            guard let input else { throw UsageError(message: "Restore needs --input.") }
            return try restoreFile(
                input: input,
                out: outURL,
                key: key,
                unit: unit,
                grain: grain,
                passes: passes,
                reverseRight: reverseRight
            )
        }
        let source: Clip
        let opened: URL?
        if tone {
            source = Tone.make(seconds: seconds)
            opened = nil
        } else {
            let url = URL(fileURLWithPath: input ?? "")
            opened = url
            let loaded = try SongLoader.load(url: url)
            if loaded.clip.mark != nil {
                throw FoldError(message: "That file is already folded. Use --restore.")
            }
            source = loaded.clip
        }
        let folded = try AudioFold.permute(
            samples: source.samples,
            frames: source.frames,
            channels: source.channels,
            unit: unit,
            grain: grain,
            key: key,
            passes: passes,
            reverseRight: unit == .grain && reverseRight,
            reverse: false
        )
        var clip = source
        clip.samples = folded.samples
        clip.mark = plainNote ? nil : folded.mark
        let data = try WAVFile.encode(clip: clip, includeNote: !plainNote)
        try WAVFile.write(data, to: outURL, replacing: opened)
        let note = plainNote ? "no fold note" : "fold note kept"
        let turns = folded.mark.reverseRight ? " · right turns backward" : ""
        return "Wrote \(outURL.path) · \(clock(clip.duration)) · \(folded.mark.passes) passes · \(folded.mark.unitLine) · \(note)\(turns)"
    }

    private static func restoreFile(
        input: String,
        out: URL,
        key: String,
        unit: AudioUnit,
        grain: Int,
        passes: Int?,
        reverseRight: Bool
    ) throws -> String {
        let url = URL(fileURLWithPath: input)
        let loaded = try SongLoader.load(url: url)
        let clip = loaded.clip
        let samples: [Int16]
        if let mark = clip.mark {
            samples = try AudioFold.restore(
                samples: clip.samples,
                frames: clip.frames,
                channels: clip.channels,
                mark: mark,
                phrase: key
            )
        } else {
            let folded = try AudioFold.permute(
                samples: clip.samples,
                frames: clip.frames,
                channels: clip.channels,
                unit: unit,
                grain: grain,
                key: key,
                passes: passes,
                reverseRight: unit == .grain && reverseRight,
                channelDragons: unit == .sample && clip.channels > 1,
                reverse: true
            )
            samples = folded.samples
        }
        var plain = clip
        plain.samples = samples
        plain.mark = nil
        let data = try WAVFile.encode(clip: plain, includeNote: false)
        try WAVFile.write(data, to: out, replacing: url)
        return "Wrote \(out.path) · restored · \(clock(plain.duration))"
    }

    private static func parsePasses(_ text: String) throws -> Int {
        guard let value = Int(text) else {
            throw UsageError(message: "--passes must be 1 through 7.")
        }
        return value
    }

    private static func parseUnit(_ text: String) throws -> AudioUnit {
        switch text.lowercased() {
        case "sample": return .sample
        case "frame": return .frame
        case "grain": return .grain
        default: throw UsageError(message: "--unit must be sample, frame, or grain.")
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
                fputs("Dragonfold: \(error.message)\n\(usage)\n", stderr)
                return 2
            } catch {
                fputs("Dragonfold: \(error.localizedDescription)\n", stderr)
                return 1
            }
        }
        return nil
    }
}
