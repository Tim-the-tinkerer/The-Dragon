import AppKit
import AVFoundation
import Foundation
import SwiftUI
import UniformTypeIdentifiers

final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var phrase = ""
    @Published var showPhrase = false
    @Published var passes = 0
    @Published var axis: ReelAxis = .scale
    @Published var tile = AppInfo.defaultTile
    @Published var run = AppInfo.defaultRun
    @Published var span: ReelSpan = .preview
    @Published var includeNote = true
    @Published var treatAsFolded = false
    @Published var busy = false
    @Published var status = "A short reel is loaded. Fold it, then export."
    @Published var alertMessage: String?
    @Published var targeted = false
    @Published var showHelp = false
    @Published var shownPass = 0
    @Published var drawing = Curve.Drawing(vertices: [], headline: "", detail: "")
    @Published var still: NSImage?
    @Published var player: AVPlayer?
    @Published var showingFolded = false

    private var plainReel: Reel?
    private var foldedReel: Reel?
    private var openedURL: URL?
    private var plainPreview: URL?
    private var foldedPreview: URL?
    private var looper: AVPlayerLooper?
    private var job = 0
    private var scoped: URL?

    private init() {
        let reel = DemoReel.make()
        plainReel = reel
        still = reel.image()
        refreshPicture()
        stage(reel, foldedSide: false)
    }

    var canFold: Bool { plainReel != nil && !busy }
    var canRestore: Bool {
        if busy { return false }
        if foldedReel?.mark != nil { return true }
        if !treatAsFolded { return false }
        return plainReel != nil || foldedReel != nil
    }
    var canExportFolded: Bool { foldedReel != nil && !busy }
    var canSavePlain: Bool { plainReel != nil && !busy }
    var passCount: Int { (try? currentPlan().count) ?? 1 }
    var hasPlain: Bool { plainReel != nil }
    var hasFolded: Bool { foldedReel != nil }

    var fileLine: String {
        guard let reel = showingFolded ? (foldedReel ?? plainReel) : (plainReel ?? foldedReel) else {
            return "No movie"
        }
        var line = "\(reel.name) · \(reel.width)×\(reel.height) · \(reel.count) frames · \(AppInfo.seconds(reel.duration))"
        if reel.reduced { line += " · fitted" }
        if let sound = reel.sound { line += " · \(sound.summary)" }
        return line
    }

    var layoutLine: String {
        guard let reel = plainReel ?? foldedReel else { return "No movie." }
        if let limit = ReelFold.limitMessage(
            width: reel.width,
            height: reel.height,
            frames: reel.count,
            axis: axis,
            tile: tile,
            run: run
        ) {
            return limit
        }
        var parts: [String] = []
        if axis.usesTiles {
            let placed = ReelFold.spatialLayout(width: reel.width, height: reel.height, tile: tile)
            parts.append("\(placed.units) tile\(placed.units == 1 ? "" : "s")")
            if placed.single {
                parts.append("one tile covers the frame, so the picture will not move")
            } else if let edge = ReelFold.edgeSentence(placed) {
                parts.append(edge)
            }
        }
        if axis.usesRuns {
            let placed = ReelFold.temporalLayout(frames: reel.count, run: run)
            parts.append(ReelFold.runSentence(placed))
        }
        let spatial = axis.usesTiles
            ? ReelFold.spatialLayout(width: reel.width, height: reel.height, tile: tile)
            : nil
        if let clause = ReelFold.soundClause(sound: reel.sound, videoFrames: reel.count, axis: axis, spatial: spatial) {
            parts.append(clause)
        }
        if passCount > 0 {
            parts.append("\(passCount) pass\(passCount == 1 ? "" : "es")")
        }
        let sentences = parts.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
        return sentences.joined(separator: ". ") + "."
    }

    func setPasses(_ value: Int) {
        guard (0...7).contains(value) else { return }
        passes = value
        shownPass = 0
        refreshPicture()
    }

    func refreshPicture() {
        let reel = plainReel ?? foldedReel
        let segments = segmentCount(of: reel)
        let line = unitLine(of: reel, segments: segments)
        do {
            let plan = try currentPlan()
            if shownPass >= plan.count { shownPass = 0 }
            drawing = try Curve.drawing(segments: segments, passes: plan, shown: shownPass, unitLine: line)
        } catch {
            drawing = Curve.Drawing(vertices: [], headline: "The curve can't be drawn.", detail: error.localizedDescription)
        }
    }

    func stepPass(_ delta: Int) {
        let count = passCount
        guard count > 1 else { return }
        shownPass = (shownPass + delta % count + count) % count
        refreshPicture()
    }

    func togglePlay() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    var isPlaying: Bool {
        player?.timeControlStatus == .playing
    }

    func pause() {
        player?.pause()
    }

    func show(_ folded: Bool) {
        showingFolded = folded
        if folded {
            if foldedPreview == nil, let foldedReel {
                still = foldedReel.image()
                player = nil
                stage(foldedReel, foldedSide: true)
                return
            }
        } else if plainPreview == nil, let plainReel {
            still = plainReel.image()
            player = nil
            stage(plainReel, foldedSide: false)
            return
        }
        adoptCurrent()
    }

    func useReel() {
        guard !busy else { return }
        job += 1
        endScope()
        openedURL = nil
        plainPreview = nil
        foldedPreview = nil
        let reel = DemoReel.make()
        plainReel = reel
        foldedReel = nil
        treatAsFolded = false
        showingFolded = false
        still = reel.image()
        player = nil
        looper = nil
        status = "Reel. \(DemoReel.width)×\(DemoReel.height), \(DemoReel.frames) frames."
        refreshPicture()
        stage(reel, foldedSide: false)
    }

    func openPanel() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .video]
        panel.message = "Choose a movie to fold. This version fits it inside 1080p."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    func spanChanged() {
        guard !busy, let url = openedURL else { return }
        load(url)
    }

    func load(_ url: URL) {
        guard !busy else {
            status = "Wait for the fold to finish."
            return
        }
        beginScope(url)
        busy = true
        job += 1
        let token = job
        status = "Reading \(url.lastPathComponent)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let span = self.span
            let result = Result { try MovieIO.load(url, span: span) { line in
                DispatchQueue.main.async {
                    if self.job == token { self.status = line }
                }
            }}
            DispatchQueue.main.async {
                guard self.job == token else { return }
                self.busy = false
                switch result {
                case .success(let reel):
                    self.take(reel, from: url)
                case .failure(let error):
                    self.alertMessage = error.localizedDescription
                    self.status = error.localizedDescription
                }
            }
        }
    }

    func fold() {
        guard !busy else { return }
        guard let source = plainReel else {
            alertMessage = foldedReel == nil
                ? "Open a movie first."
                : "Restore this file before folding it again. Fold Again is in the File menu."
            return
        }
        if let limit = ReelFold.limitMessage(
            width: source.width, height: source.height, frames: source.count,
            axis: axis, tile: tile, run: run
        ) {
            alertMessage = limit
            return
        }
        let phrase = self.phrase
        let passes = self.passes == 0 ? nil : self.passes
        let axis = self.axis
        let tile = self.tile
        let run = self.run
        startJob("Folding…") { progress in
            try ReelFold.permute(
                source: source,
                axis: axis,
                tile: tile,
                run: run,
                key: phrase,
                passes: passes,
                reverse: false,
                onProgress: { progress("Folding \($0.lowercased())…") }
            )
        } finish: { reel in
            self.foldedReel = reel
            self.treatAsFolded = false
            self.showingFolded = true
            self.still = reel.image()
            self.player = nil
            self.refreshPicture()
            self.status = self.foldSentence(reel, source: source, axis: axis, tile: tile, run: run)
            self.stage(reel, foldedSide: true)
        }
    }

    func foldAgain() {
        guard !busy else { return }
        guard let current = foldedReel else {
            alertMessage = "Fold a movie first."
            return
        }
        current.mark = nil
        plainReel = current
        foldedReel = nil
        plainPreview = foldedPreview
        foldedPreview = nil
        showingFolded = false
        status = "The folded reel is now the plain reel. Fold runs another rearrangement."
        refreshPicture()
        fold()
    }

    func restore() {
        guard !busy else { return }
        let phrase = self.phrase
        let input: Reel
        let mark: ReelMark
        let freezeMark: Bool
        if let foldedReel, let existing = foldedReel.mark {
            input = foldedReel
            mark = existing
            freezeMark = true
        } else if treatAsFolded, let candidate = foldedReel ?? plainReel {
            input = candidate
            do {
                let plan = try currentPlan()
                mark = ReelMark(
                    axis: axis,
                    tile: axis.usesTiles ? ReelFold.tileSide(tile) : 0,
                    run: axis.usesRuns ? ReelFold.runLength(run) : 0,
                    passes: plan.count,
                    keyed: !phrase.isEmpty,
                    width: candidate.width,
                    height: candidate.height,
                    frames: candidate.count
                )
            } catch {
                alertMessage = error.localizedDescription
                return
            }
            freezeMark = false
        } else {
            alertMessage = "Nothing here is folded. Open a Dragonreel movie, or turn on Treat as folded."
            return
        }
        startJob("Restoring…") { progress in
            try ReelFold.restore(source: input, mark: mark, phrase: phrase) {
                progress("Restoring \($0.lowercased())…")
            }
        } finish: { reel in
            self.plainReel = reel
            if self.foldedReel == nil || !freezeMark {
                input.mark = freezeMark ? mark : nil
                self.foldedReel = input
            }
            self.treatAsFolded = !freezeMark
            self.showingFolded = false
            self.plainPreview = nil
            self.still = reel.image()
            self.player = nil
            self.refreshPicture()
            self.status = mark.keyed
                ? "Restored with this phrase. A wrong phrase is a different arrangement, not the movie."
                : "Restored. This fold used no phrase."
            self.stage(reel, foldedSide: false)
        }
    }

    func exportFolded() {
        guard !busy else { return }
        guard let foldedReel else {
            alertMessage = "Fold the movie before exporting it."
            return
        }
        let suggested = suggestedURL(folded: true)
        savePanel(title: "Export Folded Movie", name: suggested.name, directory: suggested.directory) { url in
            let note = self.includeNote ? foldedReel.mark?.note : nil
            self.write(foldedReel, to: url, note: note, label: "Exported")
        }
    }

    func savePlain() {
        guard !busy else { return }
        guard let plainReel else {
            alertMessage = "There is no plain movie to save."
            return
        }
        let suggested = suggestedURL(folded: false)
        savePanel(title: "Save Plain Movie", name: suggested.name, directory: suggested.directory) { url in
            self.write(plainReel, to: url, note: nil, label: "Saved")
        }
    }

    // MARK: - Private

    private func take(_ reel: Reel, from url: URL) {
        openedURL = url
        plainPreview = nil
        foldedPreview = nil
        player = nil
        looper = nil
        treatAsFolded = false
        if let mark = reel.mark {
            plainReel = nil
            foldedReel = reel
            axis = mark.axis
            if mark.tile > 0 { tile = mark.tile }
            if mark.run > 0 { run = mark.run }
            passes = mark.passes
            shownPass = 0
            showingFolded = true
        } else {
            plainReel = reel
            foldedReel = nil
            showingFolded = false
        }
        still = reel.image()
        refreshPicture()
        var line = "\(reel.name). \(reel.width)×\(reel.height), \(reel.count) frames, \(AppInfo.seconds(reel.duration))."
        if let clipped = reel.clipped { line += " \(clipped)" }
        if let mark = reel.mark {
            line += mark.keyed
                ? " Folded, \(mark.passes) passes, \(mark.unitLine). It needs the phrase."
                : " Folded, \(mark.passes) passes, \(mark.unitLine). No phrase."
        }
        status = line
        stage(reel, foldedSide: reel.mark != nil)
    }

    private func stage(_ reel: Reel, foldedSide: Bool) {
        job += 1
        let token = job
        let kept = status
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try MovieIO.preview(reel) { line in
                    DispatchQueue.main.async {
                        if self.job == token { self.status = line }
                    }
                }
                DispatchQueue.main.async {
                    guard self.job == token else { return }
                    if foldedSide {
                        self.foldedPreview = url
                    } else {
                        self.plainPreview = url
                    }
                    if self.showingFolded == foldedSide {
                        self.adopt(url)
                    }
                    if self.status.hasPrefix("Writing") {
                        self.status = kept
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.job == token else { return }
                    self.status = error.localizedDescription
                }
            }
        }
    }

    private func adoptCurrent() {
        let url = showingFolded ? foldedPreview : plainPreview
        if let url {
            adopt(url)
        } else {
            player = nil
            looper = nil
            still = (showingFolded ? foldedReel : plainReel)?.image()
        }
    }

    private func adopt(_ url: URL) {
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        looper = AVPlayerLooper(player: queue, templateItem: item)
        queue.play()
        player = queue
    }

    private func foldSentence(_ reel: Reel, source: Reel, axis: ReelAxis, tile: Int, run: Int) -> String {
        var line = "Folded in \(reel.mark?.passes ?? 0) pass\((reel.mark?.passes ?? 0) == 1 ? "" : "es"), \(reel.mark?.unitLine ?? "")."
        if axis.usesTiles {
            let placed = ReelFold.spatialLayout(width: source.width, height: source.height, tile: tile)
            if placed.single {
                line += " One tile covers the frame, so the picture did not move."
            } else if let edge = ReelFold.edgeSentence(placed) {
                line += " \(edge)"
            }
        }
        if axis.usesRuns {
            line += " " + ReelFold.runSentence(ReelFold.temporalLayout(frames: source.count, run: run))
        }
        let spatial = axis.usesTiles
            ? ReelFold.spatialLayout(width: source.width, height: source.height, tile: tile)
            : nil
        if let clause = ReelFold.soundClause(sound: source.sound, videoFrames: source.count, axis: axis, spatial: spatial) {
            line += " \(clause)."
        }
        return line
    }

    private func write(_ reel: Reel, to url: URL, note: String?, label: String) {
        let replacing = openedURL
        startJob("Writing the movie…") { progress in
            let warning = try MovieIO.write(
                reel: reel,
                note: note,
                to: url,
                replacing: replacing,
                progress: progress
            )
            return (reel, warning)
        } finish: { pair in
            var line = "\(label) \(url.lastPathComponent)."
            if note == nil {
                line += " No fold note."
            } else {
                line += " Fold note kept. The phrase is not in the file."
            }
            if let warning = pair.1 { line += " \(warning)" }
            self.status = line
        }
    }

    private func startJob<T>(
        _ label: String,
        work: @escaping (@escaping (String) -> Void) throws -> T,
        finish: @escaping (T) -> Void
    ) {
        job += 1
        let token = job
        busy = true
        status = label
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result<T, Error> {
                try work { line in
                    DispatchQueue.main.async {
                        if self.job == token { self.status = line }
                    }
                }
            }
            DispatchQueue.main.async {
                guard self.job == token else { return }
                self.busy = false
                switch result {
                case .success(let value):
                    finish(value)
                case .failure(let error):
                    self.alertMessage = error.localizedDescription
                    self.status = error.localizedDescription
                }
            }
        }
    }

    private func savePanel(title: String, name: String, directory: URL?, finish: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.mpeg4Movie]
        if let directory { panel.directoryURL = directory }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            finish(url)
        }
    }

    private func suggestedURL(folded: Bool) -> (name: String, directory: URL?) {
        let suffix = folded ? "dragon" : "copy"
        if let openedURL {
            let stem = stemName(from: openedURL)
            return ("\(stem).\(suffix).mp4", openedURL.deletingLastPathComponent())
        }
        return ("reel.\(suffix).mp4", FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first)
    }

    private func currentPlan() throws -> [Curve.Pass] {
        try Curve.plan(key: phrase, passes: passes == 0 ? nil : passes)
    }

    private func segmentCount(of reel: Reel?) -> Int {
        guard let reel else { return 0 }
        switch axis {
        case .scale, .both:
            return ReelFold.spatialLayout(width: reel.width, height: reel.height, tile: tile).units
        case .fold:
            return ReelFold.temporalLayout(frames: reel.count, run: run).units
        }
    }

    private func unitLine(of reel: Reel?, segments: Int) -> String {
        guard let reel else { return "no reel" }
        switch axis {
        case .scale:
            return "\(segments) tiles"
        case .fold:
            return "\(segments) runs"
        case .both:
            let runs = ReelFold.temporalLayout(frames: reel.count, run: run).units
            return "\(segments) tiles · \(runs) runs"
        }
    }

    private func beginScope(_ url: URL) {
        if scoped?.path == url.path { return }
        endScope()
        if url.startAccessingSecurityScopedResource() {
            scoped = url
        }
    }

    private func endScope() {
        scoped?.stopAccessingSecurityScopedResource()
        scoped = nil
    }
}

private func stemName(from url: URL) -> String {
    var stem = url.deletingPathExtension().lastPathComponent
    for suffix in [".dragon", ".copy", ".restored"] {
        if stem.hasSuffix(suffix) {
            stem.removeLast(suffix.count)
            break
        }
    }
    return stem.isEmpty ? "reel" : stem
}
