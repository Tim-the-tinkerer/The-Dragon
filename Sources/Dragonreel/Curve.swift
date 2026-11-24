import Foundation

// Heighway dragon transposition, the same rearrangement as
// SynologyDrive/Python_Scripts/dragon_curve/dragon_curve.py,
// Dragonfold, and Dragonscale. A phrase is hashed. The curve
// only changes order, never the values.

struct FoldError: Error, Equatable, LocalizedError {
    var message: String

    var errorDescription: String? { message }
}

enum Curve {
    struct Point: Equatable {
        var x: Int
        var y: Int
    }

    struct Pass: Equatable {
        var fold: Int
        var heading: Int
        var skip: UInt64
        var view: Int
    }

    struct Drawing: Equatable {
        var vertices: [Point]
        var headline: String
        var detail: String
    }

    private static let headings = ["east", "north", "west", "south"]
    private static let views = [
        "rows from the top, left to right",
        "rows from the top, right to left",
        "rows from the bottom, left to right",
        "rows from the bottom, right to left",
        "columns from the left, top to bottom",
        "columns from the left, bottom to top",
        "columns from the right, top to bottom",
        "columns from the right, bottom to top",
    ]
    private static let dirs = [(1, 0), (0, 1), (-1, 0), (0, -1)]

    static func fnv1a64(_ data: Data) -> UInt64 {
        var digest: UInt64 = 14_695_981_039_346_656_037
        let prime: UInt64 = 1_099_511_628_211
        for byte in data {
            digest ^= UInt64(byte)
            digest = digest &* prime
        }
        return digest
    }

    static func splitmix64(_ state: UInt64) -> (UInt64, UInt64) {
        let state = state &+ 0x9E3779B97F4A7C15
        var word = state
        word = (word ^ (word >> 30)) &* 0xBF58476D1CE4E5B9
        word = (word ^ (word >> 27)) &* 0x94D049BB133111EB
        return (state, word ^ (word >> 31))
    }

    /// Lowest set bit of n is the crease. The bit above it is 0 for a left
    /// turn and 1 for a right turn. OEIS A014577, with left as +1.
    static func paperTurn(_ n: UInt64) -> Int {
        let lowest = n & (0 &- n)
        if lowest > (1 << 62) {
            return 1
        }
        if n & (lowest << 1) != 0 {
            return -1
        }
        return 1
    }

    /// `passes == nil` follows the phrase: one canonical pass when the phrase
    /// is empty, otherwise 4 to 7. A number is that many passes, 1 through 7.
    /// `classic` is the version 1 single pass, used only to match the script.
    static func plan(key: String, passes: Int?, classic: Bool = false) throws -> [Pass] {
        if classic {
            return [classicPass(key)]
        }
        if let passes {
            guard (1...7).contains(passes) else {
                throw FoldError(message: "Passes must be 1 through 7.")
            }
            if key.isEmpty {
                return Array(repeating: canonical, count: passes)
            }
            var (state, word) = splitmix64(fnv1a64(Data(key.utf8)))
            var result: [Pass] = []
            result.reserveCapacity(passes)
            for _ in 0..<passes {
                (state, word) = splitmix64(state)
                result.append(pass(from: word))
            }
            return result
        }
        if key.isEmpty {
            return [canonical]
        }
        var (state, word) = splitmix64(fnv1a64(Data(key.utf8)))
        let count = 4 + Int(word >> 62)
        var result: [Pass] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            (state, word) = splitmix64(state)
            result.append(pass(from: word))
        }
        return result
    }

    static func describe(_ pass: Pass) -> String {
        let side = pass.fold == 1 ? "left" : "right"
        let facing = headings[pass.heading]
        var line = "\(side) folds, facing \(facing), segment \(pass.skip + 1)"
        if pass.view != 0 {
            line += ", read in \(views[pass.view])"
        }
        return line
    }

    static func viewName(_ view: Int) -> String {
        guard views.indices.contains(view) else { return "page order" }
        return views[view]
    }

    /// Forward: output[i] = input[map[i]]. Reverse undoes the passes, last first.
    static func indexMap(
        count: Int,
        passes: [Pass],
        reverse: Bool,
        onPass: ((Int, Int) -> Void)? = nil
    ) throws -> [Int] {
        if count == 0 { return [] }
        var map = Array(0..<count)
        let sequence = reverse ? Array(passes.reversed()) : passes
        for (offset, pass) in sequence.enumerated() {
            onPass?(offset + 1, sequence.count)
            let order = try segmentOrder(count: count, pass: pass)
            if reverse {
                var inverse = [Int](repeating: 0, count: count)
                for rank in 0..<count {
                    inverse[Int(order[rank])] = rank
                }
                map = inverse.map { map[$0] }
            } else {
                var next = [Int](repeating: 0, count: count)
                for rank in 0..<count {
                    next[rank] = map[Int(order[rank])]
                }
                map = next
            }
        }
        return map
    }

    /// `order[rank]` is the segment that lands at `rank`.
    /// The order is a permutation, so the fold can be undone.
    static func segmentOrder(count: Int, pass: Pass) throws -> [UInt32] {
        if count > AppInfo.maxUnits {
            throw FoldError(message: "That layout has \(AppInfo.grouped(count)) segments. The curve stops at \(AppInfo.grouped(AppInfo.maxUnits)).")
        }
        if count == 0 { return [] }
        let keys = try readingKeys(count: count, pass: pass)
        return radixOrder(keys)
    }

    static func rearrange<T>(
        _ values: [T],
        key: String,
        passes: Int?,
        classic: Bool = false,
        reverse: Bool
    ) throws -> [T] {
        let passes = try plan(key: key, passes: passes, classic: classic)
        let map = try indexMap(count: values.count, passes: passes, reverse: reverse)
        return map.map { values[$0] }
    }

    /// Vertices of one pass, in the doubled coordinates the dragon map uses.
    /// `length` is how many segments to walk. The skipped part of the curve is not walked.
    static func vertices(length: Int, pass: Pass) throws -> [Point] {
        try walk(length: length, pass: pass, storeVertices: true).vertices
    }

    static func drawing(
        segments: Int,
        passes: [Pass],
        shown: Int,
        unitLine: String
    ) throws -> Drawing {
        guard !passes.isEmpty else {
            return Drawing(vertices: [], headline: "No pass.", detail: "")
        }
        let index = min(max(shown, 0), passes.count - 1)
        let pass = passes[index]
        let draw = min(max(segments, 0), AppInfo.drawSegments)
        let vertices = draw == 0 ? [] : try self.vertices(length: draw, pass: pass)
        let headline = "\(passes.count) pass\(passes.count == 1 ? "" : "es") · \(unitLine)"
        var lines = ["Pass \(index + 1) of \(passes.count): \(describe(pass))"]
        if segments > draw && draw > 0 {
            lines.append("Showing the first \(draw) of \(segments) segments.")
        } else if draw > 0 {
            lines.append("Showing all \(draw) segments of this pass.")
        }
        lines.append("Read in \(viewName(pass.view)).")
        if passes.count > 1 {
            lines.append("")
            for (number, item) in passes.enumerated() {
                lines.append("Pass \(number + 1): \(describe(item))")
            }
        }
        return Drawing(vertices: vertices, headline: headline, detail: lines.joined(separator: "\n"))
    }

    // MARK: - Walk

    private static let canonical = Pass(fold: 1, heading: 0, skip: 0, view: 0)

    /// The dragon does not reuse an edge. The set only checks short walks.
    /// A song is millions of samples, and a set of every midpoint does not fit.
    private static let checkedLength = 100_000

    private struct Mid {
        var x: Int32
        var y: Int32
    }

    private struct Walk {
        var midpoints: [Mid]
        var vertices: [Point]
    }

    private static func classicPass(_ key: String) -> Pass {
        if key.isEmpty { return canonical }
        let digest = fnv1a64(Data(key.utf8))
        let fold = (digest & 1) == 1 ? -1 : 1
        let heading = Int((digest >> 1) & 3)
        return Pass(fold: fold, heading: heading, skip: digest >> 3, view: 0)
    }

    private static func pass(from word: UInt64) -> Pass {
        Pass(
            fold: (word & 1) == 1 ? -1 : 1,
            heading: Int((word >> 1) & 3),
            skip: word >> 6,
            view: Int((word >> 3) & 7)
        )
    }

    private static func walk(length: Int, pass: Pass, storeVertices: Bool) throws -> Walk {
        if length < 0 {
            throw FoldError(message: "Length must be non-negative.")
        }
        if pass.fold != 1 && pass.fold != -1 {
            throw FoldError(message: "Fold must be left or right.")
        }
        if !(0...3).contains(pass.heading) {
            throw FoldError(message: "Heading must be east, north, west, or south.")
        }
        if length > 0, pass.skip > UInt64.max - UInt64(length) {
            throw FoldError(message: "That reel is too long for this curve.")
        }
        var x = 0
        var y = 0
        var face = pass.heading
        var vertices: [Point] = []
        if storeVertices {
            vertices.reserveCapacity(length + 1)
            vertices.append(Point(x: 0, y: 0))
        }
        var mids: [Mid] = []
        mids.reserveCapacity(length)
        let check = length <= checkedLength
        var seen = Set<Int64>()
        if check { seen.reserveCapacity(length) }
        let skip = pass.skip
        for index in 0..<length {
            let step = dirs[face]
            let nextX = x + step.0
            let nextY = y + step.1
            let midX = x + nextX
            let midY = y + nextY
            guard let sx = Int32(exactly: midX), let sy = Int32(exactly: midY) else {
                throw FoldError(message: "That reel is too long for this curve.")
            }
            if check {
                let packed = (Int64(sx) << 32) | Int64(UInt32(bitPattern: sy))
                if !seen.insert(packed).inserted {
                    throw FoldError(message: "The dragon curve repeated a segment at index \(index).")
                }
            }
            mids.append(Mid(x: sx, y: sy))
            x = nextX
            y = nextY
            if storeVertices {
                vertices.append(Point(x: x * 2, y: y * 2))
            }
            let turn = paperTurn(skip &+ UInt64(index) &+ 1)
            face = (face + pass.fold * turn) % 4
            if face < 0 { face += 4 }
        }
        return Walk(midpoints: mids, vertices: vertices)
    }

    /// Keys are built here, and the midpoints are released before the caller sorts.
    private static func readingKeys(count: Int, pass: Pass) throws -> [UInt64] {
        let points = try walk(length: count, pass: pass, storeVertices: false).midpoints
        guard (0...7).contains(pass.view) else {
            throw FoldError(message: "The reading direction must be one of the eight page orders.")
        }
        if points.isEmpty { return [] }
        let outer = (pass.view & 2) != 0 ? -1 : 1
        let inner = (pass.view & 1) != 0 ? -1 : 1
        let columns = (pass.view & 4) != 0
        func place(_ point: Mid) -> (Int, Int) {
            let x = Int(point.x)
            let y = Int(point.y)
            if columns {
                return (x * outer, -y * inner)
            }
            return (-y * outer, x * inner)
        }
        var minPrimary = Int.max
        var maxPrimary = Int.min
        var minSecondary = Int.max
        var maxSecondary = Int.min
        for point in points {
            let placed = place(point)
            if placed.0 < minPrimary { minPrimary = placed.0 }
            if placed.0 > maxPrimary { maxPrimary = placed.0 }
            if placed.1 < minSecondary { minSecondary = placed.1 }
            if placed.1 > maxSecondary { maxSecondary = placed.1 }
        }
        let spanPrimary = maxPrimary - minPrimary
        let spanSecondary = maxSecondary - minSecondary
        guard spanPrimary >= 0, spanSecondary >= 0,
              spanPrimary <= Int(UInt32.max), spanSecondary <= Int(UInt32.max) else {
            throw FoldError(message: "That reel is too long for this curve.")
        }
        var keys = [UInt64](repeating: 0, count: points.count)
        for index in 0..<points.count {
            let placed = place(points[index])
            let primary = UInt64(UInt32(placed.0 - minPrimary))
            let secondary = UInt64(UInt32(placed.1 - minSecondary))
            keys[index] = (primary << 32) | secondary
        }
        return keys
    }

    /// Stable 16-bit LSD radix. Equal keys keep the earlier segment, which is
    /// the same tie-break as a stable sort of the page order.
    private static func radixOrder(_ keys: [UInt64]) -> [UInt32] {
        let count = keys.count
        if count == 0 { return [] }
        if count == 1 { return [0] }
        var current = [UInt32](unsafeUninitializedCapacity: count) { buffer, initialized in
            for index in 0..<count {
                buffer[index] = UInt32(index)
            }
            initialized = count
        }
        var next = [UInt32](repeating: 0, count: count)
        let bins = 65_536
        var histogram = [Int](repeating: 0, count: bins)
        for shift in stride(from: 0, to: 64, by: 16) {
            for bin in 0..<bins { histogram[bin] = 0 }
            let amount = UInt64(shift)
            for key in keys {
                histogram[Int((key >> amount) & 0xFFFF)] += 1
            }
            var sum = 0
            for bin in 0..<bins {
                let tally = histogram[bin]
                histogram[bin] = sum
                sum += tally
            }
            for index in current {
                let key = keys[Int(index)]
                let bin = Int((key >> amount) & 0xFFFF)
                let dest = histogram[bin]
                histogram[bin] = dest + 1
                next[dest] = index
            }
            swap(&current, &next)
        }
        return current
    }
}
