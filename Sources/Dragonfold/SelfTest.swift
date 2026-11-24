import AVFoundation
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
        checkAudio(&failures)
        checkRightTurns(&failures)
        checkChannels(&failures)
        checkWAV(&failures)
        checkCLI(&failures)

        expectThrow("passes 8") {
            _ = try Curve.plan(key: "paper", passes: 8)
        }
        expectThrow("phrase required") {
            let folded = try AudioFold.permute(
                samples: [1, 2, 3, 4],
                frames: 4,
                channels: 1,
                unit: .sample,
                grain: 1,
                key: "paper",
                passes: 1,
                reverse: false
            )
            _ = try AudioFold.restore(
                samples: folded.samples,
                frames: 4,
                channels: 1,
                mark: folded.mark,
                phrase: ""
            )
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
            let pass = try Curve.plan(key: "paper", passes: nil)[0]
            _ = try Curve.vertices(length: 400, pass: pass)
            _ = try Curve.vertices(length: 400, pass: try Curve.plan(key: "", passes: 1)[0])
        } catch {
            failures.append("plan: \(error.localizedDescription)")
        }
    }

    private static func checkAudio(_ failures: inout [String]) {
        do {
            var samples = [Int16]()
            for value in 0..<100 {
                samples.append(Int16(value))
            }
            let folded = try AudioFold.permute(
                samples: samples,
                frames: 100,
                channels: 1,
                unit: .grain,
                grain: 30,
                key: "paper",
                passes: 3,
                reverse: false
            )
            if folded.samples == samples { failures.append("grain fold did not move") }
            if folded.samples.suffix(10) != samples.suffix(10) {
                failures.append("grain tail moved")
            }
            let back = try AudioFold.restore(
                samples: folded.samples,
                frames: 100,
                channels: 1,
                mark: folded.mark,
                phrase: "paper"
            )
            if back != samples { failures.append("grain restore") }
            let wrong = try AudioFold.restore(
                samples: folded.samples,
                frames: 100,
                channels: 1,
                mark: folded.mark,
                phrase: "papers"
            )
            if wrong == samples { failures.append("wrong phrase restored the grain") }
            if folded.mark.passes != 3 || folded.mark.unit != .grain || folded.mark.grain != 30 || !folded.mark.keyed {
                failures.append("grain mark \(folded.mark)")
            }

            var stereo: [Int16] = []
            for frame in 0..<8 {
                stereo.append(Int16(frame + 1))
                stereo.append(Int16((frame + 1) * 10))
            }
            let order = try Curve.rearrange(Array(0..<8), key: "", passes: 1, reverse: false)
            let frames = try AudioFold.permute(
                samples: stereo,
                frames: 8,
                channels: 2,
                unit: .frame,
                grain: 1,
                key: "",
                passes: 1,
                reverse: false
            ).samples
            for (rank, source) in order.enumerated() {
                if frames[rank * 2] != stereo[source * 2] || frames[rank * 2 + 1] != stereo[source * 2 + 1] {
                    failures.append("frame \(rank) did not follow the curve")
                    break
                }
            }
            let samplesOnly = try AudioFold.permute(
                samples: stereo,
                frames: 8,
                channels: 2,
                unit: .sample,
                grain: 1,
                key: "paper",
                passes: 4,
                reverse: false
            )
            let framesKeyed = try AudioFold.permute(
                samples: stereo,
                frames: 8,
                channels: 2,
                unit: .frame,
                grain: 1,
                key: "paper",
                passes: 4,
                reverse: false
            ).samples
            if samplesOnly.samples == framesKeyed { failures.append("sample and frame folds matched") }
            if !samplesOnly.mark.ownDragon { failures.append("sample fold kept one dragon") }
            let sampleBack = try AudioFold.restore(
                samples: samplesOnly.samples,
                frames: 8,
                channels: 2,
                mark: samplesOnly.mark,
                phrase: "paper"
            )
            if sampleBack != stereo { failures.append("sample restore") }

            let tone = Tone.make()
            let toneFold = try AudioFold.permute(
                samples: tone.samples,
                frames: tone.frames,
                channels: tone.channels,
                unit: .grain,
                grain: 1024,
                key: "paper",
                passes: nil,
                reverse: false
            )
            if toneFold.mark.passes != 7 { failures.append("tone passes \(toneFold.mark.passes)") }
            let toneBack = try AudioFold.restore(
                samples: toneFold.samples,
                frames: tone.frames,
                channels: tone.channels,
                mark: toneFold.mark,
                phrase: "paper"
            )
            if toneBack != tone.samples { failures.append("tone restore") }
            if AudioFold.limitMessage(frames: 2_000_000, channels: 2, unit: .sample, grain: 1) != nil {
                failures.append("sample limit still blocks a short song")
            }
            if AudioFold.limitMessage(frames: 48_000 * 600, channels: 2, unit: .sample, grain: 1) != nil {
                failures.append("ten minute sample fold is refused")
            }
            if AudioFold.limitMessage(frames: 48_000 * 600, channels: 2, unit: .frame, grain: 1) != nil {
                failures.append("ten minute frame fold is refused")
            }
            if AudioFold.limitMessage(frames: AppInfo.maxUnits + 1, channels: 1, unit: .sample, grain: 1) == nil {
                failures.append("sample limit missing")
            }

            let wide = 250_000
            var wideSamples = [Int16](repeating: 0, count: wide)
            for index in 0..<wide {
                wideSamples[index] = Int16(truncatingIfNeeded: index &* 17 &+ 3)
            }
            let wideFold = try AudioFold.permute(
                samples: wideSamples,
                frames: wide,
                channels: 1,
                unit: .sample,
                grain: 1,
                key: "paper",
                passes: 2,
                reverse: false
            ).samples
            if wideFold == wideSamples { failures.append("long sample fold did not move") }
            let wideMap = try Curve.indexMap(
                count: wide,
                passes: try Curve.plan(key: "paper", passes: 2),
                reverse: false
            )
            for index in 0..<wide where wideFold[index] != wideSamples[wideMap[index]] {
                failures.append("long sample fold diverged at \(index)")
                break
            }
            let wideBack = try AudioFold.permute(
                samples: wideFold,
                frames: wide,
                channels: 1,
                unit: .sample,
                grain: 1,
                key: "paper",
                passes: 2,
                reverse: true
            ).samples
            if wideBack != wideSamples { failures.append("long sample restore") }
        } catch {
            failures.append("audio: \(error.localizedDescription)")
        }
    }

    private static func checkRightTurns(_ failures: inout [String]) {
        func backward(_ pass: Curve.Pass, _ segment: Int) -> Bool {
            let turn = Curve.paperTurn(pass.skip &+ UInt64(segment) &+ 1)
            return pass.fold * turn == -1
        }
        do {
            let pass = try Curve.plan(key: "", passes: 1)[0]
            if pass.fold != 1 || pass.skip != 0 {
                failures.append("canonical pass is not the plain curve")
            }
            let grain = 30
            let segments = 3
            let frames = grain * segments
            let samples = (1...frames).map { Int16($0) }
            let straight = try AudioFold.permute(
                samples: samples,
                frames: frames,
                channels: 1,
                unit: .grain,
                grain: grain,
                key: "",
                passes: 1,
                reverseRight: false,
                reverse: false
            )
            let turned = try AudioFold.permute(
                samples: samples,
                frames: frames,
                channels: 1,
                unit: .grain,
                grain: grain,
                key: "",
                passes: 1,
                reverseRight: true,
                reverse: false
            )
            if turned.mark.reverseRight == false || straight.mark.reverseRight {
                failures.append("reverse mark")
            }
            if turned.samples == straight.samples {
                failures.append("right turns did not change the grain")
            }
            let order = try Curve.segmentOrder(count: segments, pass: pass)
            var sawBackward = false
            for rank in 0..<segments {
                let source = Int(order[rank])
                var expect = Array(samples[(source * grain)..<((source + 1) * grain)])
                if backward(pass, source) {
                    expect.reverse()
                    sawBackward = true
                }
                let got = Array(turned.samples[(rank * grain)..<((rank + 1) * grain)])
                if got != expect {
                    failures.append("grain \(rank) from segment \(source)")
                    break
                }
            }
            if !sawBackward { failures.append("plain curve had no right turn") }
            let back = try AudioFold.restore(
                samples: turned.samples,
                frames: frames,
                channels: 1,
                mark: turned.mark,
                phrase: ""
            )
            if back != samples { failures.append("right-turn restore") }

            let lone = (1...20).map { Int16($0) }
            let loneFold = try AudioFold.permute(
                samples: lone,
                frames: lone.count,
                channels: 1,
                unit: .grain,
                grain: 1024,
                key: "paper",
                passes: 1,
                reverseRight: true,
                reverse: false
            )
            if loneFold.samples != Array(lone.reversed()) {
                failures.append("single right turn did not reverse the grain")
            }
            let loneBack = try AudioFold.restore(
                samples: loneFold.samples,
                frames: lone.count,
                channels: 1,
                mark: loneFold.mark,
                phrase: "paper"
            )
            if loneBack != lone { failures.append("single grain restore") }

            let channels = 2
            let span = 2
            let stereoFrames = span * segments
            var stereo: [Int16] = []
            for frame in 0..<stereoFrames {
                stereo.append(Int16(frame + 1))
                stereo.append(Int16(100 + frame))
            }
            let stereoFold = try AudioFold.permute(
                samples: stereo,
                frames: stereoFrames,
                channels: channels,
                unit: .grain,
                grain: span,
                key: "",
                passes: 1,
                reverseRight: true,
                reverse: false
            ).samples
            let stereoOrder = try Curve.segmentOrder(count: segments, pass: pass)
            for rank in 0..<segments {
                let source = Int(stereoOrder[rank])
                var chunk: [[Int16]] = []
                for frame in 0..<span {
                    let at = (source * span + frame) * channels
                    chunk.append([stereo[at], stereo[at + 1]])
                }
                if backward(pass, source) { chunk.reverse() }
                var mismatch = false
                for frame in 0..<span {
                    let at = (rank * span + frame) * channels
                    if stereoFold[at] != chunk[frame][0] || stereoFold[at + 1] != chunk[frame][1] {
                        mismatch = true
                    }
                }
                if mismatch {
                    failures.append("stereo grain \(rank)")
                    break
                }
            }

            let longCount = 100
            let long = (1...longCount).map { Int16($0) }
            let longFold = try AudioFold.permute(
                samples: long,
                frames: longCount,
                channels: 1,
                unit: .grain,
                grain: 30,
                key: "paper",
                passes: 3,
                reverseRight: true,
                reverse: false
            )
            if Array(longFold.samples.suffix(10)) != Array(long.suffix(10)) {
                failures.append("right-turn tail moved")
            }
            let longBack = try AudioFold.restore(
                samples: longFold.samples,
                frames: longCount,
                channels: 1,
                mark: longFold.mark,
                phrase: "paper"
            )
            if longBack != long { failures.append("right-turn multi restore") }
            let plainFold = try AudioFold.permute(
                samples: long,
                frames: longCount,
                channels: 1,
                unit: .grain,
                grain: 30,
                key: "paper",
                passes: 3,
                reverse: false
            )
            if plainFold.samples == longFold.samples {
                failures.append("right turns matched a plain grain fold")
            }

            let bits = (1...16).map { Int16($0) }
            let sampleOn = try AudioFold.permute(
                samples: bits,
                frames: bits.count,
                channels: 1,
                unit: .sample,
                grain: 1,
                key: "paper",
                passes: 2,
                reverseRight: true,
                reverse: false
            )
            let sampleOff = try AudioFold.permute(
                samples: bits,
                frames: bits.count,
                channels: 1,
                unit: .sample,
                grain: 1,
                key: "paper",
                passes: 2,
                reverse: false
            )
            if sampleOn.samples != sampleOff.samples || sampleOn.mark.reverseRight {
                failures.append("sample mode reversed a turn")
            }

            let clip = Clip(
                samples: turned.samples,
                frames: frames,
                channels: 1,
                sampleRate: 44_100,
                name: "turns",
                truncated: false,
                mark: turned.mark
            )
            let data = try WAVFile.encode(clip: clip, includeNote: true)
            guard let parsed = WAVFile.parse(data, name: "turns.dragon")?.clip else {
                failures.append("right-turn note did not parse")
                return
            }
            if parsed.mark != turned.mark { failures.append("right-turn note dropped the flag") }
            let noted = try AudioFold.restore(
                samples: parsed.samples,
                frames: parsed.frames,
                channels: parsed.channels,
                mark: parsed.mark!,
                phrase: ""
            )
            if noted != samples { failures.append("noted right-turn restore") }
        } catch {
            failures.append("right turns: \(error.localizedDescription)")
        }
    }

    private static func checkChannels(_ failures: inout [String]) {
        func side(_ samples: [Int16], _ channel: Int) -> [Int16] {
            stride(from: channel, to: samples.count, by: 2).map { samples[$0] }
        }
        do {
            let frames = 8
            var stereo: [Int16] = []
            for frame in 0..<frames {
                stereo.append(Int16(frame + 1))
                stereo.append(Int16(100 + frame))
            }
            let folded = try AudioFold.permute(
                samples: stereo,
                frames: frames,
                channels: 2,
                unit: .sample,
                grain: 1,
                key: "paper",
                passes: 2,
                reverse: false
            )
            let leftIn = side(stereo, 0)
            let rightIn = side(stereo, 1)
            let leftOut = side(folded.samples, 0)
            let rightOut = side(folded.samples, 1)
            if leftOut.sorted() != leftIn.sorted() || rightOut.sorted() != rightIn.sorted() {
                failures.append("a sample changed channel")
            }
            let plan = try Curve.plan(key: "paper", passes: 2)
            let leftMap = try Curve.indexMap(count: frames, passes: plan, reverse: false)
            let mirror = plan.map {
                Curve.Pass(fold: -$0.fold, heading: $0.heading, skip: $0.skip, view: $0.view)
            }
            let rightMap = try Curve.indexMap(count: frames, passes: mirror, reverse: false)
            if leftMap == rightMap { failures.append("the mirror dragon matched the phrase") }
            for index in 0..<frames {
                if leftOut[index] != leftIn[leftMap[index]] || rightOut[index] != rightIn[rightMap[index]] {
                    failures.append("channel \(index) left the dragon")
                    break
                }
            }
            let back = try AudioFold.restore(
                samples: folded.samples,
                frames: frames,
                channels: 2,
                mark: folded.mark,
                phrase: "paper"
            )
            if back != stereo { failures.append("channel restore") }

            let shared = try AudioFold.permute(
                samples: stereo,
                frames: frames,
                channels: 2,
                unit: .sample,
                grain: 1,
                key: "paper",
                passes: 2,
                channelDragons: false,
                reverse: false
            )
            if shared.mark.ownDragon { failures.append("shared dragon was marked per channel") }
            let sharedMap = try Curve.indexMap(count: stereo.count, passes: plan, reverse: false)
            for index in 0..<stereo.count where shared.samples[index] != stereo[sharedMap[index]] {
                failures.append("shared dragon diverged at \(index)")
                break
            }
            let sharedBack = try AudioFold.restore(
                samples: shared.samples,
                frames: frames,
                channels: 2,
                mark: shared.mark,
                phrase: "paper"
            )
            if sharedBack != stereo { failures.append("shared dragon restore") }

            let clip = Clip(
                samples: folded.samples,
                frames: frames,
                channels: 2,
                sampleRate: 44_100,
                name: "sides",
                truncated: false,
                mark: folded.mark
            )
            let data = try WAVFile.encode(clip: clip, includeNote: true)
            guard let parsed = WAVFile.parse(data, name: "sides.dragon")?.clip else {
                failures.append("channel note did not parse")
                return
            }
            if parsed.mark?.ownDragon != true { failures.append("channel note dropped the flag") }
        } catch {
            failures.append("channels: \(error.localizedDescription)")
        }
    }

    private static func checkWAV(_ failures: inout [String]) {
        do {
            let tone = Tone.make(seconds: 0.2)
            let folded = try AudioFold.permute(
                samples: tone.samples,
                frames: tone.frames,
                channels: tone.channels,
                unit: .grain,
                grain: 128,
                key: "paper",
                passes: 2,
                reverse: false
            )
            var clip = tone
            clip.samples = folded.samples
            clip.mark = folded.mark
            let data = try WAVFile.encode(clip: clip, includeNote: true)
            if tag(data, 0) != "RIFF" || tag(data, 8) != "WAVE" || tag(data, 12) != "fmt " || tag(data, 36) != "data" {
                failures.append("WAV header is not a plain PCM header")
            }
            let dataBytes = Int(readU32(data, 40))
            let noteAt = 44 + dataBytes
            if tag(data, noteAt) != "dcaf" {
                failures.append("fold note is not after the audio")
            }
            guard let parsed = WAVFile.parse(data, name: "tone.dragon") , let read = parsed.clip else {
                failures.append("parse failed")
                return
            }
            if read.samples != folded.samples { failures.append("parsed samples differ") }
            if read.mark != folded.mark { failures.append("parsed mark differs") }
            let back = try AudioFold.restore(
                samples: read.samples,
                frames: read.frames,
                channels: read.channels,
                mark: read.mark!,
                phrase: "paper"
            )
            if back != tone.samples { failures.append("WAV restore") }

            var tampered = data
            if tampered.count > 80 { tampered[80] ^= 0xFF }
            let broken = WAVFile.parse(tampered, name: "tampered")
            if broken?.clip?.mark != nil { failures.append("tampered file kept its note") }
            if broken?.warning == nil { failures.append("tampered file did not warn") }

            let plain = try WAVFile.encode(clip: tone, includeNote: false)
            if tag(plain, 36) != "data" { failures.append("plain WAV header") }
            if WAVFile.parse(plain, name: "plain")?.clip?.mark != nil {
                failures.append("plain WAV grew a note")
            }

            let folder = FileManager.default.temporaryDirectory
            let path = folder.appendingPathComponent("dragonfold-self-\(UUID().uuidString).wav")
            try WAVFile.write(data, to: path, replacing: nil)
            defer { try? FileManager.default.removeItem(at: path) }
            do {
                try WAVFile.write(data, to: path, replacing: path)
                failures.append("same path was replaced")
            } catch {
                // The original stays.
            }
            if let file = try? AVAudioFile(forReading: path) {
                if file.length != AVAudioFramePosition(tone.frames) {
                    failures.append("AVAudioFile length \(file.length)")
                }
                if file.fileFormat.channelCount != 2 {
                    failures.append("AVAudioFile channels \(file.fileFormat.channelCount)")
                }
            } else {
                failures.append("AVAudioFile could not open the WAV")
            }
            let info = afinfo(path)
            if !info.contains("WAVE") || !(info.contains("Int16") || info.lowercased().contains("16-bit") || info.contains("lpcm")) {
                failures.append("afinfo:\n\(info)")
            }
        } catch {
            failures.append("wav: \(error.localizedDescription)")
        }
    }

    private static func checkCLI(_ failures: inout [String]) {
        let folder = FileManager.default.temporaryDirectory
        let folded = folder.appendingPathComponent("dragonfold-cli-\(UUID().uuidString).wav")
        let restored = folder.appendingPathComponent("dragonfold-back-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: folded)
            try? FileManager.default.removeItem(at: restored)
        }
        do {
            _ = try CLI.perform([
                "Dragonfold", "--tone", "--seconds", "0.2", "--key", "paper",
                "--passes", "2", "--grain", "128", "--out", folded.path,
            ])
            guard let parsed = WAVFile.parse(try Data(contentsOf: folded), name: "cli"), let clip = parsed.clip else {
                failures.append("CLI wav did not parse")
                return
            }
            if clip.mark == nil { failures.append("CLI wav has no note") }
            let tone = Tone.make(seconds: 0.2)
            if clip.samples == tone.samples { failures.append("CLI fold did not move the tone") }
            _ = try CLI.perform([
                "Dragonfold", "--restore", "--input", folded.path, "--key", "paper", "--out", restored.path,
            ])
            guard let back = WAVFile.parse(try Data(contentsOf: restored), name: "back")?.clip else {
                failures.append("CLI restore did not parse")
                return
            }
            if back.samples != tone.samples { failures.append("CLI restore did not match the tone") }
            if back.mark != nil { failures.append("CLI restore kept a fold note") }
        } catch {
            failures.append("cli: \(error.localizedDescription)")
        }
    }

    private static func tag(_ data: Data, _ offset: Int) -> String {
        guard offset >= 0, offset + 4 <= data.count else { return "" }
        return String(bytes: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
    }

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func afinfo(_ url: URL) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/afinfo")
        task.arguments = [url.path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return "afinfo failed: \(error.localizedDescription)"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
