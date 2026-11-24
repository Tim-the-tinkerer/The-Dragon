import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var phrase = ""
    @Published var showPhrase = false
    @Published var passes = 0
    @Published var unit: ImageUnit = .tile
    @Published var tile = AppInfo.defaultTile
    @Published var spinTiles = false
    @Published var splitChannels = false
    @Published var pairPictures = false
    @Published var includeNote = true
    @Published var treatAsFolded = false
    @Published var busy = false
    @Published var status = "A card is loaded. Fold it, then export."
    @Published var alertMessage: String?
    @Published var targeted = false
    @Published var showHelp = false
    @Published var shownPass = 0
    @Published var drawing = Curve.Drawing(vertices: [], headline: "", detail: "")
    @Published var plainImage: NSImage?
    @Published var foldedImage: NSImage?
    /// True while the right well is the night card, including after that card is fitted to the first picture.
    @Published private(set) var secondIsStandIn = true

    private(set) var plain: Picture?
    private(set) var folded: Picture?
    private(set) var mate: Picture?
    private var openedURL: URL?
    private var job = 0

    private init() {
        plain = Card.make()
        refreshPicture()
        publish()
    }

    var canFold: Bool {
        if busy || plain == nil || plain?.mark?.pair == true { return false }
        if pairPictures && mate == nil { return false }
        return true
    }
    var canRestore: Bool {
        if busy { return false }
        if plain?.mark?.pair == true && mate != nil { return true }
        // A single fold kept in memory stays hidden while Pair is on. Restore the two wells, or turn Pair off.
        if pairPictures {
            return treatAsFolded && plain != nil && mate != nil && plain?.mark == nil
        }
        if folded?.mark != nil { return true }
        if !treatAsFolded { return false }
        return plain != nil || folded != nil
    }
    var canExportFolded: Bool {
        if busy { return false }
        if plain?.mark?.pair == true && mate != nil { return true }
        if pairPictures { return false }
        return folded != nil
    }
    var canSavePlain: Bool {
        if busy { return false }
        if pairPictures { return plain != nil && mate != nil }
        return plain != nil
    }
    var canFoldAgain: Bool {
        if busy { return false }
        if plain?.mark?.pair == true { return mate != nil }
        if pairPictures { return false }
        return folded != nil
    }
    var passCount: Int { (try? currentPlan().count) ?? 1 }
    var hasPlain: Bool { plain != nil }
    var hasFolded: Bool { folded != nil }

    var fileLine: String {
        if pairPictures, let first = plain, let second = mate {
            var line = "\(first.name) · \(first.width)×\(first.height)"
            if first.reduced { line += " · fitted to \(AppInfo.maxSide)" }
            line += " · \(second.name)"
            if second.reduced { line += " · second fitted" }
            return line
        }
        guard let picture = plain ?? folded else { return "No picture" }
        var line = "\(picture.name) · \(picture.width)×\(picture.height)"
        if picture.reduced { line += " · fitted to \(AppInfo.maxSide)" }
        return line
    }

    var layoutLine: String {
        guard let picture = plain ?? folded else { return "No picture." }
        if pairPictures {
            guard mate != nil else { return "Pair needs a second picture." }
            if let limit = ImageFold.pairLimit(width: picture.width, height: picture.height, unit: unit, tile: tile) {
                return limit
            }
            let placed = ImageFold.layout(width: picture.width, height: picture.height, unit: unit, tile: tile)
            let count = ImageFold.pairUnits(width: picture.width, height: picture.height, unit: unit, tile: tile)
            var line = "\(count) segment\(count == 1 ? "" : "s") on the curve, across both pictures."
            if passCount > 0 {
                line += " \(passCount) pass\(passCount == 1 ? "" : "es")."
            }
            if placed.single && unit != .pixel {
                line += " Each picture is one segment, so the two can trade places."
            } else if let edge = edgeSentence(placed) {
                line += " " + edge + " Each picture keeps its own edge."
            }
            return line
        }
        if let limit = ImageFold.limitMessage(width: picture.width, height: picture.height, unit: unit, tile: tile) {
            return limit
        }
        let placed = ImageFold.layout(width: picture.width, height: picture.height, unit: unit, tile: tile)
        var line = "\(placed.units) segment\(placed.units == 1 ? "" : "s") on the curve."
        if passCount > 0 {
            line += " \(passCount) pass\(passCount == 1 ? "" : "es")."
        }
        if placed.single && unit != .pixel {
            line += unit == .tile
                ? " One tile covers the picture, so it will not move."
                : " One strip covers the picture, so it will not move."
        } else if let edge = edgeSentence(placed) {
            line += " " + edge
        }
        return line
    }

    func setPasses(_ value: Int) {
        guard (0...7).contains(value) else { return }
        passes = value
        shownPass = 0
        refreshPicture()
    }

    func refreshPicture() {
        let picture = plain ?? folded
        let width = picture?.width ?? 0
        let height = picture?.height ?? 0
        let placed = ImageFold.layout(width: width, height: height, unit: unit, tile: tile)
        let segments = curveSegments(placed, width: width, height: height)
        do {
            let plan = try currentPlan()
            if shownPass >= plan.count { shownPass = 0 }
            var line = "\(segments) segment\(segments == 1 ? "" : "s")"
            if pairPictures, mate != nil, plain != nil {
                line += " across both pictures"
            }
            if let edge = edgeSentence(placed) {
                line += " · \(edge)"
            }
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

    func useCard() {
        guard !busy else { return }
        job += 1
        openedURL = nil
        plain = Card.make()
        folded = nil
        mate = pairPictures ? Card.mate() : nil
        secondIsStandIn = true
        treatAsFolded = false
        publish()
        status = pairPictures
            ? "Card and night card. \(Card.width)×\(Card.height)."
            : "Card. \(Card.width)×\(Card.height)."
        refreshPicture()
    }

    func setPair(_ on: Bool) {
        guard !busy else { return }
        if on, plain == nil, folded != nil {
            status = "Restore this picture before pairing it. The folded picture stays where it is."
            return
        }
        pairPictures = on
        if on {
            if mate == nil {
                mate = Card.mate()
                secondIsStandIn = true
            }
            if let first = plain, let second = mate,
               second.width != first.width || second.height != first.height,
               let fitted = try? ImageFold.fit(second, width: first.width, height: first.height) {
                mate = fitted
                status = "Second picture fitted to \(first.width)×\(first.height). The two pictures share one dragon."
                publish()
                refreshPicture()
                return
            }
            status = mate?.name == "Night"
                ? "Night card. The two pictures share one dragon."
                : "Pair is on. The two pictures share one dragon."
        } else {
            status = "Pair is off. The second picture is kept."
        }
        publish()
        refreshPicture()
    }

    func openSecondPanel() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image, .png, .jpeg, .tiff, .gif, .heic, .webP]
        panel.message = "Choose a second image. Its pieces mix with the first."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadMate(url)
    }

    func openPanel() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image, .png, .jpeg, .tiff, .gif, .heic, .webP]
        panel.message = "Choose an image to fold."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    /// One file lands on the well under the pointer. Two files fill both wells.
    func loadDropped(_ urls: [URL], ontoSecond: Bool) {
        guard !urls.isEmpty else { return }
        if urls.count >= 2 {
            loadBoth(urls[0], urls[1])
            return
        }
        if ontoSecond {
            loadSecond(urls[0])
        } else {
            load(urls[0])
        }
    }

    func loadSecond(_ url: URL) {
        loadMate(url)
    }

    func load(_ url: URL) {
        guard !busy else {
            status = "Wait for the fold to finish."
            return
        }
        job += 1
        let token = job
        busy = true
        status = "Reading \(url.lastPathComponent)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try PictureLoader.load(url: url) }
            DispatchQueue.main.async {
                guard token == self.job else { return }
                self.busy = false
                switch result {
                case .success(let loaded):
                    self.take(loaded.picture, from: url, warning: loaded.warning)
                case .failure(let error):
                    self.alertMessage = error.localizedDescription
                    self.status = error.localizedDescription
                }
            }
        }
    }

    func fold() {
        guard !busy else { return }
        if pairPictures {
            foldPair()
            return
        }
        guard let source = plain else {
            alertMessage = folded == nil
                ? "Open an image first."
                : "Restore this file before folding it again. Fold Again is in the File menu."
            return
        }
        if source.mark?.pair == true {
            alertMessage = "Turn Pair pictures back on, or use Fold Again."
            return
        }
        if let limit = ImageFold.limitMessage(width: source.width, height: source.height, unit: unit, tile: tile) {
            alertMessage = limit
            return
        }
        let phrase = self.phrase
        let passes = self.passes == 0 ? nil : self.passes
        let unit = self.unit
        let tile = self.tile
        let spinTiles = self.spinTiles
        let splitChannels = self.splitChannels
        startJob(status: "Folding…") { onPass in
            let folded = try ImageFold.permute(
                pixels: source.pixels,
                width: source.width,
                height: source.height,
                unit: unit,
                tile: tile,
                key: phrase,
                passes: passes,
                spin: spinTiles,
                split: splitChannels,
                reverse: false,
                onPass: onPass
            )
            var picture = source
            picture.pixels = folded.pixels
            picture.mark = folded.mark
            return picture
        } finish: { picture in
            self.folded = picture
            self.treatAsFolded = false
            self.publish()
            self.refreshPicture()
            let placed = ImageFold.layout(width: source.width, height: source.height, unit: unit, tile: tile)
            var line = "Folded in \(picture.mark?.passes ?? 0) pass\((picture.mark?.passes ?? 0) == 1 ? "" : "es"), \(picture.mark?.unitLine ?? "")."
            if placed.single {
                line += unit == .tile
                    ? " One tile covers the picture, so it did not move."
                    : " One strip covers the picture, so it did not move."
            } else if let edge = self.edgeSentence(placed) {
                line += " " + edge
            }
            if !placed.single && picture.pixels == source.pixels {
                line += " The picture did not move."
            }
            if picture.mark?.spin == true {
                line += " Tiles turned with the pen."
            }
            if picture.mark?.split == true {
                line += " Red, green, and blue walked their own curves."
            }
            self.status = line
        }
    }

    func foldAgain() {
        guard !busy else { return }
        if var first = plain, var second = mate, first.mark?.pair == true {
            if let limit = ImageFold.pairLimit(width: first.width, height: first.height, unit: unit, tile: tile) {
                alertMessage = limit
                return
            }
            pairPictures = true
            first.mark = nil
            second.mark = nil
            plain = first
            mate = second
            secondIsStandIn = false
            folded = nil
            publish()
            status = "The mixed pictures stay. Fold runs another rearrangement."
            fold()
            return
        }
        if pairPictures {
            alertMessage = "Fold the two pictures before folding them again."
            return
        }
        guard let current = folded else {
            alertMessage = "Fold a picture first."
            return
        }
        if let limit = ImageFold.limitMessage(width: current.width, height: current.height, unit: unit, tile: tile) {
            alertMessage = limit
            return
        }
        plain = Picture(
            pixels: current.pixels,
            width: current.width,
            height: current.height,
            name: current.name,
            reduced: current.reduced,
            mark: nil
        )
        folded = nil
        publish()
        status = "The folded picture is now the plain picture. Fold runs another rearrangement."
        fold()
    }

    func restore() {
        guard !busy else { return }
        if plain?.mark?.pair == true || (pairPictures && treatAsFolded && plain != nil && mate != nil && plain?.mark == nil) {
            restorePair()
            return
        }
        if pairPictures {
            alertMessage = "Nothing here is folded. Open a Dragonscale PNG, or turn on Treat as folded."
            return
        }
        let phrase = self.phrase
        let input: Picture
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
                let placed = ImageFold.layout(width: input.width, height: input.height, unit: unit, tile: tile)
                mark = FoldMark(
                    unit: unit,
                    tile: ImageFold.tileSide(unit: unit, tile: tile),
                    passes: plan.count,
                    keyed: !phrase.isEmpty,
                    spin: ImageFold.turnsTiles(spinTiles, unit: unit, layout: placed),
                    split: ImageFold.splitsChannels(splitChannels, unit: unit)
                )
            } catch {
                alertMessage = error.localizedDescription
                return
            }
            freezeMark = false
        } else {
            alertMessage = "Nothing here is folded. Open a Dragonscale PNG, or turn on Treat as folded."
            return
        }
        if let limit = ImageFold.limitMessage(width: input.width, height: input.height, unit: mark.unit, tile: mark.tile) {
            alertMessage = limit
            return
        }
        startJob(status: "Restoring…") { onPass in
            let pixels = try ImageFold.restore(
                pixels: input.pixels,
                width: input.width,
                height: input.height,
                mark: mark,
                phrase: phrase,
                onPass: onPass
            )
            var picture = input
            picture.pixels = pixels
            picture.mark = nil
            return picture
        } finish: { picture in
            self.plain = picture
            if self.folded == nil || !freezeMark {
                var kept = input
                kept.mark = freezeMark ? mark : nil
                self.folded = kept
            }
            self.treatAsFolded = !freezeMark
            self.publish()
            self.refreshPicture()
            self.status = mark.keyed
                ? "Restored with this phrase. A wrong phrase is a different arrangement, not the picture."
                : "Restored. This fold used no phrase."
        }
    }

    func exportFolded() {
        guard !busy else { return }
        if let first = plain, let second = mate, first.mark?.pair == true {
            let suggested = suggestedURL(folded: true)
            let mark = includeNote ? first.mark : nil
            savePanel(title: "Export Folded PNG", prompt: "Export", name: suggested.name, directory: suggested.directory) { url in
                self.writeBuilt(to: url, includeNote: mark != nil, label: "Exported") {
                    try ImageFold.stack(top: first, bottom: second, mark: mark)
                }
            }
            return
        }
        if pairPictures {
            alertMessage = "Fold the two pictures before exporting them."
            return
        }
        guard let folded else {
            alertMessage = "Fold the picture before exporting it."
            return
        }
        let suggested = suggestedURL(folded: true)
        savePanel(title: "Export Folded PNG", prompt: "Export", name: suggested.name, directory: suggested.directory) { url in
            var picture = folded
            if !self.includeNote { picture.mark = nil }
            self.write(picture, to: url, includeNote: self.includeNote && folded.mark != nil, label: "Exported")
        }
    }

    func savePlain() {
        guard !busy else { return }
        if pairPictures, let first = plain, let second = mate {
            let suggested = suggestedURL(folded: false)
            savePanel(title: "Save Plain PNG", prompt: "Save", name: suggested.name, directory: suggested.directory) { url in
                self.writeBuilt(to: url, includeNote: false, label: "Saved") {
                    try ImageFold.stack(top: first, bottom: second, mark: nil)
                }
            }
            return
        }
        guard let plain else {
            alertMessage = "There is no plain picture to save."
            return
        }
        let suggested = suggestedURL(folded: false)
        savePanel(title: "Save Plain PNG", prompt: "Save", name: suggested.name, directory: suggested.directory) { url in
            var picture = plain
            picture.mark = nil
            self.write(picture, to: url, includeNote: false, label: "Saved")
        }
    }

    // MARK: - Private

    private func take(_ picture: Picture, from url: URL, warning: String?) {
        openedURL = url
        treatAsFolded = false
        if picture.mark?.pair == true, let halves = ImageFold.halves(picture) {
            pairPictures = true
            plain = halves.0
            mate = halves.1
            secondIsStandIn = false
            folded = nil
            apply(mark: picture.mark)
            publish()
            refreshPicture()
            var line = "\(picture.name). Two pictures, \(halves.0.width)×\(halves.0.height), stacked."
            if let mark = picture.mark {
                line += mark.keyed
                    ? " Folded, \(mark.passes) passes, \(mark.unitLine). It needs the phrase."
                    : " Folded, \(mark.passes) passes, \(mark.unitLine). No phrase."
                if mark.spin { line += " Tiles turned with the pen." }
                if mark.split { line += " Red, green, and blue walked their own curves." }
            }
            if picture.reduced {
                line += " Loaded a copy fitted to \(AppInfo.maxSide) pixels on the long side."
            }
            if let warning { line += " " + warning }
            status = line
            return
        }
        if picture.mark != nil {
            pairPictures = false
            plain = nil
            folded = picture
            apply(mark: picture.mark)
        } else {
            let previous = mate
            plain = picture
            folded = nil
            refitMate()
            publish()
            refreshPicture()
            var line = "\(picture.name). \(picture.width)×\(picture.height)."
            if picture.reduced {
                line += " Loaded a copy fitted to \(AppInfo.maxSide) pixels on the long side."
            }
            if pairPictures, let previous, let mate,
               previous.width != mate.width || previous.height != mate.height {
                line += " Second picture fitted to \(mate.width)×\(mate.height)."
            }
            if let warning { line += " " + warning }
            status = line
            return
        }
        publish()
        refreshPicture()
        var line = "\(picture.name). \(picture.width)×\(picture.height)."
        if picture.reduced {
            line += " Loaded a copy fitted to \(AppInfo.maxSide) pixels on the long side."
        }
        if let mark = picture.mark {
            line += mark.keyed
                ? " Folded, \(mark.passes) passes, \(mark.unitLine). It needs the phrase."
                : " Folded, \(mark.passes) passes, \(mark.unitLine). No phrase."
            if mark.spin { line += " Tiles turned with the pen." }
            if mark.split { line += " Red, green, and blue walked their own curves." }
        }
        if let warning { line += " " + warning }
        status = line
    }

    private func foldPair() {
        guard plain != nil else {
            alertMessage = "Open an image first."
            return
        }
        if plain?.mark?.pair == true {
            alertMessage = "Restore this file before folding it again. Fold Again is in the File menu."
            return
        }
        guard mate != nil else {
            alertMessage = "Open a second picture."
            return
        }
        let first: Picture
        let second: Picture
        let didFit: Bool
        do {
            let prepared = try matchedPair()
            first = prepared.0
            second = prepared.1
            didFit = prepared.2
        } catch {
            alertMessage = error.localizedDescription
            return
        }
        if let limit = ImageFold.pairLimit(width: first.width, height: first.height, unit: unit, tile: tile) {
            alertMessage = limit
            return
        }
        let phrase = self.phrase
        let passes = self.passes == 0 ? nil : self.passes
        let unit = self.unit
        let tile = self.tile
        let spinTiles = self.spinTiles
        let splitChannels = self.splitChannels
        startPair(status: "Folding…") { onPass in
            let mixed = try ImageFold.permutePair(
                first: first,
                second: second,
                unit: unit,
                tile: tile,
                key: phrase,
                passes: passes,
                spin: spinTiles,
                split: splitChannels,
                reverse: false,
                onPass: onPass
            )
            return (mixed.first, mixed.second)
        } finish: { leading, trailing in
            self.plain = leading
            self.mate = trailing
            self.secondIsStandIn = false
            self.folded = nil
            self.treatAsFolded = false
            self.publish()
            self.refreshPicture()
            let placed = ImageFold.layout(width: first.width, height: first.height, unit: unit, tile: tile)
            var line = "Folded in \(leading.mark?.passes ?? 0) pass\((leading.mark?.passes ?? 0) == 1 ? "" : "es"), \(leading.mark?.unitLine ?? "")."
            if placed.single && unit != .pixel {
                line += " Each picture is one segment, so the two can trade places."
            } else if let edge = self.edgeSentence(placed) {
                line += " " + edge
            }
            if leading.pixels == first.pixels && trailing.pixels == second.pixels {
                line += " The pictures did not move."
            } else {
                line += " Pieces crossed between the pictures."
            }
            if leading.mark?.spin == true { line += " Tiles turned with the pen." }
            if leading.mark?.split == true { line += " Red, green, and blue walked their own curves." }
            if didFit { line += " Second picture fitted to \(first.width)×\(first.height)." }
            self.status = line
        }
    }

    private func restorePair() {
        guard let first = plain, let mate else {
            alertMessage = "Open both pictures."
            return
        }
        let phrase = self.phrase
        let mark: FoldMark
        let freezeMark: Bool
        if let existing = first.mark, existing.pair {
            mark = existing
            freezeMark = true
        } else if treatAsFolded {
            do {
                let plan = try currentPlan()
                let placed = ImageFold.layout(width: first.width, height: first.height, unit: unit, tile: tile)
                mark = FoldMark(
                    unit: unit,
                    tile: ImageFold.tileSide(unit: unit, tile: tile),
                    passes: plan.count,
                    keyed: !phrase.isEmpty,
                    spin: ImageFold.turnsTiles(spinTiles, unit: unit, layout: placed),
                    split: ImageFold.splitsChannels(splitChannels, unit: unit),
                    pair: true
                )
            } catch {
                alertMessage = error.localizedDescription
                return
            }
            freezeMark = false
        } else {
            alertMessage = "Nothing here is folded. Open a Dragonscale PNG, or turn on Treat as folded."
            return
        }
        if let limit = ImageFold.pairLimit(width: first.width, height: first.height, unit: mark.unit, tile: mark.tile) {
            alertMessage = limit
            return
        }
        let host: Picture
        let other: Picture
        if freezeMark {
            guard first.width == mate.width, first.height == mate.height else {
                alertMessage = "The two pictures need the same width and height."
                return
            }
            host = first
            other = mate
        } else {
            do {
                let prepared = try matchedPair()
                host = prepared.0
                other = prepared.1
            } catch {
                alertMessage = error.localizedDescription
                return
            }
        }
        startPair(status: "Restoring…") { onPass in
            try ImageFold.restorePair(first: host, second: other, mark: mark, phrase: phrase, onPass: onPass)
        } finish: { leading, trailing in
            self.plain = leading
            self.mate = trailing
            // Card.mate() is the only picture named Night. A restored night card is the stand-in again.
            self.secondIsStandIn = trailing.name == "Night"
            self.folded = nil
            self.pairPictures = true
            self.treatAsFolded = false
            self.publish()
            self.refreshPicture()
            self.status = mark.keyed
                ? "Restored both pictures with this phrase. A wrong phrase is a different arrangement, not the pictures."
                : "Restored both pictures. This fold used no phrase."
        }
    }

    private func matchedPair() throws -> (Picture, Picture, Bool) {
        guard let first = plain else { throw FoldError(message: "Open an image first.") }
        guard var second = mate else { throw FoldError(message: "Open a second picture.") }
        var fitted = false
        if second.width != first.width || second.height != first.height {
            second = try ImageFold.fit(second, width: first.width, height: first.height)
            fitted = true
            mate = second
        }
        return (first, second, fitted)
    }

    private func loadMate(_ url: URL) {
        guard !busy else {
            status = "Wait for the fold to finish."
            return
        }
        job += 1
        let token = job
        busy = true
        status = "Reading \(url.lastPathComponent)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try PictureLoader.load(url: url) }
            DispatchQueue.main.async {
                guard token == self.job else { return }
                self.busy = false
                switch result {
                case .success(let loaded):
                    self.installMate(loaded.picture, warning: loaded.warning)
                case .failure(let error):
                    self.alertMessage = error.localizedDescription
                    self.status = error.localizedDescription
                }
            }
        }
    }

    private func loadBoth(_ firstURL: URL, _ secondURL: URL) {
        guard !busy else {
            status = "Wait for the fold to finish."
            return
        }
        job += 1
        let token = job
        busy = true
        status = "Reading \(firstURL.lastPathComponent) and \(secondURL.lastPathComponent)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let first = Result { try PictureLoader.load(url: firstURL) }
            let second = Result { try PictureLoader.load(url: secondURL) }
            DispatchQueue.main.async {
                guard token == self.job else { return }
                self.busy = false
                switch (first, second) {
                case let (.success(left), .success(right)):
                    // Two files fill the two wells. A fold note on either file is not a pair stack.
                    var host = left.picture
                    let ignored = host.mark != nil
                    host.mark = nil
                    self.openedURL = firstURL
                    self.treatAsFolded = false
                    self.folded = nil
                    self.plain = host
                    var warning = right.warning
                    if ignored {
                        let sentence = "The fold note on the first picture is not used."
                        warning = warning.map { $0 + " " + sentence } ?? sentence
                    }
                    self.installMate(right.picture, warning: warning)
                case let (.failure(error), _):
                    self.alertMessage = error.localizedDescription
                    self.status = error.localizedDescription
                case let (_, .failure(error)):
                    self.alertMessage = error.localizedDescription
                    self.status = error.localizedDescription
                }
            }
        }
    }

    private func installMate(_ picture: Picture, warning: String?) {
        if plain == nil, folded != nil {
            status = "Restore this picture before adding a second one. The folded picture stays where it is."
            return
        }
        if plain?.mark?.pair == true {
            status = "Restore this pair before replacing the second picture."
            return
        }
        do {
            var incoming = picture
            incoming.mark = nil
            var line: String
            if let host = plain, host.name == "Card", host.width == Card.width, host.height == Card.height,
               incoming.width != host.width || incoming.height != host.height {
                // The built-in card is only a stand-in. A dropped picture keeps its own size.
                plain = try ImageFold.fit(host, width: incoming.width, height: incoming.height)
                mate = incoming
                line = "Second picture. \(incoming.name). \(incoming.width)×\(incoming.height). The card was fitted to it."
            } else if let host = plain {
                let fitted = try ImageFold.fit(incoming, width: host.width, height: host.height)
                let changed = incoming.width != fitted.width || incoming.height != fitted.height
                mate = fitted
                line = changed
                    ? "Second picture fitted to \(fitted.width)×\(fitted.height)."
                    : "Second picture. \(fitted.name). \(fitted.width)×\(fitted.height)."
            } else {
                mate = incoming
                line = "Second picture. \(incoming.name). \(incoming.width)×\(incoming.height)."
            }
            if picture.mark != nil {
                line += " The fold note on the second picture is not used."
            }
            if let warning { line += " " + warning }
            if folded != nil {
                line += " The earlier folded picture was cleared."
            }
            folded = nil
            pairPictures = true
            secondIsStandIn = false
            publish()
            refreshPicture()
            status = line
        } catch {
            alertMessage = error.localizedDescription
            status = error.localizedDescription
        }
    }

    private func apply(mark: FoldMark?) {
        guard let mark else { return }
        unit = mark.unit
        if mark.unit != .pixel { tile = mark.tile }
        spinTiles = mark.spin
        splitChannels = mark.split
        passes = mark.passes
        shownPass = 0
    }

    private func refitMate() {
        guard let first = plain, let second = mate else { return }
        guard second.width != first.width || second.height != first.height else { return }
        if let fitted = try? ImageFold.fit(second, width: first.width, height: first.height) {
            mate = fitted
        }
    }

    private func curveSegments(_ placed: ImageFold.Layout, width: Int, height: Int) -> Int {
        guard pairPictures, mate != nil, plain != nil, width > 0, height > 0 else { return placed.units }
        return ImageFold.pairUnits(width: width, height: height, unit: unit, tile: tile)
    }

    private func startPair(
        status: String,
        work: @escaping (@escaping (Int, Int) -> Void) throws -> (Picture, Picture),
        finish: @escaping (Picture, Picture) -> Void
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
                case .success(let pictures):
                    finish(pictures.0, pictures.1)
                case .failure(let error):
                    self.alertMessage = error.localizedDescription
                    self.status = error.localizedDescription
                }
            }
        }
    }

    private func startJob(
        status: String,
        work: @escaping (@escaping (Int, Int) -> Void) throws -> Picture,
        finish: @escaping (Picture) -> Void
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
                case .success(let picture):
                    finish(picture)
                case .failure(let error):
                    self.alertMessage = error.localizedDescription
                    self.status = error.localizedDescription
                }
            }
        }
    }

    private func publish() {
        plainImage = plain.flatMap(PictureImage.nsImage)
        if pairPictures, plain != nil {
            foldedImage = mate.flatMap(PictureImage.nsImage)
        } else if let folded {
            foldedImage = PictureImage.nsImage(folded)
        } else if pairPictures {
            foldedImage = mate.flatMap(PictureImage.nsImage)
        } else {
            foldedImage = nil
        }
    }

    private func currentPlan() throws -> [Curve.Pass] {
        try Curve.plan(key: phrase, passes: passes == 0 ? nil : passes)
    }

    private func edgeSentence(_ placed: ImageFold.Layout) -> String? {
        if placed.single || (placed.edgeRight == 0 && placed.edgeBottom == 0) { return nil }
        if placed.edgeRight > 0 && placed.edgeBottom > 0 {
            return "Right \(placed.edgeRight) and bottom \(placed.edgeBottom) stay put."
        }
        if placed.edgeRight > 0 { return "Right \(placed.edgeRight) stays put." }
        return "Bottom \(placed.edgeBottom) stays put."
    }

    private func suggestedURL(folded: Bool) -> (name: String, directory: URL) {
        let directory = openedURL?.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let stem = stemName(from: openedURL)
        let name = folded ? "\(stem).dragon.png" : "\(stem).copy.png"
        return (name, directory)
    }

    private func savePanel(title: String, prompt: String, name: String, directory: URL, write: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.title = title
        panel.prompt = prompt
        panel.nameFieldStringValue = name
        panel.directoryURL = directory
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.png]
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension.lowercased() != "png" {
            url = url.appendingPathExtension("png")
        }
        write(url)
    }

    private func write(_ picture: Picture, to url: URL, includeNote: Bool, label: String) {
        if includeNote && picture.mark == nil {
            alertMessage = "There is no fold note to write. Fold the picture first."
            return
        }
        writeBuilt(to: url, includeNote: includeNote, label: label) { picture }
    }

    /// `make` runs off the main thread, so stacking two pictures does not freeze the window.
    private func writeBuilt(
        to url: URL,
        includeNote: Bool,
        label: String,
        make: @escaping () throws -> Picture
    ) {
        let opened = openedURL
        job += 1
        let token = job
        busy = true
        status = "Writing \(url.lastPathComponent)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () -> Void in
                let picture = try make()
                if includeNote && picture.mark == nil {
                    throw FoldError(message: "There is no fold note to write. Fold the picture first.")
                }
                let data = try PNGFile.fileData(picture: picture, includeNote: includeNote)
                try PNGFile.write(data, to: url, replacing: opened)
            }
            DispatchQueue.main.async {
                guard token == self.job else { return }
                self.busy = false
                switch result {
                case .success:
                    self.status = "\(label) \(url.lastPathComponent). The original was left alone."
                case .failure(let error):
                    self.alertMessage = error.localizedDescription
                    self.status = error.localizedDescription
                }
            }
        }
    }
}
