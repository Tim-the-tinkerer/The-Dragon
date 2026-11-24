import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

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
        checkPixels(&failures)
        checkStrips(&failures)
        checkSpin(&failures)
        checkSplit(&failures)
        checkPair(&failures)
        checkDrop(&failures)
        checkAudit(&failures)
        checkPNG(&failures)
        checkJPEG(&failures)
        checkCLI(&failures)

        expectThrow("passes 8") {
            _ = try Curve.plan(key: "paper", passes: 8)
        }
        expectThrow("phrase required") {
            let folded = try ImageFold.permute(
                pixels: sample(width: 4, height: 2),
                width: 4,
                height: 2,
                unit: .pixel,
                tile: 1,
                key: "paper",
                passes: 1,
                reverse: false
            )
            _ = try ImageFold.restore(
                pixels: folded.pixels,
                width: 4,
                height: 2,
                mark: folded.mark,
                phrase: ""
            )
        }
        if ImageFold.limitMessage(width: 2_000, height: 1_000, unit: .pixel, tile: 1) != nil {
            failures.append("pixel limit on a picture the window can open")
        }
        if ImageFold.limitMessage(width: AppInfo.maxSide, height: AppInfo.maxSide, unit: .pixel, tile: 1) != nil {
            failures.append("full window picture refused in pixel mode")
        }
        if ImageFold.limitMessage(width: 9_000, height: 9_000, unit: .pixel, tile: 1) == nil {
            failures.append("pixel limit missing")
        }
        let orders = [
            Curve.Pass(fold: 1, heading: 0, skip: 0, view: 0),
            Curve.Pass(fold: -1, heading: 2, skip: 17, view: 5),
            Curve.Pass(fold: 1, heading: 3, skip: 1_000_003, view: 7),
        ]
        for (index, pass) in orders.enumerated() {
            do {
                let match = try Curve.readingOrdersMatch(count: 1_800, pass: pass)
                if !match {
                    failures.append("reading order \(index)")
                }
            } catch {
                failures.append("reading order \(index): \(error.localizedDescription)")
            }
        }
        checkLargePixel(&failures)

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

    private static func checkLargePixel(_ failures: inout [String]) {
        let width = 1_600
        let height = 1_000
        let original = sample(width: width, height: height)
        do {
            let folded = try ImageFold.permute(
                pixels: original,
                width: width,
                height: height,
                unit: .pixel,
                tile: 1,
                key: "paper",
                passes: 1,
                reverse: false
            )
            if folded.pixels == original { failures.append("large pixel fold did not move") }
            let back = try ImageFold.restore(
                pixels: folded.pixels,
                width: width,
                height: height,
                mark: folded.mark,
                phrase: "paper"
            )
            if back != original { failures.append("large pixel restore") }
        } catch {
            failures.append("large pixel: \(error.localizedDescription)")
        }
    }

    private static func checkPixels(_ failures: inout [String]) {
        do {
            let width = 42
            let height = 26
            let original = sample(width: width, height: height)
            let folded = try ImageFold.permute(
                pixels: original,
                width: width,
                height: height,
                unit: .tile,
                tile: 8,
                key: "paper",
                passes: 3,
                reverse: false
            )
            if folded.pixels == original { failures.append("tile fold did not move") }
            let placed = ImageFold.layout(width: width, height: height, unit: .tile, tile: 8)
            if placed.edgeRight != 2 || placed.edgeBottom != 2 || placed.columns != 5 || placed.rows != 3 {
                failures.append("layout \(placed.columns)x\(placed.rows) edge \(placed.edgeRight),\(placed.edgeBottom)")
            }
            if !edgeMatches(folded.pixels, original, width: width, height: height, layout: placed) {
                failures.append("tile edge moved")
            }
            let plan = try Curve.plan(key: "paper", passes: 3)
            let map = try Curve.indexMap(count: placed.units, passes: plan, reverse: false)
            let source = map[0]
            let sx = (source % placed.columns) * placed.side
            let sy = (source / placed.columns) * placed.side
            if quad(folded.pixels, width, 0, 0) != quad(original, width, sx, sy) {
                failures.append("tile 0 did not follow the curve")
            }
            let back = try ImageFold.restore(
                pixels: folded.pixels,
                width: width,
                height: height,
                mark: folded.mark,
                phrase: "paper"
            )
            if back != original { failures.append("tile restore") }
            let wrong = try ImageFold.restore(
                pixels: folded.pixels,
                width: width,
                height: height,
                mark: folded.mark,
                phrase: "papers"
            )
            if wrong == original { failures.append("wrong phrase restored the tile") }
            if folded.mark.passes != 3 || folded.mark.unit != .tile || folded.mark.tile != 8 || !folded.mark.keyed {
                failures.append("tile mark \(folded.mark.passes) \(folded.mark.tile) \(folded.mark.keyed)")
            }

            let smallW = 6
            let smallH = 4
            let small = sample(width: smallW, height: smallH)
            let order = try Curve.rearrange(Array(0..<(smallW * smallH)), key: "paper", passes: 2, reverse: false)
            let pixels = try ImageFold.permute(
                pixels: small,
                width: smallW,
                height: smallH,
                unit: .pixel,
                tile: 1,
                key: "paper",
                passes: 2,
                reverse: false
            ).pixels
            for index in 0..<order.count {
                let source = order[index]
                let sx = source % smallW
                let sy = source / smallW
                let dx = index % smallW
                let dy = index / smallW
                if quad(pixels, smallW, dx, dy) != quad(small, smallW, sx, sy) {
                    failures.append("pixel \(index) did not follow the curve")
                    break
                }
            }
            let pixelBack = try ImageFold.permute(
                pixels: pixels,
                width: smallW,
                height: smallH,
                unit: .pixel,
                tile: 1,
                key: "paper",
                passes: 2,
                reverse: true
            ).pixels
            if pixelBack != small { failures.append("pixel restore") }

            let tiny = sample(width: 10, height: 10)
            let held = try ImageFold.permute(
                pixels: tiny,
                width: 10,
                height: 10,
                unit: .tile,
                tile: 16,
                key: "paper",
                passes: 4,
                reverse: false
            ).pixels
            if held != tiny { failures.append("a picture smaller than one tile moved") }

            let card = Card.make()
            let sun = card.pixel(x: 370, y: 68)
            if sun != (Card.brass.r, Card.brass.g, Card.brass.b, 255) {
                failures.append("card sun \(sun)")
            }
            let pane = card.pixel(x: 100, y: 180)
            if pane != (176, 64, 48, 255) {
                failures.append("card window \(pane)")
            }
            if PictureImage.nsImage(card) == nil { failures.append("card image") }
            let cardFold = try ImageFold.permute(
                pixels: card.pixels,
                width: card.width,
                height: card.height,
                unit: .tile,
                tile: 16,
                key: "paper",
                passes: nil,
                reverse: false
            )
            if cardFold.mark.passes != 7 { failures.append("card passes \(cardFold.mark.passes)") }
            if cardFold.pixels == card.pixels { failures.append("card fold did not move") }
            let cardBack = try ImageFold.restore(
                pixels: cardFold.pixels,
                width: card.width,
                height: card.height,
                mark: cardFold.mark,
                phrase: "paper"
            )
            if cardBack != card.pixels { failures.append("card restore") }
        } catch {
            failures.append("pixels: \(error.localizedDescription)")
        }
    }

    private static func checkStrips(_ failures: inout [String]) {
        let width = 42
        let height = 26
        let original = sample(width: width, height: height)
        do {
            let rows = try ImageFold.permute(
                pixels: original,
                width: width,
                height: height,
                unit: .row,
                tile: 4,
                key: "paper",
                passes: 3,
                reverse: false
            )
            let rowLayout = ImageFold.layout(width: width, height: height, unit: .row, tile: 4)
            if rowLayout.columns != 1 || rowLayout.rows != 6 || rowLayout.edgeRight != 0 || rowLayout.edgeBottom != 2
                || rowLayout.spanWidth != width || rowLayout.spanHeight != 4 || rowLayout.units != 6 {
                failures.append("row layout \(rowLayout.columns)x\(rowLayout.rows) edge \(rowLayout.edgeRight),\(rowLayout.edgeBottom)")
            }
            if rows.pixels == original { failures.append("row fold did not move") }
            if !edgeMatches(rows.pixels, original, width: width, height: height, layout: rowLayout) {
                failures.append("row edge moved")
            }
            if !ribbonsMatch(rows.pixels, original, width: width, layout: rowLayout, key: "paper", passes: 3) {
                failures.append("a row did not move as one ribbon")
            }
            let rowBack = try ImageFold.restore(
                pixels: rows.pixels,
                width: width,
                height: height,
                mark: rows.mark,
                phrase: "paper"
            )
            if rowBack != original { failures.append("row restore") }
            let rowWrong = try ImageFold.restore(
                pixels: rows.pixels,
                width: width,
                height: height,
                mark: rows.mark,
                phrase: "papers"
            )
            if rowWrong == original { failures.append("wrong phrase restored the rows") }
            if rows.mark.unit != .row || rows.mark.tile != 4 { failures.append("row mark") }

            let noted = Picture(pixels: rows.pixels, width: width, height: height, name: "rows", reduced: false, mark: rows.mark)
            let data = try PNGFile.fileData(picture: noted, includeNote: true)
            guard case .picture(let read, let w, let h, let payload) = PNGFile.decode(data) else {
                failures.append("row note did not decode")
                return
            }
            if read != rows.pixels || w != width || h != height { failures.append("row PNG pixels") }
            let parsed = PNGFile.mark(from: payload ?? Data(), pixels: read, width: w, height: h)
            if parsed.0 != rows.mark { failures.append("row note \(String(describing: parsed.0))") }

            let columns = try ImageFold.permute(
                pixels: original,
                width: width,
                height: height,
                unit: .column,
                tile: 8,
                key: "paper",
                passes: 2,
                reverse: false
            )
            let columnLayout = ImageFold.layout(width: width, height: height, unit: .column, tile: 8)
            if columnLayout.columns != 5 || columnLayout.rows != 1 || columnLayout.edgeRight != 2 || columnLayout.edgeBottom != 0
                || columnLayout.spanWidth != 8 || columnLayout.spanHeight != height || columnLayout.units != 5 {
                failures.append("column layout \(columnLayout.columns)x\(columnLayout.rows) edge \(columnLayout.edgeRight),\(columnLayout.edgeBottom)")
            }
            if columns.pixels == original { failures.append("column fold did not move") }
            if !edgeMatches(columns.pixels, original, width: width, height: height, layout: columnLayout) {
                failures.append("column edge moved")
            }
            if !ribbonsMatch(columns.pixels, original, width: width, layout: columnLayout, key: "paper", passes: 2) {
                failures.append("a column did not move as one ribbon")
            }
            let columnBack = try ImageFold.restore(
                pixels: columns.pixels,
                width: width,
                height: height,
                mark: columns.mark,
                phrase: "paper"
            )
            if columnBack != original { failures.append("column restore") }

            let shortRows = sample(width: 20, height: 10)
            let heldRows = try ImageFold.permute(
                pixels: shortRows,
                width: 20,
                height: 10,
                unit: .row,
                tile: 16,
                key: "paper",
                passes: 2,
                reverse: false
            ).pixels
            if heldRows != shortRows { failures.append("a picture shorter than one row strip moved") }
            let shortColumns = sample(width: 10, height: 20)
            let heldColumns = try ImageFold.permute(
                pixels: shortColumns,
                width: 10,
                height: 20,
                unit: .column,
                tile: 16,
                key: "paper",
                passes: 2,
                reverse: false
            ).pixels
            if heldColumns != shortColumns { failures.append("a picture narrower than one column strip moved") }
        } catch {
            failures.append("strips: \(error.localizedDescription)")
        }
    }

    /// Every pixel in a ribbon comes from the same place in the source ribbon.
    private static func ribbonsMatch(
        _ folded: [UInt8],
        _ original: [UInt8],
        width: Int,
        layout: ImageFold.Layout,
        key: String,
        passes: Int
    ) -> Bool {
        guard let plan = try? Curve.plan(key: key, passes: passes),
              let map = try? Curve.indexMap(count: layout.units, passes: plan, reverse: false)
        else { return false }
        for dest in 0..<map.count {
            let source = map[dest]
            let sCol = source % layout.columns
            let sRow = source / layout.columns
            let dCol = dest % layout.columns
            let dRow = dest / layout.columns
            let sx = sCol * layout.spanWidth
            let sy = sRow * layout.spanHeight
            let dx = dCol * layout.spanWidth
            let dy = dRow * layout.spanHeight
            for row in 0..<layout.spanHeight {
                for column in 0..<layout.spanWidth {
                    if quad(folded, width, dx + column, dy + row) != quad(original, width, sx + column, sy + row) {
                        return false
                    }
                }
            }
        }
        return true
    }

    private static func checkSpin(_ failures: inout [String]) {
        do {
            let plain = try Curve.plan(key: "", passes: 1)[0]
            let faces = try Curve.headings(count: 4, pass: plain)
            if faces != [0, 1, 2, 1] {
                failures.append("plain headings \(faces)")
            }
            let width = 8
            let height = 2
            var original = [UInt8](repeating: 0, count: width * height * 4)
            func paint(_ tile: Int, _ colors: [(UInt8, UInt8, UInt8)]) {
                let x0 = tile * 2
                for index in 0..<4 {
                    let x = x0 + (index % 2)
                    let y = index / 2
                    let pixel = (y * width + x) * 4
                    original[pixel] = colors[index].0
                    original[pixel + 1] = colors[index].1
                    original[pixel + 2] = colors[index].2
                    original[pixel + 3] = 255
                }
            }
            let upright = [(UInt8(255), UInt8(0), UInt8(0)), (0, 255, 0), (0, 0, 255), (255, 255, 255)]
            paint(0, upright)
            paint(1, upright)
            paint(2, [(10, 0, 0), (20, 0, 0), (30, 0, 0), (40, 0, 0)])
            paint(3, [(1, 0, 0), (2, 0, 0), (3, 0, 0), (4, 0, 0)])

            let spun = try ImageFold.permute(
                pixels: original,
                width: width,
                height: height,
                unit: .tile,
                tile: 2,
                key: "",
                passes: 1,
                spin: true,
                reverse: false
            )
            if !spun.mark.spin { failures.append("spin mark") }
            let still = try ImageFold.permute(
                pixels: original,
                width: width,
                height: height,
                unit: .tile,
                tile: 2,
                key: "",
                passes: 1,
                reverse: false
            )
            if still.mark.spin || still.pixels == spun.pixels {
                failures.append("spin matched a plain tile fold")
            }
            let order = try Curve.segmentOrder(count: 4, pass: plain)
            guard let east = order.firstIndex(of: 0),
                  let north = order.firstIndex(of: 1),
                  let west = order.firstIndex(of: 2)
            else {
                failures.append("spin order")
                return
            }
            if quad(spun.pixels, width, east * 2, 0) != (255, 0, 0, 255)
                || quad(spun.pixels, width, east * 2 + 1, 1) != (255, 255, 255, 255) {
                failures.append("east tile turned")
            }
            // North is 90° clockwise: blue red / white green.
            if quad(spun.pixels, width, north * 2, 0) != (0, 0, 255, 255)
                || quad(spun.pixels, width, north * 2 + 1, 0) != (255, 0, 0, 255)
                || quad(spun.pixels, width, north * 2, 1) != (255, 255, 255, 255)
                || quad(spun.pixels, width, north * 2 + 1, 1) != (0, 255, 0, 255) {
                failures.append("north tile is not 90°")
            }
            // West is 180°: 40 30 / 20 10.
            if quad(spun.pixels, width, west * 2, 0).0 != 40
                || quad(spun.pixels, width, west * 2 + 1, 0).0 != 30
                || quad(spun.pixels, width, west * 2, 1).0 != 20
                || quad(spun.pixels, width, west * 2 + 1, 1).0 != 10 {
                failures.append("west tile is not 180°")
            }
            let back = try ImageFold.restore(
                pixels: spun.pixels,
                width: width,
                height: height,
                mark: spun.mark,
                phrase: ""
            )
            if back != original { failures.append("spin restore") }

            let note = PNGFile.notePayload(mark: spun.mark, width: width, height: height, pixels: spun.pixels)
            if note.count != PNGFile.noteSize || note[0] != 2 || note[3] != 2 {
                failures.append("spin note \(note.count) \(note.first ?? 0) \(note.count > 3 ? note[3] : 0)")
            }
            let keyed = FoldMark(unit: .tile, tile: 2, passes: 1, keyed: true, spin: true)
            let keyedNote = PNGFile.notePayload(mark: keyed, width: width, height: height, pixels: spun.pixels)
            if keyedNote[0] != 2 || keyedNote[3] != 3 { failures.append("keyed spin flags") }
            var unknown = keyedNote
            unknown[3] = 4
            if PNGFile.mark(from: unknown, pixels: spun.pixels, width: width, height: height).0 != nil {
                failures.append("unknown spin flag accepted")
            }
            let picture = Picture(pixels: spun.pixels, width: width, height: height, name: "spin", reduced: false, mark: spun.mark)
            let data = try PNGFile.fileData(picture: picture, includeNote: true)
            guard case .picture(let read, _, _, let payload) = PNGFile.decode(data) else {
                failures.append("spin PNG did not decode")
                return
            }
            let parsed = PNGFile.mark(from: payload ?? Data(), pixels: read, width: width, height: height)
            if parsed.0 != spun.mark { failures.append("spin PNG mark") }

            let broad = sample(width: 16, height: 16)
            let turned = try ImageFold.permute(
                pixels: broad,
                width: 16,
                height: 16,
                unit: .tile,
                tile: 4,
                key: "paper",
                passes: 3,
                spin: true,
                reverse: false
            )
            if !turned.mark.spin || turned.pixels == broad { failures.append("multi spin did not move") }
            let turnedBack = try ImageFold.restore(
                pixels: turned.pixels,
                width: 16,
                height: 16,
                mark: turned.mark,
                phrase: "paper"
            )
            if turnedBack != broad { failures.append("multi spin restore") }
            let turnedWrong = try ImageFold.restore(
                pixels: turned.pixels,
                width: 16,
                height: 16,
                mark: turned.mark,
                phrase: "papers"
            )
            if turnedWrong == broad { failures.append("wrong phrase restored a spun tile") }
            let plainFold = try ImageFold.permute(
                pixels: broad,
                width: 16,
                height: 16,
                unit: .tile,
                tile: 4,
                key: "paper",
                passes: 3,
                reverse: false
            )
            if plainFold.pixels == turned.pixels || plainFold.mark.spin {
                failures.append("multi spin matched a plain fold")
            }

            let edged = sample(width: 18, height: 10)
            let edgeLayout = ImageFold.layout(width: 18, height: 10, unit: .tile, tile: 8)
            let edgeFold = try ImageFold.permute(
                pixels: edged,
                width: 18,
                height: 10,
                unit: .tile,
                tile: 8,
                key: "",
                passes: 1,
                spin: true,
                reverse: false
            )
            if !edgeMatches(edgeFold.pixels, edged, width: 18, height: 10, layout: edgeLayout) {
                failures.append("spin edge moved")
            }

            let pixels = sample(width: 6, height: 4)
            let pixelFold = try ImageFold.permute(
                pixels: pixels,
                width: 6,
                height: 4,
                unit: .pixel,
                tile: 1,
                key: "",
                passes: 1,
                spin: true,
                reverse: false
            )
            if pixelFold.mark.spin || pixelFold.pixels != stillPixels(pixels, width: 6, height: 4) {
                failures.append("pixel mode spun")
            }
            let rows = try ImageFold.permute(
                pixels: sample(width: 8, height: 8),
                width: 8,
                height: 8,
                unit: .row,
                tile: 4,
                key: "",
                passes: 1,
                spin: true,
                reverse: false
            )
            if rows.mark.spin { failures.append("a row strip spun") }
            let tiny = try ImageFold.permute(
                pixels: sample(width: 4, height: 4),
                width: 4,
                height: 4,
                unit: .tile,
                tile: 1,
                key: "",
                passes: 1,
                spin: true,
                reverse: false
            )
            if tiny.mark.spin { failures.append("a one-pixel tile spun") }
            let held = sample(width: 10, height: 10)
            let covered = try ImageFold.permute(
                pixels: held,
                width: 10,
                height: 10,
                unit: .tile,
                tile: 16,
                key: "",
                passes: 1,
                spin: true,
                reverse: false
            )
            if covered.mark.spin || covered.pixels != held {
                failures.append("a picture smaller than one tile spun")
            }
        } catch {
            failures.append("spin: \(error.localizedDescription)")
        }
    }

    private static func checkSplit(_ failures: inout [String]) {
        let width = 4
        let height = 3
        let count = width * height
        var original = [UInt8](repeating: 0, count: count * 4)
        for index in 0..<count {
            let at = index * 4
            original[at] = UInt8(index + 1)
            original[at + 1] = UInt8(80 + index)
            original[at + 2] = UInt8(160 + index)
            original[at + 3] = index == 2 ? 128 : 255
        }
        func source(_ map: [Int], _ index: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            let place = map[index]
            return quad(original, width, place % width, place / width)
        }
        do {
            let folded = try ImageFold.permute(
                pixels: original,
                width: width,
                height: height,
                unit: .pixel,
                tile: 1,
                key: "paper",
                passes: 1,
                split: true,
                reverse: false
            )
            if !folded.mark.split || folded.mark.unitLine != "pixel, each channel" {
                failures.append("split mark")
            }
            let plan = try Curve.plan(key: "paper", passes: 1)
            let red = try Curve.indexMap(count: count, passes: plan, reverse: false)
            let mirrored = plan.map {
                Curve.Pass(fold: -$0.fold, heading: $0.heading, skip: $0.skip, view: $0.view)
            }
            let blue = try Curve.indexMap(count: count, passes: mirrored, reverse: false)
            let green = try Curve.indexMap(count: count, passes: try Curve.plan(key: "", passes: 1), reverse: false)
            if red == blue || red == green || blue == green {
                failures.append("channel curves were not distinct")
            }
            if red[2] == 2 && green[2] == 2 && blue[2] == 2 {
                failures.append("channels left pixel 2 in place")
            }
            for index in 0..<count {
                let got = quad(folded.pixels, width, index % width, index / width)
                let r = source(red, index)
                let g = source(green, index)
                let b = source(blue, index)
                if got.0 != r.0 || got.1 != g.1 || got.2 != b.2 || got.3 != original[index * 4 + 3] {
                    failures.append("channel \(index)")
                    break
                }
            }
            if folded.pixels[2 * 4 + 3] != 128 { failures.append("alpha moved") }
            let back = try ImageFold.restore(
                pixels: folded.pixels,
                width: width,
                height: height,
                mark: folded.mark,
                phrase: "paper"
            )
            if back != original { failures.append("split restore") }
            let wrong = try ImageFold.restore(
                pixels: folded.pixels,
                width: width,
                height: height,
                mark: folded.mark,
                phrase: "papers"
            )
            if wrong == original { failures.append("wrong phrase restored a split") }
            let together = try ImageFold.permute(
                pixels: original,
                width: width,
                height: height,
                unit: .pixel,
                tile: 1,
                key: "paper",
                passes: 1,
                reverse: false
            )
            if together.mark.split || together.pixels == folded.pixels {
                failures.append("split matched one dragon")
            }

            let plainFold = try ImageFold.permute(
                pixels: original,
                width: width,
                height: height,
                unit: .pixel,
                tile: 1,
                key: "",
                passes: 1,
                split: true,
                reverse: false
            )
            let plainMap = try Curve.indexMap(count: count, passes: try Curve.plan(key: "", passes: 1), reverse: false)
            let plainMirror = try Curve.indexMap(
                count: count,
                passes: [Curve.Pass(fold: -1, heading: 0, skip: 0, view: 0)],
                reverse: false
            )
            if plainMap == plainMirror { failures.append("plain mirror matched the plain curve") }
            let plainAt = quad(plainFold.pixels, width, 0, 0)
            if plainAt.0 != source(plainMap, 0).0 || plainAt.1 != source(plainMap, 0).1 || plainAt.2 != source(plainMirror, 0).2 {
                failures.append("empty phrase did not keep green on the plain curve")
            }

            let twice = try ImageFold.permute(
                pixels: original,
                width: width,
                height: height,
                unit: .pixel,
                tile: 1,
                key: "paper",
                passes: 2,
                split: true,
                reverse: false
            )
            let twiceBack = try ImageFold.restore(
                pixels: twice.pixels,
                width: width,
                height: height,
                mark: twice.mark,
                phrase: "paper"
            )
            if twiceBack != original { failures.append("split two-pass restore") }

            let tileOn = try ImageFold.permute(
                pixels: sample(width: 8, height: 8),
                width: 8,
                height: 8,
                unit: .tile,
                tile: 4,
                key: "paper",
                passes: 1,
                split: true,
                reverse: false
            )
            let tileOff = try ImageFold.permute(
                pixels: sample(width: 8, height: 8),
                width: 8,
                height: 8,
                unit: .tile,
                tile: 4,
                key: "paper",
                passes: 1,
                reverse: false
            )
            if tileOn.mark.split || tileOn.pixels != tileOff.pixels {
                failures.append("a tile fold split its colors")
            }

            let note = PNGFile.notePayload(mark: folded.mark, width: width, height: height, pixels: folded.pixels)
            if note.count != PNGFile.noteSize || note[0] != 3 || note[3] != 5 {
                failures.append("split note \(note.count) \(note.first ?? 0) \(note.count > 3 ? note[3] : 0)")
            }
            var unknown = note
            unknown[3] = 13
            if PNGFile.mark(from: unknown, pixels: folded.pixels, width: width, height: height).0 != nil {
                failures.append("unknown channel flag accepted")
            }
            let picture = Picture(pixels: folded.pixels, width: width, height: height, name: "split", reduced: false, mark: folded.mark)
            let data = try PNGFile.fileData(picture: picture, includeNote: true)
            guard case .picture(let read, _, _, let payload) = PNGFile.decode(data) else {
                failures.append("split PNG did not decode")
                return
            }
            if PNGFile.mark(from: payload ?? Data(), pixels: read, width: width, height: height).0 != folded.mark {
                failures.append("split PNG mark")
            }
        } catch {
            failures.append("split: \(error.localizedDescription)")
        }
    }

    private static func stillPixels(_ pixels: [UInt8], width: Int, height: Int) -> [UInt8] {
        (try? ImageFold.permute(
            pixels: pixels,
            width: width,
            height: height,
            unit: .pixel,
            tile: 1,
            key: "",
            passes: 1,
            reverse: false
        ).pixels) ?? []
    }

    private static func checkPNG(_ failures: inout [String]) {
        do {
            let width = 5
            let height = 3
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            func put(_ x: Int, _ y: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) {
                let index = (y * width + x) * 4
                pixels[index] = r
                pixels[index + 1] = g
                pixels[index + 2] = b
                pixels[index + 3] = a
            }
            put(0, 0, 255, 0, 0, 255)
            put(1, 0, 10, 20, 30, 128)
            put(2, 0, 0, 0, 0, 0)
            put(0, 2, 0, 255, 0, 255)
            put(4, 2, 0, 0, 255, 200)
            let mark = FoldMark(unit: .tile, tile: 2, passes: 3, keyed: true)
            let note = PNGFile.notePayload(mark: mark, width: width, height: height, pixels: pixels)
            var picture = Picture(pixels: pixels, width: width, height: height, name: "swatch", reduced: false, mark: mark)
            let data = try PNGFile.fileData(picture: picture, includeNote: true)
            if data.prefix(8) != PNGFile.signature { failures.append("PNG signature") }
            guard let iend = data.range(of: Data("IEND".utf8), options: .backwards),
                  let noted = data.range(of: Data(PNGFile.noteType.utf8)),
                  noted.lowerBound < iend.lowerBound
            else {
                failures.append("fold note is not before IEND")
                return
            }
            guard case .picture(let read, let w, let h, let payload) = PNGFile.decode(data) else {
                failures.append("exact decode failed")
                return
            }
            if read != pixels || w != width || h != height { failures.append("PNG pixels differ") }
            let parsed = PNGFile.mark(from: payload ?? Data(), pixels: read, width: w, height: h)
            if parsed.0 != mark { failures.append("PNG mark \(String(describing: parsed.0)) \(parsed.1 ?? "")") }
            let corner = topColor(data)
            if corner != "red" { failures.append("PNG top-left is \(corner)") }

            var moved = pixels
            moved[0] = 1
            let stale = try PNGFile.encode(pixels: moved, width: width, height: height, note: note)
            guard case .picture(let stalePixels, _, _, let staleNote) = PNGFile.decode(stale) else {
                failures.append("stale note did not decode")
                return
            }
            let staleMark = PNGFile.mark(from: staleNote ?? Data(), pixels: stalePixels, width: width, height: height)
            if staleMark.0 != nil { failures.append("stale note was trusted") }
            if staleMark.1 == nil { failures.append("stale note did not warn") }

            picture.mark = nil
            let plain = try PNGFile.fileData(picture: picture, includeNote: false)
            if plain.range(of: Data(PNGFile.noteType.utf8)) != nil { failures.append("plain PNG grew a note") }
            if case .picture(_, _, _, let plainNote) = PNGFile.decode(plain), plainNote != nil {
                failures.append("plain decode kept a note")
            }

            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
            else {
                failures.append("ImageIO could not open the PNG")
                return
            }

            let folder = FileManager.default.temporaryDirectory
            let path = folder.appendingPathComponent("dragonscale-self-\(UUID().uuidString).png")
            try PNGFile.write(data, to: path, replacing: nil)
            defer { try? FileManager.default.removeItem(at: path) }
            do {
                try PNGFile.write(data, to: path, replacing: path)
                failures.append("same path was replaced")
            } catch {
                // The original stays.
            }
            let kept = try Data(contentsOf: path)
            if kept != data { failures.append("refused write changed the file") }
        } catch {
            failures.append("png: \(error.localizedDescription)")
        }
    }

    private static func checkJPEG(_ failures: inout [String]) {
        let width = 32
        let height = 24
        let picture = Picture(
            pixels: sample(width: width, height: height),
            width: width,
            height: height,
            name: "jpeg",
            reduced: false,
            mark: nil
        )
        guard let cg = PictureImage.cgImage(picture) else {
            failures.append("jpeg image")
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dragonscale-jpeg-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            failures.append("jpeg destination")
            return
        }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            failures.append("jpeg encode")
            return
        }
        do {
            let loaded = try PictureLoader.load(url: url)
            if loaded.picture.width != width || loaded.picture.height != height {
                failures.append("jpeg size \(loaded.picture.width)x\(loaded.picture.height)")
            }
            if loaded.picture.mark != nil { failures.append("jpeg grew a note") }
            let folded = try ImageFold.permute(
                pixels: loaded.picture.pixels,
                width: loaded.picture.width,
                height: loaded.picture.height,
                unit: .tile,
                tile: 8,
                key: "paper",
                passes: 2,
                reverse: false
            )
            if folded.pixels == loaded.picture.pixels { failures.append("jpeg fold did not move") }
            let back = try ImageFold.restore(
                pixels: folded.pixels,
                width: loaded.picture.width,
                height: loaded.picture.height,
                mark: folded.mark,
                phrase: "paper"
            )
            if back != loaded.picture.pixels { failures.append("jpeg restore") }
        } catch {
            failures.append("jpeg: \(error.localizedDescription)")
        }
    }

    private static func checkCLI(_ failures: inout [String]) {
        let folder = FileManager.default.temporaryDirectory
        let plain = folder.appendingPathComponent("dragonscale-plain-\(UUID().uuidString).png")
        let folded = folder.appendingPathComponent("dragonscale-cli-\(UUID().uuidString).png")
        let restored = folder.appendingPathComponent("dragonscale-back-\(UUID().uuidString).png")
        defer {
            try? FileManager.default.removeItem(at: plain)
            try? FileManager.default.removeItem(at: folded)
            try? FileManager.default.removeItem(at: restored)
        }
        do {
            let card = Card.make()
            let cardPNG = try PNGFile.encode(pixels: card.pixels, width: card.width, height: card.height, note: nil)
            try cardPNG.write(to: plain, options: .atomic)
            let before = try Data(contentsOf: plain)
            do {
                _ = try CLI.perform([
                    "Dragonscale", "--input", plain.path, "--key", "paper", "--out", plain.path,
                ])
                failures.append("CLI replaced the input")
            } catch {
                // The original stays.
            }
            let after = try Data(contentsOf: plain)
            if before != after { failures.append("CLI input bytes changed") }

            _ = try CLI.perform([
                "Dragonscale", "--card", "--key", "paper", "--passes", "2", "--tile", "16",
                "--out", folded.path,
            ])
            let loaded = try PictureLoader.load(url: folded)
            if loaded.picture.mark == nil { failures.append("CLI png has no note") }
            if loaded.picture.pixels == card.pixels { failures.append("CLI fold did not move the card") }
            if loaded.picture.mark?.passes != 2 || loaded.picture.mark?.tile != 16 || loaded.picture.mark?.keyed != true {
                failures.append("CLI mark \(String(describing: loaded.picture.mark))")
            }
            _ = try CLI.perform([
                "Dragonscale", "--restore", "--input", folded.path, "--key", "paper", "--out", restored.path,
            ])
            let back = try PictureLoader.load(url: restored)
            if back.picture.pixels != card.pixels { failures.append("CLI restore") }
            if back.picture.mark != nil { failures.append("CLI restore kept a note") }
        } catch {
            failures.append("cli: \(error.localizedDescription)")
        }
    }

    private static func sample(width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            pixels[index * 4] = UInt8(index & 255)
            pixels[index * 4 + 1] = UInt8((index / 256) & 255)
            pixels[index * 4 + 2] = UInt8(index & 31)
            pixels[index * 4 + 3] = 255
        }
        return pixels
    }

    private static func quad(_ pixels: [UInt8], _ width: Int, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let index = (y * width + x) * 4
        return (pixels[index], pixels[index + 1], pixels[index + 2], pixels[index + 3])
    }

    private static func edgeMatches(
        _ folded: [UInt8],
        _ original: [UInt8],
        width: Int,
        height: Int,
        layout: ImageFold.Layout
    ) -> Bool {
        let coveredW = layout.columns * layout.spanWidth
        let coveredH = layout.rows * layout.spanHeight
        for y in 0..<height {
            for x in 0..<width where x >= coveredW || y >= coveredH {
                if quad(folded, width, x, y) != quad(original, width, x, y) { return false }
            }
        }
        return true
    }

    /// The bitmap's first row is the top of the file. Read the stored bytes, not a color-managed sample.
    private static func topColor(_ data: Data) -> String {
        guard let rep = NSBitmapImageRep(data: data), let bytes = rep.bitmapData else { return "no rep" }
        let samples = rep.samplesPerPixel
        guard samples >= 3, rep.pixelsWide >= 1, rep.pixelsHigh >= 1 else {
            return "samples=\(samples)"
        }
        let top = (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
        let bottomIndex = (rep.pixelsHigh - 1) * rep.bytesPerRow
        let bottom = (Int(bytes[bottomIndex]), Int(bytes[bottomIndex + 1]), Int(bytes[bottomIndex + 2]))
        if top == (255, 0, 0) && bottom == (0, 255, 0) { return "red" }
        return "top=\(top.0),\(top.1),\(top.2) bottom=\(bottom.0),\(bottom.1),\(bottom.2) samples=\(samples) alphaFirst=\(rep.bitmapFormat.contains(.alphaFirst))"
    }

    private static func checkAudit(_ failures: inout [String]) {
        if !CLI.isJob(["Dragonscale", "--tile=8"]) { failures.append("--tile= was not a job") }
        if !CLI.isJob(["Dragonscale", "--passes=2"]) { failures.append("--passes= was not a job") }
        if !CLI.isJob(["Dragonscale", "--unit=row"]) { failures.append("--unit= was not a job") }
        if CLI.isJob(["Dragonscale", "-psn_0_1"]) { failures.append("process serial number started a job") }

        let pixels = sample(width: 4, height: 4)
        let folded = try? ImageFold.permute(
            pixels: pixels, width: 4, height: 4, unit: .tile, tile: 2,
            key: "paper", passes: 1, reverse: false
        )
        if let folded {
            var note = PNGFile.notePayload(mark: folded.mark, width: 4, height: 4, pixels: folded.pixels)
            note[4] = UInt8(5_000 & 0xFF)
            note[5] = UInt8((5_000 >> 8) & 0xFF)
            if PNGFile.mark(from: note, pixels: folded.pixels, width: 4, height: 4).0 != nil {
                failures.append("tile 5000 was trusted")
            }
        } else {
            failures.append("audit fold failed")
        }

        if let encoded = try? PNGFile.encode(pixels: pixels, width: 4, height: 4, note: nil), encoded.count > 12 {
            var spliced = encoded
            spliced.insert(contentsOf: pngChunk("tRNS", Data([0, 255])), at: encoded.count - 12)
            if case .picture = PNGFile.decode(spliced) {
                failures.append("tRNS stayed on the exact path")
            }
            if case .picture = PNGFile.decode(encoded) {
            } else {
                failures.append("plain PNG no longer decodes")
            }
        } else {
            failures.append("audit png encode failed")
        }

        let folder = FileManager.default.temporaryDirectory
        let original = folder.appendingPathComponent("dragonscale-hard-\(UUID().uuidString).png")
        let link = folder.appendingPathComponent("dragonscale-hard-link-\(UUID().uuidString).png")
        defer {
            try? FileManager.default.removeItem(at: original)
            try? FileManager.default.removeItem(at: link)
        }
        do {
            let bytes = try PNGFile.encode(pixels: pixels, width: 4, height: 4, note: nil)
            try bytes.write(to: original, options: .atomic)
            try FileManager.default.linkItem(at: original, to: link)
            if !PNGFile.sameFile(original, link) { failures.append("hard link was treated as a different file") }
            let out = folder.appendingPathComponent("dragonscale-hard-out-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: out) }
            do {
                _ = try CLI.perform([
                    "Dragonscale", "--input", original.path, "--key", "paper", "--out", link.path,
                ])
                failures.append("CLI replaced a hard link of the input")
            } catch {
                // The original stays.
            }
            let after = try Data(contentsOf: original)
            if after != bytes { failures.append("hard link write changed the original") }
        } catch {
            failures.append("hard link: \(error.localizedDescription)")
        }
    }

    private static func pngChunk(_ type: String, _ payload: Data) -> Data {
        var out = Data()
        var length = UInt32(payload.count).bigEndian
        out.append(contentsOf: withUnsafeBytes(of: &length) { Array($0) })
        var crcBytes = Array(type.utf8)
        crcBytes.append(contentsOf: payload)
        out.append(contentsOf: type.utf8)
        out.append(payload)
        var crc = PNGFile.crc32(crcBytes).bigEndian
        out.append(contentsOf: withUnsafeBytes(of: &crc) { Array($0) })
        return out
    }

    private static func checkDrop(_ failures: inout [String]) {
        let first = CGRect(x: 16, y: 70, width: 260, height: 340)
        let second = CGRect(x: 286, y: 70, width: 260, height: 340)
        func land(_ x: CGFloat, _ y: CGFloat, _ pair: Bool, _ standIn: Bool) -> DropLanding {
            DropTarget.choose(
                point: CGPoint(x: x, y: y),
                pairOn: pair,
                first: first,
                second: second,
                secondIsStandIn: standIn
            )
        }
        if land(100, 200, false, true) != .window { failures.append("pair off drop should load the first picture") }
        if land(400, 200, true, true) != .second { failures.append("right well should take the second picture") }
        if land(100, 200, true, true) != .first { failures.append("left well should take the first picture") }
        if land(400, 20, true, false) != .second { failures.append("right column above the well should take the second picture") }
        if land(100, 500, true, true) != .first { failures.append("left column below the well should take the first picture") }
        if land(700, 200, true, true) != .second { failures.append("night card should catch a drop outside the wells") }
        if land(700, 200, true, false) != .window { failures.append("a real second picture should leave outside drops on the first") }
        if DropTarget.choose(point: nil, pairOn: true, first: .zero, second: .zero, secondIsStandIn: true) != .second {
            failures.append("night card should catch a drop before the wells are measured")
        }
        if DropTarget.choose(point: CGPoint(x: 40, y: 40), pairOn: true, first: .zero, second: .zero, secondIsStandIn: false) != .window {
            failures.append("unmeasured wells should leave a real second picture alone")
        }
    }

    private static func checkPair(_ failures: inout [String]) {
        let day = Card.make()
        let night = Card.mate()
        let sun = day.pixel(x: 370, y: 68)
        let moon = night.pixel(x: 370, y: 68)
        if sun.0 != Card.brass.r || sun.1 != Card.brass.g || sun.2 != Card.brass.b {
            failures.append("day card sun moved")
        }
        if moon.0 == Card.brass.r && moon.1 == Card.brass.g && moon.2 == Card.brass.b {
            failures.append("night card used the day sun")
        }
        if night.pixels == day.pixels || night.name != "Night" || night.width != day.width || night.height != day.height {
            failures.append("night card")
        }
        if ImageFold.pairLimit(width: AppInfo.maxSide, height: AppInfo.maxSide, unit: .pixel, tile: 1) == nil {
            failures.append("pair pixel limit missing")
        }
        if ImageFold.pairLimit(width: AppInfo.maxSide, height: AppInfo.maxSide, unit: .tile, tile: 16) != nil {
            failures.append("pair tile of a full picture refused")
        }
        if ImageFold.pairLimit(width: 8, height: 8, unit: .tile, tile: 4) != nil {
            failures.append("small pair refused")
        }

        func picture(_ pixels: [UInt8], _ width: Int, _ height: Int) -> Picture {
            Picture(pixels: pixels, width: width, height: height, name: "pair", reduced: false, mark: nil)
        }
        func wash(_ width: Int, _ height: Int, _ channel: Int) -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            for index in 0..<(width * height) {
                pixels[index * 4 + channel] = UInt8((index % 251) + 1)
                pixels[index * 4 + 3] = 255
            }
            return pixels
        }
        func crossed(_ map: [Int], _ units: Int) -> Bool {
            for dest in 0..<map.count where (dest < units) != (map[dest] < units) { return true }
            return false
        }
        func origin(_ index: Int, _ layout: ImageFold.Layout, _ unit: ImageUnit) -> (Int, Int) {
            switch unit {
            case .pixel, .tile:
                return (index % layout.columns * layout.spanWidth, index / layout.columns * layout.spanHeight)
            case .row:
                return (0, index * layout.spanHeight)
            case .column:
                return (index * layout.spanWidth, 0)
            }
        }
        func expectMap(
            _ name: String,
            first: [UInt8],
            second: [UInt8],
            width: Int,
            height: Int,
            unit: ImageUnit,
            tile: Int
        ) {
            let layout = ImageFold.layout(width: width, height: height, unit: unit, tile: tile)
            let units = layout.single ? 1 : layout.units
            let attempts = ["paper", "Hello", "Dragon_Curves", "bend", "scale"]
            do {
                var folded = false
                for passes in 1...3 {
                    for key in attempts {
                        let plan = try Curve.plan(key: key, passes: passes)
                        let map = try Curve.indexMap(count: units * 2, passes: plan, reverse: false)
                        if !crossed(map, units) { continue }
                        let mixed = try ImageFold.permutePair(
                            first: picture(first, width, height),
                            second: picture(second, width, height),
                            unit: unit,
                            tile: tile,
                            key: key,
                            passes: passes,
                            reverse: false
                        )
                        if !mixed.mark.pair || !mixed.mark.unitLine.contains("paired") {
                            failures.append("\(name) mark \(mixed.mark.unitLine)")
                        }
                        if !layout.single {
                            for dest in 0..<map.count {
                                let source = map[dest]
                                let srcPixels = source < units ? first : second
                                let srcIndex = source < units ? source : source - units
                                let dstPixels = dest < units ? mixed.first.pixels : mixed.second.pixels
                                let dstIndex = dest < units ? dest : dest - units
                                let from = origin(srcIndex, layout, unit)
                                let to = origin(dstIndex, layout, unit)
                                if quad(dstPixels, width, to.0, to.1) != quad(srcPixels, width, from.0, from.1) {
                                    failures.append("\(name) segment \(dest)")
                                    break
                                }
                            }
                            if !edgeMatches(mixed.first.pixels, first, width: width, height: height, layout: layout)
                                || !edgeMatches(mixed.second.pixels, second, width: width, height: height, layout: layout) {
                                failures.append("\(name) edge moved")
                            }
                        } else {
                            let sources = [first, second]
                            if mixed.first.pixels != sources[map[0]] || mixed.second.pixels != sources[map[1]] {
                                failures.append("\(name) whole picture")
                            }
                        }
                        let back = try ImageFold.restorePair(
                            first: mixed.first,
                            second: mixed.second,
                            mark: mixed.mark,
                            phrase: key
                        )
                        if back.0.pixels != first || back.1.pixels != second {
                            failures.append("\(name) restore")
                        }
                        let wrong = try ImageFold.restorePair(
                            first: mixed.first,
                            second: mixed.second,
                            mark: mixed.mark,
                            phrase: "nope"
                        )
                        if wrong.0.pixels == first && wrong.1.pixels == second {
                            failures.append("\(name) wrong phrase restored")
                        }
                        folded = true
                        break
                    }
                    if folded { break }
                }
                if !folded { failures.append("\(name) no crossing fold") }
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
            }
        }

        expectMap("tile", first: wash(8, 8, 0), second: wash(8, 8, 2), width: 8, height: 8, unit: .tile, tile: 4)
        expectMap("tile edge", first: wash(10, 6, 0), second: wash(10, 6, 2), width: 10, height: 6, unit: .tile, tile: 4)
        expectMap("rows", first: wash(8, 10, 0), second: wash(8, 10, 2), width: 8, height: 10, unit: .row, tile: 4)
        expectMap("columns", first: wash(10, 8, 0), second: wash(10, 8, 2), width: 10, height: 8, unit: .column, tile: 4)
        expectMap("pixels", first: wash(4, 3, 0), second: wash(4, 3, 2), width: 4, height: 3, unit: .pixel, tile: 1)
        expectMap("single", first: wash(6, 6, 0), second: wash(6, 6, 2), width: 6, height: 6, unit: .tile, tile: 8)

        do {
            let first = wash(6, 6, 0)
            let second = wash(6, 6, 2)
            let mixed = try ImageFold.permutePair(
                first: picture(first, 6, 6),
                second: picture(second, 6, 6),
                unit: .tile,
                tile: 8,
                key: "paper",
                passes: 1,
                spin: true,
                reverse: false
            )
            if mixed.mark.spin || !mixed.mark.pair { failures.append("a pair of small pictures spun") }
            let back = try ImageFold.restorePair(first: mixed.first, second: mixed.second, mark: mixed.mark, phrase: "paper")
            if back.0.pixels != first || back.1.pixels != second { failures.append("small pair spin restore") }
        } catch {
            failures.append("small pair spin: \(error.localizedDescription)")
        }

        do {
            let first = wash(8, 8, 0)
            let second = wash(8, 8, 2)
            let spun = try ImageFold.permutePair(
                first: picture(first, 8, 8),
                second: picture(second, 8, 8),
                unit: .tile,
                tile: 4,
                key: "paper",
                passes: 1,
                spin: true,
                reverse: false
            )
            let still = try ImageFold.permutePair(
                first: picture(first, 8, 8),
                second: picture(second, 8, 8),
                unit: .tile,
                tile: 4,
                key: "paper",
                passes: 1,
                reverse: false
            )
            if !spun.mark.spin || spun.mark.split || spun.first.pixels == still.first.pixels {
                failures.append("pair spin did not turn")
            }
            let back = try ImageFold.restorePair(first: spun.first, second: spun.second, mark: spun.mark, phrase: "paper")
            if back.0.pixels != first || back.1.pixels != second { failures.append("pair spin restore") }
            let stacked = try ImageFold.stack(top: spun.first, bottom: spun.second, mark: spun.mark)
            let note = PNGFile.notePayload(mark: spun.mark, width: stacked.width, height: stacked.height, pixels: stacked.pixels)
            if note.count != PNGFile.noteSize || note[0] != 4 || note[3] != 3 {
                failures.append("pair spin note \(note.first ?? 0) \(note.count > 3 ? note[3] : 0)")
            }
        } catch {
            failures.append("pair spin: \(error.localizedDescription)")
        }

        do {
            var first = wash(4, 3, 0)
            let second = wash(4, 3, 2)
            first[2 * 4 + 3] = 128
            let split = try ImageFold.permutePair(
                first: picture(first, 4, 3),
                second: picture(second, 4, 3),
                unit: .pixel,
                tile: 1,
                key: "paper",
                passes: 1,
                split: true,
                reverse: false
            )
            let together = try ImageFold.permutePair(
                first: picture(first, 4, 3),
                second: picture(second, 4, 3),
                unit: .pixel,
                tile: 1,
                key: "paper",
                passes: 1,
                reverse: false
            )
            if !split.mark.split || !split.mark.pair || split.first.pixels == together.first.pixels {
                failures.append("pair split matched one dragon")
            }
            if split.first.pixels[2 * 4 + 3] != 128 { failures.append("pair alpha moved") }
            let back = try ImageFold.restorePair(first: split.first, second: split.second, mark: split.mark, phrase: "paper")
            if back.0.pixels != first || back.1.pixels != second { failures.append("pair split restore") }
            let twice = try ImageFold.permutePair(
                first: picture(first, 4, 3),
                second: picture(second, 4, 3),
                unit: .pixel,
                tile: 1,
                key: "paper",
                passes: 2,
                split: true,
                reverse: false
            )
            let twiceBack = try ImageFold.restorePair(first: twice.first, second: twice.second, mark: twice.mark, phrase: "paper")
            if twiceBack.0.pixels != first || twiceBack.1.pixels != second { failures.append("pair split two-pass restore") }
            let stacked = try ImageFold.stack(top: split.first, bottom: split.second, mark: split.mark)
            let note = PNGFile.notePayload(mark: split.mark, width: stacked.width, height: stacked.height, pixels: stacked.pixels)
            if note[0] != 4 || note[3] != 5 { failures.append("pair split note") }
            let tileSplit = try ImageFold.permutePair(
                first: picture(wash(8, 8, 0), 8, 8),
                second: picture(wash(8, 8, 2), 8, 8),
                unit: .tile,
                tile: 4,
                key: "paper",
                passes: 1,
                split: true,
                reverse: false
            )
            if tileSplit.mark.split { failures.append("a paired tile fold split its colors") }
        } catch {
            failures.append("pair split: \(error.localizedDescription)")
        }

        do {
            let first = wash(8, 8, 0)
            let second = wash(8, 8, 2)
            let mixed = try ImageFold.permutePair(
                first: picture(first, 8, 8),
                second: picture(second, 8, 8),
                unit: .tile,
                tile: 4,
                key: "paper",
                passes: 1,
                reverse: false
            )
            let stacked = try ImageFold.stack(top: mixed.first, bottom: mixed.second, mark: mixed.mark)
            let data = try PNGFile.fileData(picture: stacked, includeNote: true)
            guard case .picture(let read, let width, let height, let payload) = PNGFile.decode(data) else {
                failures.append("pair PNG did not decode")
                return
            }
            if width != 8 || height != 16 || read != stacked.pixels { failures.append("pair PNG pixels") }
            if PNGFile.mark(from: payload ?? Data(), pixels: read, width: width, height: height).0 != mixed.mark {
                failures.append("pair PNG mark")
            }
            guard let halves = ImageFold.halves(Picture(pixels: read, width: width, height: height, name: "stack", reduced: false, mark: mixed.mark)) else {
                failures.append("pair PNG did not split")
                return
            }
            if halves.0.pixels != mixed.first.pixels || halves.1.pixels != mixed.second.pixels {
                failures.append("pair PNG halves")
            }
            let note = payload ?? Data()
            if note.count != PNGFile.noteSize || note[0] != 4 || note[3] != 1 {
                failures.append("pair note flags")
            }
            var unknown = note
            unknown[3] = 8
            if PNGFile.mark(from: unknown, pixels: read, width: width, height: height).0 != nil {
                failures.append("unknown pair flag accepted")
            }
            var newer = note
            newer[0] = 5
            let newerMark = PNGFile.mark(from: newer, pixels: read, width: width, height: height)
            if newerMark.0 != nil || newerMark.1?.contains("newer") != true {
                failures.append("pair version 5 \(newerMark.1 ?? "")")
            }
            let odd = wash(3, 3, 0)
            let oddMark = FoldMark(unit: .pixel, tile: 1, passes: 1, keyed: true, pair: true)
            let oddNote = PNGFile.notePayload(mark: oddMark, width: 3, height: 3, pixels: odd)
            if PNGFile.mark(from: oddNote, pixels: odd, width: 3, height: 3).0 != nil {
                failures.append("odd pair note accepted")
            }
        } catch {
            failures.append("pair png: \(error.localizedDescription)")
        }

        do {
            var small = [UInt8](repeating: 255, count: 2 * 2 * 4)
            small[0] = 255
            small[1] = 0
            small[2] = 0
            small[4] = 255
            small[5] = 0
            small[6] = 0
            small[8] = 0
            small[9] = 0
            small[10] = 255
            small[12] = 0
            small[13] = 0
            small[14] = 255
            let fitted = try ImageFold.fit(picture(small, 2, 2), width: 4, height: 4)
            let top = quad(fitted.pixels, 4, 0, 0)
            let bottom = quad(fitted.pixels, 4, 0, 3)
            if fitted.width != 4 || fitted.height != 4 || !fitted.reduced || !(top.0 > top.2 && bottom.2 > bottom.0) {
                failures.append("fit \(fitted.width)x\(fitted.height) top=\(top) bottom=\(bottom)")
            }
            let same = try ImageFold.fit(picture(small, 2, 2), width: 2, height: 2)
            if same.pixels != small || same.reduced { failures.append("same-size fit changed bytes") }
        } catch {
            failures.append("fit: \(error.localizedDescription)")
        }

        let folder = FileManager.default.temporaryDirectory
        let out = folder.appendingPathComponent("dragonscale-pair-\(UUID().uuidString).png")
        let back = folder.appendingPathComponent("dragonscale-pair-back-\(UUID().uuidString).png")
        defer {
            try? FileManager.default.removeItem(at: out)
            try? FileManager.default.removeItem(at: back)
        }
        do {
            _ = try CLI.perform(["Dragonscale", "--input", "missing.png", "--pair", "--out", out.path])
            failures.append("pair without mate was accepted")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            if !message.contains("mate") {
                failures.append("pair without mate: \(message)")
            }
        }
        do {
            let wrote = try CLI.perform([
                "Dragonscale", "--card", "--pair", "--key", "paper", "--passes", "1", "--tile", "32",
                "--out", out.path,
            ])
            if !wrote.contains("paired") { failures.append("cli pair line \(wrote)") }
            let loaded = try PictureLoader.load(url: out)
            if loaded.picture.mark?.pair != true || loaded.picture.width != Card.width || loaded.picture.height != Card.height * 2 {
                failures.append("cli pair file \(loaded.picture.width)x\(loaded.picture.height) \(String(describing: loaded.picture.mark))")
            }
            var unmixed = day.pixels
            unmixed.append(contentsOf: night.pixels)
            if loaded.picture.pixels == unmixed { failures.append("cli pair did not move") }
            _ = try CLI.perform([
                "Dragonscale", "--restore", "--input", out.path, "--key", "paper", "--out", back.path,
            ])
            let restored = try PictureLoader.load(url: back)
            if restored.picture.mark != nil || restored.picture.height != Card.height * 2 {
                failures.append("cli pair restore kept a note")
            }
            guard let halves = ImageFold.halves(restored.picture) else {
                failures.append("cli pair restore did not split")
                return
            }
            if halves.0.pixels != day.pixels || halves.1.pixels != night.pixels {
                failures.append("cli pair restore pixels")
            }
        } catch {
            failures.append("cli pair: \(error.localizedDescription)")
        }
    }
}
