import Foundation

enum SelfTest {
    static func run() -> String? {
        var failures: [String] = []
        func expect(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: String = "") {
            if !condition() {
                failures.append(detail.isEmpty ? name : "\(name): \(detail)")
            }
        }
        func expectThrow(_ name: String, _ body: () throws -> Void) {
            do {
                try body()
                failures.append("\(name): expected an error")
            } catch {
                return
            }
        }

        let turns = (1...16).map { Curve.paperTurn(UInt64($0)) }
        expect("paperfold", turns == [1, 1, -1, 1, 1, -1, -1, 1, 1, 1, -1, -1, 1, -1, -1, 1], "\(turns)")
        expect("fnv empty", Curve.fnv1a64(Data()) == 14_695_981_039_346_656_037)

        checkText(&failures)
        checkFit(&failures)
        checkNote(&failures)
        checkScale(&failures)
        checkFold(&failures)
        checkBoth(&failures)
        checkSound(&failures)
        checkCache(&failures)
        checkBudget(&failures)
        checkMovie(&failures)
        checkCLI(&failures)

        expectThrow("passes 8") {
            _ = try Curve.plan(key: "paper", passes: 8)
        }
        expectThrow("phrase required") {
            let source = solidReel(frames: 4, width: 16, height: 16)
            let folded = try ReelFold.permute(
                source: source, axis: .scale, tile: 8, run: 1,
                key: "paper", passes: 1, reverse: false
            )
            _ = try ReelFold.restore(source: folded, mark: folded.mark!, phrase: "")
        }
        if ReelFold.limitMessage(width: 2_000, height: 1_200, frames: 4, axis: .scale, tile: 1, run: 1) == nil {
            failures.append("tile limit missing")
        }

        return failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    private static func checkText(_ failures: inout [String]) {
        func round(_ name: String, _ text: String, _ key: String, _ passes: Int?, _ classic: Bool, _ want: String) {
            do {
                let folded = try Curve.rearrange(Array(text), key: key, passes: passes, classic: classic, reverse: false)
                let back = try Curve.rearrange(folded, key: key, passes: passes, classic: classic, reverse: true)
                if String(folded) != want {
                    failures.append("\(name): got \(String(folded))")
                }
                if String(back) != text {
                    failures.append("\(name) round trip: got \(String(back))")
                }
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
            }
        }
        round("Hello", "Hello", "", 1, false, "olleH")
        round("world", "Hello, World!", "", nil, false, "oorW,ll lde!H")
        round("paper", "Hello", "paper", nil, false, "loeHl")
        round("classic", "Hello", "paper", nil, true, "lelHo")
        round("four", "Hello", "paper", 4, false, "Holle")
        round("dragon", "Hello", "Dragon_Curves", nil, false, "Holle")
        round("three", "0123456789abcdefghij", "paper", 3, false, "89ja4b3d5i0167hgefc2")
        round("empty three", "Hello!!", "", 3, false, "l!Ho!el")
        do {
            let count = try Curve.plan(key: "Dragon_Curves", passes: nil).count
            if count != 6 { failures.append("Dragon_Curves passes: \(count)") }
            let paper = try Curve.plan(key: "paper", passes: nil).count
            if paper != 7 { failures.append("paper passes: \(paper)") }
            let wrong = try Curve.rearrange(Array("loeHl"), key: "papers", passes: nil, reverse: true)
            if String(wrong) == "Hello" { failures.append("wrong phrase restored Hello") }
        } catch {
            failures.append("plan: \(error.localizedDescription)")
        }
    }

    private static func checkFit(_ failures: inout [String]) {
        let hd = FrameFit.size(width: 3840, height: 2160)
        if hd.width != 1920 || hd.height != 1080 || !hd.fitted {
            failures.append("4K fit: \(hd)")
        }
        let portrait = FrameFit.size(width: 1080, height: 1920)
        if portrait.width > 1920 || portrait.height > 1080 || portrait.width % 2 != 0 || portrait.height % 2 != 0 {
            failures.append("portrait fit: \(portrait)")
        }
        if portrait.width != 606 || portrait.height != 1080 {
            failures.append("portrait size: \(portrait.width)×\(portrait.height)")
        }
        let same = FrameFit.size(width: 1280, height: 720)
        if same.width != 1280 || same.height != 720 || same.fitted {
            failures.append("720p should stay: \(same)")
        }
        let full = FrameFit.size(width: 1920, height: 1080)
        if full.fitted || full.width != 1920 || full.height != 1080 {
            failures.append("1080p should stay")
        }
        let odd = FrameFit.size(width: 1919, height: 1079)
        if odd.width != 1918 || odd.height != 1078 || !odd.fitted {
            failures.append("odd fit: \(odd)")
        }
        let wide = FrameFit.size(width: 4000, height: 1000)
        if wide.width != 1920 || wide.height != 480 || wide.width > 1920 || wide.height > 1080 {
            failures.append("banner fit: \(wide)")
        }
    }

    private static func checkNote(_ failures: inout [String]) {
        let mark = ReelMark(axis: .both, tile: 16, run: 8, passes: 4, keyed: true, width: 480, height: 270, frames: 48)
        guard let parsed = ReelMark.parse(mark.note) else {
            failures.append("note did not parse: \(mark.note)")
            return
        }
        if parsed != mark { failures.append("note round trip") }
        if ReelMark.parse("hello") != nil { failures.append("plain text parsed as a note") }
        if ReelMark.parse("DRL1 a=9 t=16 r=8 p=4 k=1 w=8 h=8 n=4") != nil {
            failures.append("bad axis parsed")
        }
    }

    private static func checkScale(_ failures: inout [String]) {
        do {
            let width = 64
            let height = 64
            let count = 6
            let source = Reel.memory(
                frames: (0..<count).map { tagged(frame: $0, width: width, height: height) },
                width: width, height: height, fps: 24, name: "scale"
            )
            let folded = try ReelFold.permute(
                source: source, axis: .scale, tile: 16, run: 8,
                key: "paper", passes: 1, reverse: false
            )
            if folded.mark?.axis != .scale || folded.mark?.run != 0 || folded.mark?.tile != 16 {
                failures.append("scale mark \(String(describing: folded.mark))")
            }
            let back = try ReelFold.restore(source: folded, mark: folded.mark!, phrase: "paper")
            if !same(source, back) { failures.append("scale restore") }
            let first = try folded.pixels(at: 0)
            let plain = try source.pixels(at: 0)
            if first == plain { failures.append("scale did not move a tile") }
            guard let anchor = locate(r: 0, g: 0, frame: first, width: width) else {
                failures.append("scale anchor missing")
                return
            }
            for frame in 0..<count {
                let pixels = try folded.pixels(at: frame)
                if channel(pixels, 2) != UInt8(frame) {
                    failures.append("scale moved time on frame \(frame)")
                }
                guard let spot = locate(r: 0, g: 0, frame: pixels, width: width) else {
                    failures.append("scale lost the anchor on frame \(frame)")
                    continue
                }
                if spot.x != anchor.x || spot.y != anchor.y || spot.b != UInt8(frame) {
                    failures.append("scale map changed on frame \(frame)")
                }
            }

            let wide = Reel.memory(
                frames: [tagged(frame: 3, width: 40, height: 36)],
                width: 40, height: 36, fps: 24, name: "edge"
            )
            let edge = try ReelFold.permute(
                source: wide, axis: .scale, tile: 16, run: 1,
                key: "", passes: 1, reverse: false
            )
            let original = try wide.pixels(at: 0)
            let scrambled = try edge.pixels(at: 0)
            if pixel(scrambled, width: 40, x: 33, y: 2) != pixel(original, width: 40, x: 33, y: 2) {
                failures.append("right edge moved")
            }
            if pixel(scrambled, width: 40, x: 4, y: 33) != pixel(original, width: 40, x: 4, y: 33) {
                failures.append("bottom edge moved")
            }
        } catch {
            failures.append("scale: \(error.localizedDescription)")
        }
    }

    private static func checkFold(_ failures: inout [String]) {
        do {
            let source = solidReel(frames: 10, width: 8, height: 8)
            let folded = try ReelFold.permute(
                source: source, axis: .fold, tile: 16, run: 4,
                key: "", passes: 1, reverse: false
            )
            if folded.mark?.axis != .fold || folded.mark?.tile != 0 || folded.mark?.run != 4 {
                failures.append("fold mark")
            }
            let back = try ReelFold.restore(source: folded, mark: folded.mark!, phrase: "")
            if !same(source, back) { failures.append("fold restore") }
            let colors = try (0..<10).map { try folded.pixels(at: $0)[0] }
            if colors[8] != 8 || colors[9] != 9 { failures.append("tail moved: \(colors)") }
            if colors[1] != colors[0] &+ 1 || colors[5] != colors[4] &+ 1 {
                failures.append("run broke internal order: \(colors)")
            }
            let harsh = try ReelFold.permute(
                source: source, axis: .fold, tile: 16, run: 1,
                key: "paper", passes: 1, reverse: false
            )
            let harshBack = try ReelFold.restore(source: harsh, mark: harsh.mark!, phrase: "paper")
            if !same(source, harshBack) { failures.append("flicker restore") }
            let harshColors = try (0..<10).map { try harsh.pixels(at: $0)[0] }
            if harshColors == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9] {
                failures.append("run of 1 did not move")
            }
            var jumps = 0
            for index in 1..<10 where harshColors[index] != harshColors[index - 1] &+ 1 {
                jumps += 1
            }
            if jumps < 3 { failures.append("run of 1 was not harsh: \(harshColors)") }
        } catch {
            failures.append("fold: \(error.localizedDescription)")
        }
    }

    private static func checkBoth(_ failures: inout [String]) {
        do {
            let source = Reel.memory(
                frames: (0..<8).map { tagged(frame: $0, width: 32, height: 32) },
                width: 32, height: 32, fps: 24, name: "both"
            )
            let together = try ReelFold.permute(
                source: source, axis: .both, tile: 16, run: 4,
                key: "paper", passes: 2, reverse: false
            )
            let back = try ReelFold.restore(source: together, mark: together.mark!, phrase: "paper")
            if !same(source, back) { failures.append("both restore") }
            let wrong = try ReelFold.restore(source: together, mark: together.mark!, phrase: "papers")
            if same(source, wrong) { failures.append("wrong phrase restored the reel") }

            let scaled = try ReelFold.permute(
                source: source, axis: .scale, tile: 16, run: 4,
                key: "paper", passes: 2, reverse: false
            )
            let scaleThenFold = try ReelFold.permute(
                source: scaled, axis: .fold, tile: 16, run: 4,
                key: "paper", passes: 2, reverse: false
            )
            let timed = try ReelFold.permute(
                source: source, axis: .fold, tile: 16, run: 4,
                key: "paper", passes: 2, reverse: false
            )
            let foldThenScale = try ReelFold.permute(
                source: timed, axis: .scale, tile: 16, run: 4,
                key: "paper", passes: 2, reverse: false
            )
            if !same(scaleThenFold, foldThenScale) { failures.append("scale and fold did not commute") }
            if !same(together, scaleThenFold) { failures.append("both disagreed with scale-then-fold") }
        } catch {
            failures.append("both: \(error.localizedDescription)")
        }
    }

    private static func checkCache(_ failures: inout [String]) {
        do {
            let store = try FrameStore(width: 32, height: 16)
            defer { store.destroy() }
            var frames: [[UInt8]] = []
            for index in 0..<3 {
                var pixels = [UInt8](repeating: UInt8(index * 40), count: 32 * 16 * 4)
                pixels[0] = UInt8(index)
                pixels[10] = 200
                frames.append(pixels)
                try store.append(pixels)
            }
            if store.count != 3 { failures.append("cache count") }
            for index in 0..<3 {
                var buffer = [UInt8]()
                try store.read(into: &buffer, at: index)
                if buffer != frames[index] { failures.append("cache frame \(index)") }
            }
        } catch {
            failures.append("cache: \(error.localizedDescription)")
        }
    }

    private static func checkBudget(_ failures: inout [String]) {
        do {
            let huge = try Reel.receiving(
                width: 1920, height: 1080, frames: Int.max,
                fps: 24, name: "huge", reduced: true, clipped: nil
            )
            if !huge.keepsFramesOnDisk { failures.append("huge reel stayed in memory") }
            let pixel = [UInt8](repeating: 0, count: 1920 * 1080 * 4)
            try huge.append(pixel)
            if huge.count != 1 { failures.append("huge reel append \(huge.count)") }
            huge.close()
            let unknown = try Reel.receiving(
                width: 16, height: 16, frames: nil,
                fps: 24, name: "unknown", reduced: false, clipped: nil
            )
            if !unknown.keepsFramesOnDisk { failures.append("unknown length stayed in memory") }
            unknown.close()
            if !Reel.keepsFramesInMemory(width: 16, height: 16, frames: 10) {
                failures.append("small reel was sent to disk")
            }
        } catch {
            failures.append("budget reel: \(error.localizedDescription)")
        }

        guard let short = StorageBudget.job(
            width: 1920, height: 1080, fps: 24, seconds: 10,
            sampleRate: 48_000, channels: 2, hasSound: true
        ) else {
            failures.append("short budget")
            return
        }
        let picture = Int64(1920) * 1080 * 4 * 240
        if short.frames != 240 || short.pictureBytes != picture {
            failures.append("short picture \(short.frames) \(short.pictureBytes)")
        }
        if short.soundBytes != 0 || short.total != picture * 2 {
            failures.append("short sound was stored \(short.soundBytes) total \(short.total)")
        }
        guard let long = StorageBudget.job(
            width: 320, height: 240, fps: 24, seconds: 3_600,
            sampleRate: 48_000, channels: 2, hasSound: true
        ) else {
            failures.append("long budget")
            return
        }
        if long.total <= short.total || long.soundBytes == 0 {
            failures.append("long small picture \(long.total) sound \(long.soundBytes)")
        }
        if StorageBudget.job(width: 1920, height: 1080, fps: 24, seconds: .infinity, sampleRate: 48_000, channels: 2, hasSound: false) != nil {
            failures.append("infinite movie was measured")
        }
        if StorageBudget.refusal(short, free: nil) == nil {
            failures.append("missing free space was allowed")
        }
        if StorageBudget.refusal(short, free: 20_000_000_000) != nil {
            failures.append("short job was refused")
        }
        if StorageBudget.refusal(long, free: 3_000_000_000) == nil {
            failures.append("long job was allowed")
        }
        let preview = ReadLimit.make(.preview, frameBudget: nil)
        if preview.maxFrames != 600 || preview.maxSeconds != 20 || preview.maxCacheBytes == nil {
            failures.append("preview cap changed")
        }
        let full = ReadLimit.make(.full, frameBudget: picture)
        if full.maxFrames != nil || full.maxSeconds != nil || full.maxCacheBytes != nil || full.frameBudget != picture {
            failures.append("full cap changed")
        }
    }

    private static func checkMovie(_ failures: inout [String]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Dragonreel-test-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = Reel.memory(
                frames: (0..<8).map { tagged(frame: $0, width: 64, height: 48) },
                width: 64, height: 48, fps: 24, name: "tiny"
            )
            let folded = try ReelFold.permute(
                source: source, axis: .both, tile: 16, run: 2,
                key: "paper", passes: 1, reverse: false
            )
            let url = directory.appendingPathComponent("tiny.dragon.mp4")
            attachTone(folded, per: 2_000, tail: 0)
            _ = try MovieIO.write(reel: folded, note: folded.mark?.note, to: url, replacing: nil)
            guard let text = try MovieIO.noteText(in: url), let mark = ReelMark.parse(text) else {
                failures.append("movie note missing")
                return
            }
            if mark.axis != .both || mark.tile != 16 || mark.run != 2 || mark.passes != 1 || !mark.keyed {
                failures.append("movie note fields \(mark)")
            }
            let loaded = try MovieIO.load(url) { _ in }
            if loaded.width != 64 || loaded.height != 48 {
                failures.append("movie size \(loaded.width)×\(loaded.height)")
            }
            if loaded.count != 8 {
                failures.append("movie frames \(loaded.count)")
            }
            if loaded.mark == nil {
                failures.append("loaded movie dropped the note")
            }
            if loaded.sound == nil || loaded.sound?.channels != 1 || loaded.sound?.sampleRate != 48_000 {
                failures.append("loaded movie dropped the sound")
            }
            let plain = directory.appendingPathComponent("plain.mp4")
            _ = try MovieIO.write(reel: source, note: nil, to: plain, replacing: nil)
            if try MovieIO.noteText(in: plain) != nil {
                failures.append("plain movie carried a note")
            }
            let long = Reel.memory(
                frames: (0..<48).map { tagged(frame: $0, width: 16, height: 16) },
                width: 16, height: 16, fps: 24, name: "long"
            )
            attachTone(long, per: 2_000, tail: 0, channels: 2)
            let longURL = directory.appendingPathComponent("long.mp4")
            let warning = try MovieIO.write(reel: long, note: nil, to: longURL, replacing: nil)
            if warning != nil { failures.append("long movie left the sound out: \(warning!)") }
            let played = try MovieIO.load(longURL) { _ in }
            if played.count != 48 { failures.append("long movie frames \(played.count)") }
            if played.sound == nil || played.sound?.channels != 2 {
                failures.append("long movie dropped the sound")
            }
            if let frames = played.sound?.frames, frames < 90_000 {
                failures.append("long movie sound frames \(frames)")
            }
        } catch {
            failures.append("movie: \(error.localizedDescription)")
        }
    }

    private static func checkCLI(_ failures: inout [String]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Dragonreel-cli-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let folded = directory.appendingPathComponent("reel.dragon.mp4")
            let line = try CLI.perform([
                "Dragonreel", "--reel", "--key", "paper", "--passes", "1",
                "--axis", "scale", "--tile", "16",
                "--out", folded.path,
            ])
            if !line.contains("fold note kept") { failures.append("cli line: \(line)") }
            if !FileManager.default.fileExists(atPath: folded.path) { failures.append("cli file missing") }
            let loaded = try MovieIO.load(folded) { _ in }
            if loaded.mark?.axis != .scale || loaded.mark?.keyed != true {
                failures.append("cli note \(String(describing: loaded.mark))")
            }
            if loaded.count != DemoReel.frames || loaded.width != DemoReel.width {
                failures.append("cli reel \(loaded.width)×\(loaded.height) \(loaded.count)")
            }
            let restored = directory.appendingPathComponent("reel.restored.mp4")
            let back = try CLI.perform([
                "Dragonreel", "--restore", "--input", folded.path, "--key", "paper",
                "--out", restored.path,
            ])
            if !back.contains("restored") { failures.append("cli restore: \(back)") }
            let plain = try MovieIO.load(restored) { _ in }
            if plain.mark != nil { failures.append("restored file kept a note") }
            if plain.count != loaded.count { failures.append("restore frame count") }
            do {
                _ = try CLI.perform([
                    "Dragonreel", "--input", folded.path, "--out", directory.appendingPathComponent("again.mp4").path,
                ])
                failures.append("cli folded a file that was already folded")
            } catch {
                let message = error.localizedDescription
                if !message.contains("already folded") { failures.append("cli refuse: \(message)") }
            }
        } catch {
            failures.append("cli: \(error.localizedDescription)")
        }
    }

    private static func solidReel(frames: Int, width: Int, height: Int) -> Reel {
        let buffers = (0..<frames).map { frame -> [UInt8] in
            [UInt8](repeating: UInt8(frame), count: width * height * 4)
        }
        return Reel.memory(frames: buffers, width: width, height: height, fps: 24, name: "solid")
    }

    /// Red is x, green is y, blue is the frame. The map has to keep that pixel's place across frames.
    private static func tagged(frame: Int, width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                pixels[index] = UInt8(x)
                pixels[index + 1] = UInt8(y)
                pixels[index + 2] = UInt8(frame)
            }
        }
        return pixels
    }

    private static func locate(r: UInt8, g: UInt8, frame: [UInt8], width: Int) -> (x: Int, y: Int, b: UInt8)? {
        var index = 0
        var n = 0
        while index + 3 < frame.count {
            if frame[index] == r && frame[index + 1] == g {
                return (n % width, n / width, frame[index + 2])
            }
            index += 4
            n += 1
        }
        return nil
    }

    private static func channel(_ pixels: [UInt8], _ offset: Int) -> UInt8? {
        guard pixels.count >= 4 else { return nil }
        let first = pixels[offset]
        var index = offset
        while index < pixels.count {
            if pixels[index] != first { return nil }
            index += 4
        }
        return first
    }

    private static func pixel(_ pixels: [UInt8], width: Int, x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        let index = (y * width + x) * 4
        return (pixels[index], pixels[index + 1], pixels[index + 2])
    }

    private static func checkSound(_ failures: inout [String]) {
        do {
            let source = Reel.memory(
                frames: (0..<4).map { tagged(frame: $0, width: 64, height: 64) },
                width: 64, height: 64, fps: 24, name: "sound"
            )
            attachTone(source, per: 32, tail: 0)
            let scaled = try ReelFold.permute(
                source: source, axis: .scale, tile: 16, run: 1,
                key: "paper", passes: 1, reverse: false
            )
            guard let scaledSound = scaled.sound, let plainSound = source.sound else {
                failures.append("scale dropped the sound")
                return
            }
            if scaledSound == plainSound { failures.append("scale left the sound alone") }
            if !frameSoundsStayHome(plainSound, scaledSound, frames: 4, per: 32) {
                failures.append("scale mixed sound across frames")
            }
            if !sameSoundPermutation(scaledSound, frames: 4, per: 32) {
                failures.append("scale used a different sound map on a later frame")
            }
            let back = try ReelFold.restore(source: scaled, mark: scaled.mark!, phrase: "paper")
            if back.sound != source.sound { failures.append("scale sound restore") }

            attachTone(source, per: 18, tail: 3)
            let edged = try ReelFold.permute(
                source: source, axis: .scale, tile: 16, run: 1,
                key: "", passes: 1, reverse: false
            )
            if let sound = edged.sound {
                for frame in 0..<4 {
                    let base = frame * 18
                    let tail = Array(sound.samples[(base + 16)..<(base + 18)])
                    let want = [Int16(frame * 100 + 16), Int16(frame * 100 + 17)]
                    if tail != want { failures.append("sound edge moved on frame \(frame)") }
                }
                if Array(sound.samples.suffix(3)) != [800, 801, 802] {
                    failures.append("sound tail moved on scale")
                }
            } else {
                failures.append("scale dropped the edged sound")
            }
            let edgeBack = try ReelFold.restore(source: edged, mark: edged.mark!, phrase: "")
            if edgeBack.sound != source.sound { failures.append("scale edge restore") }

            attachTone(source, per: 8, tail: 0)
            let fine = try ReelFold.permute(
                source: source, axis: .scale, tile: 16, run: 1,
                key: "paper", passes: 1, reverse: false
            )
            if fine.sound == source.sound { failures.append("short frame did not move samples") }
            if let fineSound = fine.sound, let plain = source.sound,
               !frameSoundsStayHome(plain, fineSound, frames: 4, per: 8) {
                failures.append("short frame mixed sound across frames")
            }
            let fineBack = try ReelFold.restore(source: fine, mark: fine.mark!, phrase: "paper")
            if fineBack.sound != source.sound { failures.append("short sound restore") }

            let timed = Reel.memory(
                frames: (0..<8).map { tagged(frame: $0, width: 16, height: 16) },
                width: 16, height: 16, fps: 24, name: "timed"
            )
            attachTone(timed, per: 8, tail: 3)
            let folded = try ReelFold.permute(
                source: timed, axis: .fold, tile: 16, run: 2,
                key: "", passes: 1, reverse: false
            )
            guard let moved = folded.sound else {
                failures.append("fold dropped the sound")
                return
            }
            if Array(moved.samples.suffix(3)) != [800, 801, 802] { failures.append("fold tail moved") }
            var intact = true
            var jumped = false
            for frame in 0..<8 {
                let slice = Array(moved.samples[(frame * 8)..<((frame + 1) * 8)])
                let owner = Int(slice[0]) / 100
                let expected = (0..<8).map { Int16(owner * 100 + $0) }
                if slice != expected { intact = false }
                if owner != frame { jumped = true }
            }
            if !intact { failures.append("fold broke sound inside a frame") }
            if !jumped { failures.append("fold did not move a frame of sound") }
            let foldBack = try ReelFold.restore(source: folded, mark: folded.mark!, phrase: "")
            if foldBack.sound != timed.sound { failures.append("fold sound restore") }

            attachTone(source, per: 32, tail: 3)
            let together = try ReelFold.permute(
                source: source, axis: .both, tile: 16, run: 2,
                key: "paper", passes: 2, reverse: false
            )
            let scaledFirst = try ReelFold.permute(
                source: source, axis: .scale, tile: 16, run: 2,
                key: "paper", passes: 2, reverse: false
            )
            let thenFold = try ReelFold.permute(
                source: scaledFirst, axis: .fold, tile: 16, run: 2,
                key: "paper", passes: 2, reverse: false
            )
            if together.sound != thenFold.sound { failures.append("sound did not commute") }
            if Array(together.sound?.samples.suffix(3) ?? []) != [800, 801, 802] {
                failures.append("both tail moved")
            }
            let bothBack = try ReelFold.restore(source: together, mark: together.mark!, phrase: "paper")
            if bothBack.sound != source.sound { failures.append("both sound restore") }

            attachTone(source, per: 16, tail: 0, channels: 2)
            let stereo = try ReelFold.permute(
                source: source, axis: .both, tile: 16, run: 2,
                key: "paper", passes: 1, reverse: false
            )
            if let sound = stereo.sound {
                if sound.channels != 2 { failures.append("stereo channels") }
                var pair = true
                var index = 0
                while index + 1 < sound.samples.count {
                    if sound.samples[index + 1] != sound.samples[index] &+ 1 { pair = false }
                    index += 2
                }
                if !pair { failures.append("stereo pair split") }
            } else {
                failures.append("stereo dropped")
            }
            let stereoBack = try ReelFold.restore(source: stereo, mark: stereo.mark!, phrase: "paper")
            if stereoBack.sound != source.sound { failures.append("stereo restore") }

            let filed = Reel.memory(
                frames: (0..<4).map { tagged(frame: $0, width: 64, height: 64) },
                width: 64, height: 64, fps: 24, name: "filed"
            )
            attachTone(filed, per: 32, tail: 3)
            guard let plain = filed.sound else {
                failures.append("file sound missing")
                return
            }
            let store = try SoundStore(channels: plain.channels)
            try store.append(plain.samples)
            filed.sound = Soundtrack(sampleRate: plain.sampleRate, channels: plain.channels, file: store)
            let memoryReel = Reel.memory(
                frames: (0..<4).map { tagged(frame: $0, width: 64, height: 64) },
                width: 64, height: 64, fps: 24, name: "filed-memory"
            )
            memoryReel.sound = Soundtrack(sampleRate: plain.sampleRate, channels: plain.channels, samples: plain.samples)
            let fromFile = try ReelFold.permute(
                source: filed, axis: .both, tile: 16, run: 2,
                key: "paper", passes: 1, reverse: false
            )
            let fromMemory = try ReelFold.permute(
                source: memoryReel, axis: .both, tile: 16, run: 2,
                key: "paper", passes: 1, reverse: false
            )
            guard let fileSound = fromFile.sound, fileSound.keepsFile, let memorySound = fromMemory.sound else {
                failures.append("file fold dropped the sound")
                return
            }
            let readBack = try fileSound.readSamples(frame: 0, count: fileSound.frames)
            if readBack != memorySound.samples { failures.append("file fold did not match memory") }
            let fileBack = try ReelFold.restore(source: fromFile, mark: fromFile.mark!, phrase: "paper")
            let restored = try fileBack.sound?.readSamples(frame: 0, count: plain.frames) ?? []
            if restored != plain.samples { failures.append("file sound restore") }
        } catch {
            failures.append("sound: \(error.localizedDescription)")
        }
    }

    private static func attachTone(_ reel: Reel, per: Int, tail: Int, channels: Int = 1) {
        var samples: [Int16] = []
        samples.reserveCapacity((reel.count * per + tail) * channels)
        for frame in 0..<reel.count {
            for offset in 0..<per {
                let value = Int16(frame * 100 + offset)
                samples.append(value)
                if channels == 2 { samples.append(value &+ 1) }
            }
        }
        for index in 0..<tail {
            let value = Int16(800 + index)
            samples.append(value)
            if channels == 2 { samples.append(value &+ 1) }
        }
        reel.sound = Soundtrack(sampleRate: 48_000, channels: channels, samples: samples)
    }

    private static func frameSoundsStayHome(_ source: Soundtrack, _ folded: Soundtrack, frames: Int, per: Int) -> Bool {
        guard source.channels == 1, folded.channels == 1, source.samples.count >= frames * per, folded.samples.count >= frames * per else {
            return false
        }
        for frame in 0..<frames {
            let start = frame * per
            let end = start + per
            if source.samples[start..<end].sorted() != folded.samples[start..<end].sorted() { return false }
        }
        return true
    }

    private static func sameSoundPermutation(_ sound: Soundtrack, frames: Int, per: Int) -> Bool {
        func offsets(_ frame: Int) -> [Int] {
            let start = frame * per
            return sound.samples[start..<(start + per)].map { Int($0) - frame * 100 }
        }
        let base = offsets(0)
        for frame in 1..<frames where offsets(frame) != base { return false }
        return true
    }

    private static func same(_ left: Reel, _ right: Reel) -> Bool {
        guard left.count == right.count, left.width == right.width, left.height == right.height else { return false }
        if left.sound != right.sound { return false }
        for index in 0..<left.count {
            guard let a = try? left.pixels(at: index), let b = try? right.pixels(at: index), a == b else { return false }
        }
        return true
    }
}
