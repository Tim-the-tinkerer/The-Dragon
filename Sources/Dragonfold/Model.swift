import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var phrase = ""
    @Published var showPhrase = false
    @Published var passes = 0
    @Published var unit: AudioUnit = .grain
    @Published var grain = AppInfo.defaultGrain
    @Published var reverseRight = false
    @Published var includeNote = true
    @Published var treatAsFolded = false
    @Published var hearFolded = false
    @Published var volume: Double = 0.7
    @Published var isPlaying = false
    @Published var playhead: Double = 0
    @Published var busy = false
    @Published var status = "A short tone is loaded. Fold it, then play."
    @Published var alertMessage: String?
    @Published var targeted = false
    @Published var showHelp = false
    @Published var shownPass = 0
    @Published var drawing = Curve.Drawing(vertices: [], headline: "", detail: "")
    @Published var wave = WavePeaks.empty
    @Published var waveIsFolded = false

    private(set) var plain: Clip?
    private(set) var folded: Clip?
    private var openedURL: URL?
    private var plainWave = WavePeaks.empty
    private var foldedWave = WavePeaks.empty
    private var job = 0
    private let playback = Playback()

    private init() {
        plain = Tone.make()
        refreshPicture()
        publishWave()
    }

    var canFold: Bool { plain != nil && !busy }
    var canRestore: Bool {
        if busy { return false }
        if folded?.mark != nil { return true }
        if !treatAsFolded { return false }
        return plain != nil || folded != nil
    }
    var canExportFolded: Bool { folded != nil && !busy }
    var canSavePlain: Bool { plain != nil && !busy }
    var passCount: Int { (try? currentPlan().count) ?? 1 }
    var hasPlain: Bool { plain != nil }
    var hasFolded: Bool { folded != nil }
    var channelCount: Int { (plain ?? folded)?.channels ?? 1 }

    var segmentCount: Int {
        guard let clip = plain ?? folded else { return 0 }
        return AudioFold.unitCount(frames: clip.frames, channels: clip.channels, unit: unit, grain: grain)
    }

    var tailFrames: Int {
        guard let clip = plain ?? folded else { return 0 }
        return AudioFold.layout(frames: clip.frames, channels: clip.channels, unit: unit, grain: grain).tailFrames
    }

    var limitText: String? {
        guard let clip = plain ?? folded else { return nil }
        return AudioFold.limitMessage(frames: clip.frames, channels: clip.channels, unit: unit, grain: grain)
    }

    var fileLine: String {
        guard let clip = plain ?? folded else { return "No audio" }
        var line = "\(clip.name) · \(clock(clip.duration)) · \(rateLabel(clip.sampleRate)) · \(clip.isStereo ? "stereo" : "mono")"
        if clip.truncated { line += " · first 10 min" }
        return line
    }

    func setPasses(_ value: Int) {
        guard (0...7).contains(value) else { return }
        passes = value
        shownPass = 0
        refreshPicture()
    }

    func refreshPicture() {
        let clip = plain ?? folded
        let frames = clip?.frames ?? 0
        let channels = clip?.channels ?? 1
        let count = AudioFold.unitCount(frames: frames, channels: channels, unit: unit, grain: grain)
        let layout = AudioFold.layout(frames: frames, channels: channels, unit: unit, grain: grain)
        do {
            let plan = try currentPlan()
            if shownPass >= plan.count { shownPass = 0 }
            var line = "\(count) segment\(count == 1 ? "" : "s")"
            if unit == .sample && channels > 1 {
                line += " on each channel"
            }
            if layout.tailFrames > 0 {
                line += " · last \(layout.tailFrames) frames stay"
            }
            drawing = try Curve.drawing(segments: count, passes: plan, shown: shownPass, unitLine: line)
        } catch {
            drawing = Curve.Drawing(vertices: [], headline: "The curve can't be drawn.", detail: error.localizedDescription)
        }
    }

    func togglePlay() {
        if isPlaying {
            stop()
            return
        }
        guard let clip = audible() else {
            alertMessage = "There is no audio to play."
            return
        }
        do {
            try playback.play(clip, volume: Float(volume))
            isPlaying = true
            waveIsFolded = hearFolded && folded != nil
            publishWave()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func stop() {
        playback.stop()
        isPlaying = false
        playhead = 0
    }

    func tick() {
        guard isPlaying else { return }
        if let progress = playback.progress() {
            playhead = progress
        } else if !playback.isPlaying {
            isPlaying = false
            playhead = 0
        }
    }

    func setVolume(_ value: Double) {
        volume = min(1, max(0, value))
        playback.setVolume(Float(volume))
    }

    func hear(_ foldedAudio: Bool) {
        hearFolded = foldedAudio
        waveIsFolded = foldedAudio && folded != nil
        publishWave()
        if isPlaying { togglePlay(); togglePlay() }
    }

    func useTone() {
        guard !busy else { return }
        stop()
        job += 1
        openedURL = nil
        plain = Tone.make()
        folded = nil
        treatAsFolded = false
        hearFolded = false
        plainWave = AudioFold.peaks(of: plain!)
        foldedWave = .empty
        publishWave()
        status = "Tone. \(clock(plain?.duration ?? 0)) · \(rateLabel(AppInfo.toneRate)) · stereo."
        refreshPicture()
    }

    func openPanel() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio, .wav, .aiff, .mp3, .mpeg4Audio]
        panel.message = "Choose an audio file to fold."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    func load(_ url: URL) {
        guard !busy else {
            status = "Wait for the fold to finish."
            return
        }
        stop()
        busy = true
        status = "Reading \(url.lastPathComponent)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try SongLoader.load(url: url) }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let loaded):
                    self.take(loaded.clip, from: url, warning: loaded.warning)
                case .failure(let error):
                    self.alertMessage = error.localizedDescription
                    self.status = error.localizedDescription
                }
            }
        }
    }

    func fold() {
        guard let source = plain else {
            alertMessage = folded == nil
                ? "Open an audio file first."
                : "Restore this file before folding it again. Fold Again is in the File menu."
            return
        }
        if let limit = AudioFold.limitMessage(frames: source.frames, channels: source.channels, unit: unit, grain: grain) {
            alertMessage = limit
            return
        }
        let phrase = self.phrase
        let passes = self.passes == 0 ? nil : self.passes
        let unit = self.unit
        let grain = self.grain
        let reverseRight = unit == .grain && self.reverseRight
        let units = AudioFold.unitCount(frames: source.frames, channels: source.channels, unit: unit, grain: grain)
        let label = unit == .sample && units > 2_000_000 ? "Folding a long file…" : "Folding…"
        startJob(status: label) { onPass in
            try AudioFold.permute(
                samples: source.samples,
                frames: source.frames,
                channels: source.channels,
                unit: unit,
                grain: grain,
                key: phrase,
                passes: passes,
                reverseRight: reverseRight,
                reverse: false,
                onPass: onPass
            )
        } finish: { output, mark in
            var clip = source
            clip.samples = output
            clip.mark = mark
            clip.name = source.name
            self.folded = clip
            self.hearFolded = true
            self.treatAsFolded = false
            self.foldedWave = AudioFold.peaks(of: clip)
            self.waveIsFolded = true
            self.publishWave()
            self.refreshPicture()
            let tail = AudioFold.layout(frames: source.frames, channels: source.channels, unit: unit, grain: grain).tailFrames
            var line = "Folded in \(mark.passes) pass\(mark.passes == 1 ? "" : "es"), \(mark.unitLine)."
            if tail > 0 {
                line += " The last \(tail) frames stay put."
            }
            if mark.reverseRight {
                line += " Right turns play backward."
            }
            if output == source.samples {
                line += " One segment, so the audio did not move."
            }
            self.status = line
            if self.isPlaying {
                self.stop()
                self.togglePlay()
            }
        }
    }

    func stepPass(_ delta: Int) {
        let count = passCount
        guard count > 1 else { return }
        shownPass = (shownPass + delta % count + count) % count
        refreshPicture()
    }

    func foldAgain() {
        guard let current = folded else {
            alertMessage = "Fold some audio first."
            return
        }
        if let limit = AudioFold.limitMessage(frames: current.frames, channels: current.channels, unit: unit, grain: grain) {
            alertMessage = limit
            return
        }
        plain = Clip(
            samples: current.samples,
            frames: current.frames,
            channels: current.channels,
            sampleRate: current.sampleRate,
            name: current.name,
            truncated: current.truncated,
            mark: nil
        )
        plainWave = AudioFold.peaks(of: plain!)
        folded = nil
        foldedWave = .empty
        hearFolded = false
        publishWave()
        status = "The folded audio is now the plain audio. Fold runs another rearrangement."
        fold()
    }

    func restore() {
        let phrase = self.phrase
        let input: Clip
        let mark: FoldMark
        let freezeMark: Bool
        if let folded, let existing = folded.mark {
            input = folded
            mark = existing
            freezeMark = true
        } else if treatAsFolded, let candidate = folded ?? plain {
            input = candidate
            do {
                let plan = try currentPlan()
                mark = FoldMark(
                    unit: unit,
                    grain: unit == .grain ? AudioFold.grainSize(unit: unit, grain: grain) : 1,
                    passes: plan.count,
                    keyed: !phrase.isEmpty,
                    reverseRight: unit == .grain && reverseRight,
                    ownDragon: unit == .sample && candidate.channels > 1
                )
            } catch {
                alertMessage = error.localizedDescription
                return
            }
            freezeMark = false
        } else {
            alertMessage = "Nothing here is folded. Open a Dragonfold WAV, or turn on Treat as folded."
            return
        }
        if let limit = AudioFold.limitMessage(frames: input.frames, channels: input.channels, unit: mark.unit, grain: mark.grain) {
            alertMessage = limit
            return
        }
        let units = AudioFold.unitCount(frames: input.frames, channels: input.channels, unit: mark.unit, grain: mark.grain)
        let label = mark.unit == .sample && units > 2_000_000 ? "Restoring a long file…" : "Restoring…"
        startJob(status: label) { onPass in
            let samples = try AudioFold.restore(
                samples: input.samples,
                frames: input.frames,
                channels: input.channels,
                mark: mark,
                phrase: phrase,
                onPass: onPass
            )
            return (samples, mark)
        } finish: { samples, mark in
            var clip = input
            clip.samples = samples
            clip.mark = nil
            self.plain = clip
            if self.folded == nil || !freezeMark {
                var kept = input
                kept.mark = freezeMark ? mark : nil
                self.folded = kept
                self.foldedWave = AudioFold.peaks(of: kept)
            }
            self.plainWave = AudioFold.peaks(of: clip)
            self.hearFolded = false
            self.treatAsFolded = !freezeMark
            self.waveIsFolded = false
            self.publishWave()
            self.refreshPicture()
            self.status = mark.keyed
                ? "Restored with this phrase. A wrong phrase is a different arrangement, not the recording."
                : "Restored. This fold used no phrase."
            if self.isPlaying {
                self.stop()
                self.togglePlay()
            }
        }
    }

    func exportFolded() {
        guard let folded else {
            alertMessage = "Fold the audio before exporting it."
            return
        }
        let suggested = suggestedURL(folded: true)
        savePanel(title: "Export Folded WAV", name: suggested.name, directory: suggested.directory) { url in
            var clip = folded
            if !self.includeNote { clip.mark = nil }
            self.write(clip, to: url, includeNote: self.includeNote && folded.mark != nil, label: "Exported")
        }
    }

    func savePlain() {
        guard let plain else {
            alertMessage = "There is no plain audio to save."
            return
        }
        let suggested = suggestedURL(folded: false)
        savePanel(title: "Save Plain WAV", name: suggested.name, directory: suggested.directory) { url in
            var clip = plain
            clip.mark = nil
            self.write(clip, to: url, includeNote: false, label: "Saved")
        }
    }

    // MARK: - Private

    private func take(_ clip: Clip, from url: URL, warning: String?) {
        openedURL = url
        treatAsFolded = false
        if clip.mark != nil {
            plain = nil
            folded = clip
            plainWave = .empty
            foldedWave = AudioFold.peaks(of: clip)
            hearFolded = true
            waveIsFolded = true
            unit = clip.mark?.unit ?? unit
            if let grain = clip.mark?.grain, clip.mark?.unit == .grain, AudioFold.grains.contains(grain) {
                self.grain = grain
            } else if clip.mark?.unit == .grain, let grain = clip.mark?.grain {
                self.grain = grain
            }
            passes = clip.mark?.passes ?? passes
            reverseRight = clip.mark?.reverseRight ?? false
            shownPass = 0
        } else {
            plain = clip
            folded = nil
            plainWave = AudioFold.peaks(of: clip)
            foldedWave = .empty
            hearFolded = false
            waveIsFolded = false
        }
        publishWave()
        refreshPicture()
        var line = "\(clip.name). \(clock(clip.duration)) · \(rateLabel(clip.sampleRate)) · \(clip.isStereo ? "stereo" : "mono")."
        if clip.truncated { line += " Loaded the first 10 minutes." }
        if let mark = clip.mark {
            line += mark.keyed
                ? " Folded, \(mark.passes) passes, \(mark.unitLine). It needs the phrase."
                : " Folded, \(mark.passes) passes, \(mark.unitLine). No phrase."
            if mark.reverseRight { line += " Right turns play backward." }
        }
        if let warning { line += " " + warning }
        status = line
    }

    private func startJob(
        status: String,
        work: @escaping (@escaping (Int, Int) -> Void) throws -> (samples: [Int16], mark: FoldMark),
        finish: @escaping ([Int16], FoldMark) -> Void
    ) {
        job += 1
        let token = job
        busy = true
        self.status = status
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try work { pass, total in
                    DispatchQueue.main.async {
                        guard token == self.job, self.busy else { return }
                        self.status = "\(status) pass \(pass) of \(total)"
                    }
                }
            }
            DispatchQueue.main.async {
                guard token == self.job else { return }
                self.busy = false
                switch result {
                case .success(let output):
                    finish(output.samples, output.mark)
                case .failure(let error):
                    self.alertMessage = error.localizedDescription
                    self.status = error.localizedDescription
                }
            }
        }
    }

    private func audible() -> Clip? {
        if hearFolded, let folded { return folded }
        if let plain { return plain }
        return folded
    }

    private func publishWave() {
        if waveIsFolded, !foldedWave.isEmpty {
            wave = foldedWave
        } else if !plainWave.isEmpty {
            wave = plainWave
        } else {
            wave = foldedWave
        }
    }

    private func currentPlan() throws -> [Curve.Pass] {
        try Curve.plan(key: phrase, passes: passes == 0 ? nil : passes)
    }

    private func suggestedURL(folded: Bool) -> (name: String, directory: URL) {
        let directory = openedURL?.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let stem = stemName(from: openedURL)
        let name = folded ? "\(stem).dragon.wav" : "\(stem).restored.wav"
        return (name, directory)
    }

    private func savePanel(title: String, name: String, directory: URL, write: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.title = title
        panel.prompt = "Export"
        panel.nameFieldStringValue = name
        panel.directoryURL = directory
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.wav]
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension.lowercased() != "wav" {
            url = url.appendingPathExtension("wav")
        }
        write(url)
    }

    private func write(_ clip: Clip, to url: URL, includeNote: Bool, label: String) {
        do {
            var writing = clip
            if !includeNote { writing.mark = nil }
            if includeNote && writing.mark == nil {
                throw FoldError(message: "There is no fold note to write. Fold the audio first.")
            }
            let data = try WAVFile.encode(clip: writing, includeNote: includeNote)
            try WAVFile.write(data, to: url, replacing: openedURL)
            status = "\(label) \(url.lastPathComponent). \(clock(clip.duration)) · \(rateLabel(clip.sampleRate)). The original was left alone."
        } catch {
            alertMessage = error.localizedDescription
            status = error.localizedDescription
        }
    }
}
