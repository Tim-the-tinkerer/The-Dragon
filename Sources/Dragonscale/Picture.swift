import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageUnit: Int, CaseIterable, Identifiable {
    case pixel = 1
    case tile = 2
    case row = 3
    case column = 4

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .pixel: return "Pixel"
        case .tile: return "Tile"
        case .row: return "Rows"
        case .column: return "Columns"
        }
    }

    var detail: String {
        switch self {
        case .pixel:
            return "Each pixel is its own segment. The picture breaks into static."
        case .tile:
            return "A square scrap of the picture moves together."
        case .row:
            return "A horizontal ribbon, the full width of the picture, moves together."
        case .column:
            return "A vertical ribbon, the full height of the picture, moves together."
        }
    }

    func sizeLine(_ thickness: Int) -> String {
        switch self {
        case .pixel:
            return ""
        case .tile:
            return "\(thickness) pixels on a side. The edge that does not fill a tile stays put."
        case .row:
            return "\(thickness) pixels tall, across the whole width. The bottom that does not fill a strip stays put."
        case .column:
            return "\(thickness) pixels wide, down the whole height. The right edge that does not fill a strip stays put."
        }
    }
}

struct FoldMark: Equatable {
    var unit: ImageUnit
    var tile: Int
    var passes: Int
    var keyed: Bool

    var unitLine: String {
        let base: String
        switch unit {
        case .pixel: base = split ? "pixel, each channel" : "pixel"
        case .tile: base = "tile \(tile)"
        case .row: base = "rows \(tile)"
        case .column: base = "columns \(tile)"
        }
        return pair ? base + ", paired" : base
    }

    /// True when this fold turned each square with the pen.
    var spin: Bool = false
    /// Pixel mode. Red walks the phrase, blue the mirror, green the plain curve.
    var split: Bool = false
    /// Two pictures shared one dragon. The file is the first stacked on the second.
    var pair: Bool = false
}

struct Picture: Equatable {
    var pixels: [UInt8]
    var width: Int
    var height: Int
    var name: String
    var reduced: Bool
    var mark: FoldMark?

    func pixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let index = (y * width + x) * 4
        return (pixels[index], pixels[index + 1], pixels[index + 2], pixels[index + 3])
    }
}

enum ImageFold {
    static let tiles = [4, 8, 16, 32, 64, 128]

    /// How the picture sits on the curve.
    /// A remainder that does not fill a segment stays where it is,
    /// so every segment is the same size and the fold can be undone.
    struct Layout {
        var columns: Int
        var rows: Int
        var side: Int
        var units: Int
        var single: Bool
        var edgeRight: Int
        var edgeBottom: Int
        /// Width and height of one segment, in pixels.
        var spanWidth: Int
        var spanHeight: Int
    }

    static func tileSide(unit: ImageUnit, tile: Int) -> Int {
        switch unit {
        case .pixel: return 1
        case .tile, .row, .column: return min(AppInfo.maxTile, max(1, tile))
        }
    }

    static func layout(width: Int, height: Int, unit: ImageUnit, tile: Int) -> Layout {
        guard width > 0, height > 0 else {
            return Layout(columns: 0, rows: 0, side: 1, units: 0, single: true, edgeRight: 0, edgeBottom: 0, spanWidth: 1, spanHeight: 1)
        }
        switch unit {
        case .pixel:
            return Layout(columns: width, rows: height, side: 1, units: width * height, single: false, edgeRight: 0, edgeBottom: 0, spanWidth: 1, spanHeight: 1)
        case .tile:
            let side = tileSide(unit: unit, tile: tile)
            if width < side || height < side {
                return Layout(columns: 1, rows: 1, side: side, units: 1, single: true, edgeRight: 0, edgeBottom: 0, spanWidth: side, spanHeight: side)
            }
            let columns = width / side
            let rows = height / side
            return Layout(
                columns: columns,
                rows: rows,
                side: side,
                units: columns * rows,
                single: false,
                edgeRight: width % side,
                edgeBottom: height % side,
                spanWidth: side,
                spanHeight: side
            )
        case .row:
            let side = tileSide(unit: unit, tile: tile)
            if height < side {
                return Layout(columns: 1, rows: 1, side: side, units: 1, single: true, edgeRight: 0, edgeBottom: 0, spanWidth: width, spanHeight: side)
            }
            let rows = height / side
            return Layout(
                columns: 1,
                rows: rows,
                side: side,
                units: rows,
                single: false,
                edgeRight: 0,
                edgeBottom: height % side,
                spanWidth: width,
                spanHeight: side
            )
        case .column:
            let side = tileSide(unit: unit, tile: tile)
            if width < side {
                return Layout(columns: 1, rows: 1, side: side, units: 1, single: true, edgeRight: 0, edgeBottom: 0, spanWidth: side, spanHeight: height)
            }
            let columns = width / side
            return Layout(
                columns: columns,
                rows: 1,
                side: side,
                units: columns,
                single: false,
                edgeRight: width % side,
                edgeBottom: 0,
                spanWidth: side,
                spanHeight: height
            )
        }
    }

    static func limitMessage(width: Int, height: Int, unit: ImageUnit, tile: Int) -> String? {
        let count = layout(width: width, height: height, unit: unit, tile: tile).units
        guard count > AppInfo.maxUnits else { return nil }
        let side = tileSide(unit: unit, tile: tile)
        switch unit {
        case .pixel:
            return "Pixel mode lays one pixel on each segment. This picture has \(count) pixels, and the curve stops at \(AppInfo.maxUnits). Choose Tile."
        case .tile:
            return "Tile \(side) still makes \(count) segments. The curve stops at \(AppInfo.maxUnits). Choose a larger tile."
        case .row:
            return "Rows of \(side) still make \(count) segments. The curve stops at \(AppInfo.maxUnits). Choose a thicker strip."
        case .column:
            return "Columns of \(side) still make \(count) segments. The curve stops at \(AppInfo.maxUnits). Choose a thicker strip."
        }
    }

    /// Segments of the first picture, then the second. A single picture counts as one segment.
    static func pairUnits(width: Int, height: Int, unit: ImageUnit, tile: Int) -> Int {
        let placed = layout(width: width, height: height, unit: unit, tile: tile)
        if placed.units == 0 { return 0 }
        return placed.single ? 2 : placed.units * 2
    }

    static func pairLimit(width: Int, height: Int, unit: ImageUnit, tile: Int) -> String? {
        let count = pairUnits(width: width, height: height, unit: unit, tile: tile)
        guard count > AppInfo.maxUnits else { return nil }
        let noun = unit == .pixel ? "pixels" : "segments"
        return "The two pictures together have \(count) \(noun), and the curve stops at \(AppInfo.maxUnits). Choose a larger tile or a thicker strip."
    }

    /// Spin is only a square tile larger than one pixel. A ribbon or a pixel has nothing to turn.
    static func turnsTiles(_ requested: Bool, unit: ImageUnit, layout: Layout) -> Bool {
        requested && unit == .tile && layout.side > 1 && !layout.single && layout.units > 0
    }

    /// Channel split is pixel mode. A tile keeps its colors together.
    static func splitsChannels(_ requested: Bool, unit: ImageUnit) -> Bool {
        requested && unit == .pixel
    }

    static func permute(
        pixels: [UInt8],
        width: Int,
        height: Int,
        unit: ImageUnit,
        tile: Int,
        key: String,
        passes: Int?,
        spin: Bool = false,
        split: Bool = false,
        reverse: Bool,
        onPass: ((Int, Int) -> Void)? = nil
    ) throws -> (pixels: [UInt8], mark: FoldMark) {
        guard width > 0, height > 0, pixels.count == width * height * 4 else {
            throw FoldError(message: "That picture has no pixels.")
        }
        if let limit = limitMessage(width: width, height: height, unit: unit, tile: tile) {
            throw FoldError(message: limit)
        }
        let plan = try Curve.plan(key: key, passes: passes)
        let placed = layout(width: width, height: height, unit: unit, tile: tile)
        let turned = turnsTiles(spin, unit: unit, layout: placed)
        let splitColors = splitsChannels(split, unit: unit)
        let folded: [UInt8]
        if turned {
            folded = try spinAlong(
                pixels: pixels,
                width: width,
                layout: placed,
                passes: plan,
                reverse: reverse,
                onPass: onPass
            )
        } else if splitColors {
            folded = try splitChannels(
                pixels: pixels,
                count: placed.units,
                passes: plan,
                reverse: reverse,
                onPass: onPass
            )
        } else {
            let map = try Curve.indexMap(count: placed.units, passes: plan, reverse: reverse, onPass: onPass)
            folded = gather(pixels: pixels, width: width, height: height, layout: placed, map: map)
        }
        let mark = FoldMark(
            unit: unit,
            tile: tileSide(unit: unit, tile: tile),
            passes: plan.count,
            keyed: !key.isEmpty,
            spin: turned,
            split: splitColors
        )
        return (folded, mark)
    }

    static func restore(
        pixels: [UInt8],
        width: Int,
        height: Int,
        mark: FoldMark,
        phrase: String,
        onPass: ((Int, Int) -> Void)? = nil
    ) throws -> [UInt8] {
        if mark.keyed != !phrase.isEmpty {
            throw FoldError(message: mark.keyed
                ? "This fold used a phrase."
                : "This fold used no phrase. Clear the phrase and restore again.")
        }
        let result = try permute(
            pixels: pixels,
            width: width,
            height: height,
            unit: mark.unit,
            tile: mark.tile,
            key: phrase,
            passes: mark.passes,
            spin: mark.spin,
            split: mark.split,
            reverse: true,
            onPass: onPass
        )
        return result.pixels
    }

    /// The two pictures share one dragon.
    /// Covered segments of the first come first, then the second.
    /// Pixels, rows, and tiles stack those segments. Columns place them side by side.
    /// A leftover edge is not a segment, so it stays in its own picture.
    static func permutePair(
        first: Picture,
        second: Picture,
        unit: ImageUnit,
        tile: Int,
        key: String,
        passes: Int?,
        spin: Bool = false,
        split: Bool = false,
        reverse: Bool,
        onPass: ((Int, Int) -> Void)? = nil
    ) throws -> (first: Picture, second: Picture, mark: FoldMark) {
        guard first.width == second.width, first.height == second.height, first.width > 0, first.height > 0,
              first.pixels.count == first.width * first.height * 4,
              second.pixels.count == second.width * second.height * 4
        else {
            throw FoldError(message: "The two pictures need the same width and height.")
        }
        if let limit = pairLimit(width: first.width, height: first.height, unit: unit, tile: tile) {
            throw FoldError(message: limit)
        }
        let plan = try Curve.plan(key: key, passes: passes)
        let placed = layout(width: first.width, height: first.height, unit: unit, tile: tile)
        if placed.single {
            let map = try Curve.indexMap(count: 2, passes: plan, reverse: reverse, onPass: onPass)
            let sources = [first.pixels, second.pixels]
            let mark = FoldMark(
                unit: unit,
                tile: tileSide(unit: unit, tile: tile),
                passes: plan.count,
                keyed: !key.isEmpty,
                spin: false,
                split: false,
                pair: true
            )
            var leading = first
            var trailing = second
            leading.pixels = sources[map[0]]
            trailing.pixels = sources[map[1]]
            leading.mark = mark
            trailing.mark = mark
            return (leading, trailing, mark)
        }
        let packed = packPair(
            first: first.pixels,
            second: second.pixels,
            width: first.width,
            height: first.height,
            layout: placed,
            unit: unit
        )
        let folded = try permute(
            pixels: packed.pixels,
            width: packed.width,
            height: packed.height,
            unit: unit,
            tile: tile,
            key: key,
            passes: passes,
            spin: spin,
            split: split,
            reverse: reverse,
            onPass: onPass
        )
        let parts = unpackPair(
            folded: folded.pixels,
            first: first.pixels,
            second: second.pixels,
            width: first.width,
            height: first.height,
            packedWidth: packed.width,
            layout: placed,
            unit: unit
        )
        var mark = folded.mark
        mark.pair = true
        var leading = first
        var trailing = second
        leading.pixels = parts.0
        trailing.pixels = parts.1
        leading.mark = mark
        trailing.mark = mark
        return (leading, trailing, mark)
    }

    static func restorePair(
        first: Picture,
        second: Picture,
        mark: FoldMark,
        phrase: String,
        onPass: ((Int, Int) -> Void)? = nil
    ) throws -> (Picture, Picture) {
        if !mark.pair {
            throw FoldError(message: "This fold is one picture.")
        }
        if mark.keyed != !phrase.isEmpty {
            throw FoldError(message: mark.keyed
                ? "This fold used a phrase."
                : "This fold used no phrase. Clear the phrase and restore again.")
        }
        let mixed = try permutePair(
            first: first,
            second: second,
            unit: mark.unit,
            tile: mark.tile,
            key: phrase,
            passes: mark.passes,
            spin: mark.spin,
            split: mark.split,
            reverse: true,
            onPass: onPass
        )
        var leading = mixed.first
        var trailing = mixed.second
        leading.mark = nil
        trailing.mark = nil
        return (leading, trailing)
    }

    /// The export is one PNG: the first picture on top, the second below, edges included.
    static func stack(top: Picture, bottom: Picture, mark: FoldMark?) throws -> Picture {
        guard top.width == bottom.width, top.height == bottom.height, top.width > 0, top.height > 0,
              top.pixels.count == top.width * top.height * 4,
              bottom.pixels.count == bottom.width * bottom.height * 4
        else {
            throw FoldError(message: "The two pictures need the same width and height.")
        }
        var pixels = top.pixels
        pixels.append(contentsOf: bottom.pixels)
        return Picture(
            pixels: pixels,
            width: top.width,
            height: top.height + bottom.height,
            name: top.name,
            reduced: top.reduced || bottom.reduced,
            mark: mark
        )
    }

    /// Split a stacked file at half the height. The caller decides whether it was a pair.
    static func halves(_ picture: Picture) -> (Picture, Picture)? {
        guard picture.width > 0, picture.height >= 2, picture.height % 2 == 0 else { return nil }
        let half = picture.height / 2
        let bytes = picture.width * half * 4
        guard picture.pixels.count == bytes * 2 else { return nil }
        var top = picture
        top.pixels = Array(picture.pixels[0..<bytes])
        top.height = half
        var bottom = picture
        bottom.pixels = Array(picture.pixels[bytes..<bytes * 2])
        bottom.height = half
        bottom.name = "Second"
        return (top, bottom)
    }

    /// Draw the second picture into the first picture's exact size. Same size copies the bytes.
    static func fit(_ picture: Picture, width: Int, height: Int) throws -> Picture {
        guard width > 0, height > 0 else {
            throw FoldError(message: "That picture has no pixels.")
        }
        if picture.width == width && picture.height == height {
            var same = picture
            same.mark = nil
            return same
        }
        guard let image = PictureImage.cgImage(picture),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else {
            throw FoldError(message: "Could not fit the second picture.")
        }
        var raw = [UInt8](repeating: 0, count: width * height * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let drawn = raw.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: info
            ) else { return false }
            ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        guard drawn else { throw FoldError(message: "Could not fit the second picture.") }
        var straight = [UInt8](repeating: 0, count: raw.count)
        var index = 0
        while index < raw.count {
            let red = raw[index]
            let green = raw[index + 1]
            let blue = raw[index + 2]
            let alpha = raw[index + 3]
            if alpha == 0 {
                straight[index] = 0
                straight[index + 1] = 0
                straight[index + 2] = 0
                straight[index + 3] = 0
            } else if alpha == 255 {
                straight[index] = red
                straight[index + 1] = green
                straight[index + 2] = blue
                straight[index + 3] = alpha
            } else {
                let scale = Int(alpha)
                straight[index] = UInt8(min(255, Int(red) * 255 / scale))
                straight[index + 1] = UInt8(min(255, Int(green) * 255 / scale))
                straight[index + 2] = UInt8(min(255, Int(blue) * 255 / scale))
                straight[index + 3] = alpha
            }
            index += 4
        }
        return Picture(pixels: straight, width: width, height: height, name: picture.name, reduced: true, mark: nil)
    }

    private struct Packed {
        var pixels: [UInt8]
        var width: Int
        var height: Int
    }

    /// Columns are full-height ribbons, so the two pictures sit side by side.
    /// Everything else stacks the covered rows. The leftover edge is left out.
    private static func packPair(
        first: [UInt8],
        second: [UInt8],
        width: Int,
        height: Int,
        layout: Layout,
        unit: ImageUnit
    ) -> Packed {
        if unit == .column {
            let covered = layout.columns * layout.spanWidth
            let packedWidth = covered * 2
            var pixels = [UInt8](repeating: 0, count: packedWidth * height * 4)
            blitRows(from: first, srcWidth: width, srcX: 0, to: &pixels, dstWidth: packedWidth, dstX: 0, span: covered, height: height)
            blitRows(from: second, srcWidth: width, srcX: 0, to: &pixels, dstWidth: packedWidth, dstX: covered, span: covered, height: height)
            return Packed(pixels: pixels, width: packedWidth, height: height)
        }
        let bandRows = layout.rows * layout.spanHeight
        let bytes = bandRows * width * 4
        var pixels: [UInt8] = []
        pixels.reserveCapacity(bytes * 2)
        pixels.append(contentsOf: first.prefix(bytes))
        pixels.append(contentsOf: second.prefix(bytes))
        return Packed(pixels: pixels, width: width, height: bandRows * 2)
    }

    private static func unpackPair(
        folded: [UInt8],
        first: [UInt8],
        second: [UInt8],
        width: Int,
        height: Int,
        packedWidth: Int,
        layout: Layout,
        unit: ImageUnit
    ) -> ([UInt8], [UInt8]) {
        var leading = first
        var trailing = second
        if unit == .column {
            let covered = layout.columns * layout.spanWidth
            blitRows(from: folded, srcWidth: packedWidth, srcX: 0, to: &leading, dstWidth: width, dstX: 0, span: covered, height: height)
            blitRows(from: folded, srcWidth: packedWidth, srcX: covered, to: &trailing, dstWidth: width, dstX: 0, span: covered, height: height)
            return (leading, trailing)
        }
        let bandRows = layout.rows * layout.spanHeight
        let bytes = bandRows * width * 4
        leading.replaceSubrange(0..<bytes, with: folded.prefix(bytes))
        trailing.replaceSubrange(0..<bytes, with: folded.dropFirst(bytes).prefix(bytes))
        return (leading, trailing)
    }

    private static func blitRows(
        from src: [UInt8],
        srcWidth: Int,
        srcX: Int,
        to dst: inout [UInt8],
        dstWidth: Int,
        dstX: Int,
        span: Int,
        height: Int
    ) {
        guard span > 0, height > 0 else { return }
        let bytes = span * 4
        src.withUnsafeBytes { srcRaw in
            dst.withUnsafeMutableBytes { dstRaw in
                guard let source = srcRaw.baseAddress, let dest = dstRaw.baseAddress else { return }
                for row in 0..<height {
                    let from = (row * srcWidth + srcX) * 4
                    let into = (row * dstWidth + dstX) * 4
                    dest.advanced(by: into).copyMemory(from: source.advanced(by: from), byteCount: bytes)
                }
            }
        }
    }

    /// Red follows the phrase. Blue follows the same passes with the fold turned over.
    /// Green follows that many passes of the plain curve. Alpha stays on its pixel.
    private static func splitChannels(
        pixels: [UInt8],
        count: Int,
        passes: [Curve.Pass],
        reverse: Bool,
        onPass: ((Int, Int) -> Void)?
    ) throws -> [UInt8] {
        let steps = passes.count * 3
        let red = try Curve.indexMap(count: count, passes: passes, reverse: reverse) { pass, _ in
            onPass?(pass, steps)
        }
        let mirrored = passes.map {
            Curve.Pass(fold: -$0.fold, heading: $0.heading, skip: $0.skip, view: $0.view)
        }
        let blue = try Curve.indexMap(count: count, passes: mirrored, reverse: reverse) { pass, _ in
            onPass?(passes.count + pass, steps)
        }
        let plain = try Curve.plan(key: "", passes: passes.count)
        let green = try Curve.indexMap(count: count, passes: plain, reverse: reverse) { pass, _ in
            onPass?(passes.count * 2 + pass, steps)
        }
        var out = [UInt8](repeating: 0, count: pixels.count)
        pixels.withUnsafeBytes { srcRaw in
            out.withUnsafeMutableBytes { dstRaw in
                guard let src = srcRaw.baseAddress, let dst = dstRaw.baseAddress else { return }
                for index in 0..<count {
                    let at = index * 4
                    dst.advanced(by: at).copyMemory(from: src.advanced(by: red[index] * 4), byteCount: 1)
                    dst.advanced(by: at + 1).copyMemory(from: src.advanced(by: green[index] * 4 + 1), byteCount: 1)
                    dst.advanced(by: at + 2).copyMemory(from: src.advanced(by: blue[index] * 4 + 2), byteCount: 1)
                    dst.advanced(by: at + 3).copyMemory(from: src.advanced(by: at + 3), byteCount: 1)
                }
            }
        }
        return out
    }

    /// Each pass moves the squares, then turns a square by the heading of the step it came from.
    /// East is 0°. North is 90° clockwise. West is 180°. South is 270°. Rows run downward.
    /// Reverse turns the other way, then undoes that pass.
    private static func spinAlong(
        pixels: [UInt8],
        width: Int,
        layout: Layout,
        passes: [Curve.Pass],
        reverse: Bool,
        onPass: ((Int, Int) -> Void)?
    ) throws -> [UInt8] {
        let sequence = reverse ? Array(passes.reversed()) : passes
        var current = pixels
        for (offset, pass) in sequence.enumerated() {
            onPass?(offset + 1, sequence.count)
            let order = try Curve.segmentOrder(count: layout.units, pass: pass)
            let faces = try Curve.headings(count: layout.units, pass: pass)
            current = turnTiles(
                pixels: current,
                width: width,
                layout: layout,
                order: order,
                headings: faces,
                reverse: reverse
            )
        }
        return current
    }

    private static func turnTiles(
        pixels: [UInt8],
        width: Int,
        layout: Layout,
        order: [Int],
        headings: [Int],
        reverse: Bool
    ) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: pixels.count)
        let side = layout.side
        let columns = layout.columns
        let rowBytes = width * 4
        pixels.withUnsafeBytes { srcRaw in
            out.withUnsafeMutableBytes { dstRaw in
                guard let src = srcRaw.baseAddress, let dst = dstRaw.baseAddress else { return }
                dst.copyMemory(from: src, byteCount: pixels.count)
                for rank in 0..<order.count {
                    let segment = order[rank]
                    let quarter = headings[segment] & 3
                    let fromIndex = reverse ? rank : segment
                    let toIndex = reverse ? segment : rank
                    let turns = reverse ? (4 - quarter) & 3 : quarter
                    blitTile(
                        src: src,
                        dst: dst,
                        from: fromIndex,
                        to: toIndex,
                        quarter: turns,
                        side: side,
                        columns: columns,
                        rowBytes: rowBytes
                    )
                }
            }
        }
        return out
    }

    /// Clockwise `quarter` turns. The source pixel for a destination is the inverse of that turn.
    private static func blitTile(
        src: UnsafeRawPointer,
        dst: UnsafeMutableRawPointer,
        from: Int,
        to: Int,
        quarter: Int,
        side: Int,
        columns: Int,
        rowBytes: Int
    ) {
        let sx0 = (from % columns) * side
        let sy0 = (from / columns) * side
        let dx0 = (to % columns) * side
        let dy0 = (to / columns) * side
        if quarter == 0 {
            let bytes = side * 4
            for row in 0..<side {
                let fromByte = (sy0 + row) * rowBytes + sx0 * 4
                let toByte = (dy0 + row) * rowBytes + dx0 * 4
                dst.advanced(by: toByte).copyMemory(from: src.advanced(by: fromByte), byteCount: bytes)
            }
            return
        }
        for y in 0..<side {
            for x in 0..<side {
                let sx: Int
                let sy: Int
                switch quarter {
                case 1:
                    sx = y
                    sy = side - 1 - x
                case 2:
                    sx = side - 1 - x
                    sy = side - 1 - y
                default:
                    sx = side - 1 - y
                    sy = x
                }
                let fromByte = (sy0 + sy) * rowBytes + (sx0 + sx) * 4
                let toByte = (dy0 + y) * rowBytes + (dx0 + x) * 4
                dst.advanced(by: toByte).copyMemory(from: src.advanced(by: fromByte), byteCount: 4)
            }
        }
    }

    private static func gather(
        pixels: [UInt8],
        width: Int,
        height: Int,
        layout: Layout,
        map: [Int]
    ) -> [UInt8] {
        if layout.single || map.isEmpty { return pixels }
        var out = [UInt8](repeating: 0, count: pixels.count)
        let columns = layout.columns
        let rowBytes = width * 4
        pixels.withUnsafeBytes { srcRaw in
            out.withUnsafeMutableBytes { dstRaw in
                guard let src = srcRaw.baseAddress, let dst = dstRaw.baseAddress else { return }
                dst.copyMemory(from: src, byteCount: pixels.count)
                let spanWidth = layout.spanWidth
                let spanHeight = layout.spanHeight
                if spanWidth == 1 && spanHeight == 1 {
                    for dest in 0..<map.count {
                        let from = map[dest] * 4
                        let to = dest * 4
                        dst.advanced(by: to).copyMemory(from: src.advanced(by: from), byteCount: 4)
                    }
                    return
                }
                // A full-width ribbon is one contiguous band of rows.
                if spanWidth == width {
                    let band = spanHeight * rowBytes
                    for dest in 0..<map.count {
                        let from = map[dest] * band
                        let to = dest * band
                        dst.advanced(by: to).copyMemory(from: src.advanced(by: from), byteCount: band)
                    }
                    return
                }
                let spanBytes = spanWidth * 4
                for dest in 0..<map.count {
                    let source = map[dest]
                    let sCol = source % columns
                    let sRow = source / columns
                    let dCol = dest % columns
                    let dRow = dest / columns
                    let sx = sCol * spanWidth
                    let sy = sRow * spanHeight
                    let dx = dCol * spanWidth
                    let dy = dRow * spanHeight
                    for row in 0..<spanHeight {
                        let from = (sy + row) * rowBytes + sx * 4
                        let to = (dy + row) * rowBytes + dx * 4
                        dst.advanced(by: to).copyMemory(from: src.advanced(by: from), byteCount: spanBytes)
                    }
                }
            }
        }
        return out
    }
}

enum Card {
    static let width = 480
    static let height = 320
    static let brass = (r: UInt8(219), g: UInt8(173), b: UInt8(92))
    static let cream = (r: UInt8(242), g: UInt8(232), b: UInt8(210))

    /// A small picture so Fold works before a file is opened.
    static func make() -> Picture {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
            let left = max(0, x0)
            let right = min(width, x1)
            let top = max(0, y0)
            let bottom = min(height, y1)
            guard left < right, top < bottom else { return }
            for y in top..<bottom {
                var index = (y * width + left) * 4
                for _ in left..<right {
                    pixels[index] = r
                    pixels[index + 1] = g
                    pixels[index + 2] = b
                    pixels[index + 3] = 255
                    index += 4
                }
            }
        }
        for y in 0..<210 {
            let r = UInt8(28 + y / 3)
            let g = UInt8(52 + y / 2)
            let b = UInt8(min(255, 92 + y / 5))
            fill(0, y, width, y + 1, r, g, b)
        }
        fill(0, 210, width, height, 34, 52, 32)

        let sunX = 370
        let sunY = 68
        let radius = 36
        for y in (sunY - radius)..<(sunY + radius) {
            for x in (sunX - radius)..<(sunX + radius) {
                let dx = x - sunX
                let dy = y - sunY
                if dx * dx + dy * dy <= radius * radius {
                    fill(x, y, x + 1, y + 1, brass.r, brass.g, brass.b)
                }
            }
        }
        for y in 108..<156 {
            let reach = (y - 108) * 80 / 48
            fill(140 - reach, y, 140 + reach + 1, y + 1, 176, 118, 52)
        }
        fill(78, 156, 202, 268, cream.r, cream.g, cream.b)
        fill(124, 208, 152, 268, 42, 32, 28)
        fill(90, 174, 112, 196, 176, 64, 48)
        fill(158, 174, 180, 196, 64, 120, 96)
        fill(90, 208, 112, 230, 48, 78, 140)
        fill(158, 208, 180, 230, brass.r, brass.g, brass.b)

        return Picture(pixels: pixels, width: width, height: height, name: "Card", reduced: false, mark: nil)
    }

    /// The same house after dark. The day card's sun stays brass; this moon does not.
    static func mate() -> Picture {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
            let left = max(0, x0)
            let right = min(width, x1)
            let top = max(0, y0)
            let bottom = min(height, y1)
            guard left < right, top < bottom else { return }
            for y in top..<bottom {
                var index = (y * width + left) * 4
                for _ in left..<right {
                    pixels[index] = r
                    pixels[index + 1] = g
                    pixels[index + 2] = b
                    pixels[index + 3] = 255
                    index += 4
                }
            }
        }
        for y in 0..<210 {
            let r = UInt8(6 + y / 18)
            let g = UInt8(8 + y / 14)
            let b = UInt8(20 + y / 6)
            fill(0, y, width, y + 1, r, g, b)
        }
        fill(0, 210, width, height, 18, 28, 22)

        let moon = (r: UInt8(236), g: UInt8(232), b: UInt8(214))
        let moonX = 370
        let moonY = 68
        let radius = 36
        for y in (moonY - radius)..<(moonY + radius) {
            for x in (moonX - radius)..<(moonX + radius) {
                let dx = x - moonX
                let dy = y - moonY
                if dx * dx + dy * dy <= radius * radius {
                    fill(x, y, x + 1, y + 1, moon.r, moon.g, moon.b)
                }
            }
        }
        for y in 108..<156 {
            let reach = (y - 108) * 80 / 48
            fill(140 - reach, y, 140 + reach + 1, y + 1, 176, 118, 52)
        }
        fill(78, 156, 202, 268, cream.r, cream.g, cream.b)
        fill(124, 208, 152, 268, 42, 32, 28)
        fill(90, 174, 112, 196, 176, 64, 48)
        fill(158, 174, 180, 196, 64, 120, 96)
        fill(90, 208, 112, 230, 48, 78, 140)
        fill(158, 208, 180, 230, brass.r, brass.g, brass.b)

        return Picture(pixels: pixels, width: width, height: height, name: "Night", reduced: false, mark: nil)
    }
}

enum PictureImage {
    static func nsImage(_ picture: Picture) -> NSImage? {
        guard let cg = cgImage(picture) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: picture.width, height: picture.height))
        image.isTemplate = false
        return image
    }

    static func cgImage(_ picture: Picture) -> CGImage? {
        guard picture.width > 0, picture.height > 0, picture.pixels.count == picture.width * picture.height * 4 else {
            return nil
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let data = Data(picture.pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.last.rawValue)
        return CGImage(
            width: picture.width,
            height: picture.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: picture.width * 4,
            space: space,
            bitmapInfo: info,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

enum PictureLoader {
    static func load(url: URL) throws -> (picture: Picture, warning: String?) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values.isDirectory == true {
            throw FoldError(message: "Could not read that image.")
        }
        if let size = values.fileSize, size > AppInfo.maxFileBytes {
            throw FoldError(message: "That file is larger than 512 MB.")
        }
        let header = try readHeader(url)
        if header == PNGFile.signature {
            let data = try Data(contentsOf: url)
            switch PNGFile.decode(data) {
            case .picture(let pixels, let width, let height, let note):
                if height > AppInfo.maxSide && width <= AppInfo.maxSide && height <= AppInfo.maxSide * 2 {
                    let parsed = note.flatMap { PNGFile.mark(from: $0, pixels: pixels, width: width, height: height).0 }
                    if parsed?.pair == true {
                        return accept(
                            pixels: pixels,
                            width: width,
                            height: height,
                            name: url.lastPathComponent,
                            note: note,
                            reduced: false,
                            noteDropped: nil
                        )
                    }
                    let fitted = try image(data: data, name: url.lastPathComponent, fit: true)
                    let dropped = note != nil ? "The fold note does not apply to the smaller copy." : nil
                    return (fitted, dropped)
                }
                return accept(
                    pixels: pixels,
                    width: width,
                    height: height,
                    name: url.lastPathComponent,
                    note: note,
                    reduced: false,
                    noteDropped: nil
                )
            case .tooBig(let hasNote):
                let fitted = try image(url: url, name: url.lastPathComponent, fit: true)
                let dropped = hasNote ? "The fold note does not apply to the smaller copy." : nil
                return (fitted, dropped)
            case .unsupported(let note):
                let dataPicture = try image(data: data, name: url.lastPathComponent, fit: false)
                return accept(
                    pixels: dataPicture.pixels,
                    width: dataPicture.width,
                    height: dataPicture.height,
                    name: dataPicture.name,
                    note: dataPicture.reduced ? nil : note,
                    reduced: dataPicture.reduced,
                    noteDropped: dataPicture.reduced && note != nil
                        ? "The fold note does not apply to the smaller copy."
                        : nil
                )
            }
        }
        let picture = try image(url: url, name: url.lastPathComponent, fit: false)
        return (picture, nil)
    }

    private static func accept(
        pixels: [UInt8],
        width: Int,
        height: Int,
        name: String,
        note: Data?,
        reduced: Bool,
        noteDropped: String?
    ) -> (picture: Picture, warning: String?) {
        var mark: FoldMark?
        var warning = noteDropped
        if let note, !reduced {
            let parsed = PNGFile.mark(from: note, pixels: pixels, width: width, height: height)
            mark = parsed.0
            warning = join(warning, parsed.1)
        }
        let picture = Picture(pixels: pixels, width: width, height: height, name: name, reduced: reduced, mark: mark)
        return (picture, warning)
    }

    private static func image(url: URL, name: String, fit: Bool) throws -> Picture {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw FoldError(message: "Could not read that image.")
        }
        return try image(source: source, name: name, fit: fit)
    }

    private static func image(data: Data, name: String, fit: Bool) throws -> Picture {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw FoldError(message: "Could not read that image.")
        }
        return try image(source: source, name: name, fit: fit)
    }

    private static func image(source: CGImageSource, name: String, fit: Bool) throws -> Picture {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = props?[kCGImagePropertyOrientation] as? Int ?? 1
        let swapped = [5, 6, 7, 8].contains(orientation)
        let orientedW = swapped ? height : width
        let orientedH = swapped ? width : height
        let longSide = max(orientedW, orientedH)
        let needsFit = fit || orientation != 1 || longSide > AppInfo.maxSide || longSide == 0
        let image: CGImage?
        if needsFit {
            let thumb: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: AppInfo.maxSide,
                kCGImageSourceShouldCache: false,
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumb as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        }
        guard let image else { throw FoldError(message: "Could not read that image.") }
        let pixels = try pixels(from: image)
        let reduced = fit || image.width != orientedW || image.height != orientedH
        return Picture(pixels: pixels, width: image.width, height: image.height, name: name, reduced: reduced, mark: nil)
    }

    private static func pixels(from image: CGImage) throws -> [UInt8] {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { throw FoldError(message: "That image is empty.") }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw FoldError(message: "Could not read that image.")
        }
        var raw = [UInt8](repeating: 0, count: width * height * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let drawn = raw.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: info
            ) else { return false }
            ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        guard drawn else { throw FoldError(message: "Could not read that image.") }
        var out = [UInt8](repeating: 0, count: raw.count)
        var index = 0
        while index < raw.count {
            let r = raw[index]
            let g = raw[index + 1]
            let b = raw[index + 2]
            let a = raw[index + 3]
            if a == 0 {
                out[index] = 0
                out[index + 1] = 0
                out[index + 2] = 0
                out[index + 3] = 0
            } else if a == 255 {
                out[index] = r
                out[index + 1] = g
                out[index + 2] = b
                out[index + 3] = a
            } else {
                let ia = Int(a)
                out[index] = UInt8(min(255, Int(r) * 255 / ia))
                out[index + 1] = UInt8(min(255, Int(g) * 255 / ia))
                out[index + 2] = UInt8(min(255, Int(b) * 255 / ia))
                out[index + 3] = a
            }
            index += 4
        }
        return out
    }

    private static func readHeader(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: 8) ?? Data()
    }

    private static func join(_ left: String?, _ right: String?) -> String? {
        switch (left, right) {
        case let (left?, right?): return left + " " + right
        case let (left?, nil): return left
        case let (nil, right?): return right
        default: return nil
        }
    }
}

func stemName(from url: URL?) -> String {
    guard let url else { return "Dragonscale" }
    var stem = url.deletingPathExtension().lastPathComponent
    for suffix in [".dragon", ".copy", ".restored"] {
        if stem.hasSuffix(suffix) {
            stem.removeLast(suffix.count)
            break
        }
    }
    return stem.isEmpty ? "Dragonscale" : stem
}
