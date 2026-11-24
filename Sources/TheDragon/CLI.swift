import DragonCurve
import Dragonfold
import Dragonreel
import Dragonscale
import Foundation

enum ShellCLI {
    static let usage = """
    The Dragon — Curve, Scale, Fold, and Reel

    Usage:
      TheDragon
      TheDragon --self-test
      TheDragon --version
      TheDragon curve [Dragon Curve arguments]
      TheDragon scale [Dragonscale arguments]
      TheDragon fold  [Dragonfold arguments]
      TheDragon reel  [Dragonreel arguments]

    The window has one section for each fold.
    curve --help, scale --help, fold --help, and reel --help print that fold's usage.
    --self-test runs every fold. --self-test curve runs one of them.
    """

    static func run(_ args: [String]) -> Int32? {
        guard args.count >= 2 else { return nil }
        switch args[1] {
        case "--help", "-h":
            print(usage)
            return 0
        case "--version":
            print("\(AppInfo.name) \(AppInfo.version) (\(AppInfo.build))")
            return 0
        case "--self-test":
            let which = args.count >= 3 ? args[2] : "all"
            return selfTests(which)
        case "curve":
            return DragonCurveHost.command(["DragonCurve"] + Array(args.dropFirst(2)))
        case "scale":
            return DragonscaleHost.command(["Dragonscale"] + Array(args.dropFirst(2)))
        case "fold":
            return DragonfoldHost.command(["Dragonfold"] + Array(args.dropFirst(2)))
        case "reel":
            return DragonreelHost.command(["Dragonreel"] + Array(args.dropFirst(2)))
        default:
            if args[1].hasPrefix("-") {
                fputs("The Dragon: unknown option \(args[1])\n\(usage)\n", stderr)
            } else {
                fputs("The Dragon: unknown section \(args[1])\n\(usage)\n", stderr)
            }
            return 2
        }
    }

    private static func selfTests(_ which: String) -> Int32 {
        let all: [(String, String, () -> String?)] = [
            ("curve", "Dragon Curve", { DragonCurveHost.selfTest() }),
            ("scale", "Dragonscale", { DragonscaleHost.selfTest() }),
            ("fold", "Dragonfold", { DragonfoldHost.selfTest() }),
            ("reel", "Dragonreel", { DragonreelHost.selfTest() }),
        ]
        let chosen = which == "all" ? all : all.filter { $0.0 == which }
        if chosen.isEmpty {
            fputs("The Dragon: --self-test wants curve, scale, fold, reel, or nothing for all.\n", stderr)
            return 2
        }
        var failed = false
        for item in chosen {
            fputs("\(item.1)...\n", stderr)
            if let report = item.2() {
                fputs("\(item.1) SELF-TEST FAILED\n\(report)\n", stderr)
                failed = true
            } else {
                print("\(item.1) SELF-TEST OK")
            }
        }
        return failed ? 1 : 0
    }
}
