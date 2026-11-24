import Foundation

// Heighway dragon transposition, the same rearrangement as
// SynologyDrive/Python_Scripts/dragon_curve/dragon_curve.py
// and the Dragonfold audio app. A phrase is hashed. The curve
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
        if count > AppInfo.maxUnits {
            throw FoldError(message: "That layout has \(count) segments. The curve stops at \(AppInfo.maxUnits). Choose a larger tile.")
        }
        var map = Array(0..<count)
        let sequence = reverse ? Array(passes.reversed()) : passes
        for (offset, pass) in sequence.enumerated() {
            onPass?(offset + 1, sequence.count)
            let order = try passOrder(count: count, pass)
            if reverse {
                var inverse = [Int](repeating: 0, count: count)
                for rank in 0..<count {
                    inverse[order[rank]] = rank
                }
                map = inverse.map { map[$0] }
            } else {
                map = order.map { map[$0] }
            }
        }
        return map
    }

    /// Heading of each step, in curve order. 0 east, 1 north, 2 west, 3 south.
    static func headings(count: Int, pass: Pass) throws -> [Int] {
        try walk(length: count, pass: pass, storeVertices: false, storeFaces: true).faces
    }

    /// Page order of one pass. `order[rank]` is the curve step that lands at that rank.
    static func segmentOrder(count: Int, pass: Pass) throws -> [Int] {
        try passOrder(count: count, pass)
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

    private struct Walk {
        var midpoints: [Point]
        var vertices: [Point]
        var faces: [Int]
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

    private static func turnIndex(skip: UInt64, index: Int) throws -> UInt64 {
        guard index >= 0 else {
            throw FoldError(message: "Length must be non-negative.")
        }
        let step = UInt64(index)
        let add = step &+ 1
        guard skip <= UInt64.max - add else {
            throw FoldError(message: "That picture is too large for this curve.")
        }
        return skip &+ add
    }

    private static func walk(length: Int, pass: Pass, storeVertices: Bool, storeFaces: Bool = false) throws -> Walk {
        if length < 0 {
            throw FoldError(message: "Length must be non-negative.")
        }
        if pass.fold != 1 && pass.fold != -1 {
            throw FoldError(message: "Fold must be left or right.")
        }
        if !(0...3).contains(pass.heading) {
            throw FoldError(message: "Heading must be east, north, west, or south.")
        }
        var x = 0
        var y = 0
        var face = pass.heading
        var vertices: [Point] = []
        if storeVertices {
            vertices.reserveCapacity(length + 1)
            vertices.append(Point(x: 0, y: 0))
        }
        var mids: [Point] = []
        mids.reserveCapacity(length)
        var faces: [Int] = []
        if storeFaces { faces.reserveCapacity(length) }
        // A paperfold walk does not revisit an edge. The set is a check for the
        // short curves the tests use. A photo-sized walk skips it.
        let watch = length <= 65_536
        var seen = Set<Int64>()
        if watch { seen.reserveCapacity(length) }
        for index in 0..<length {
            if storeFaces { faces.append(face) }
            let step = dirs[face]
            let nextX = x + step.0
            let nextY = y + step.1
            let midX = x + nextX
            let midY = y + nextY
            guard let packed = pack(midX, midY) else {
                throw FoldError(message: "That picture is too large for this curve.")
            }
            if watch {
                if !seen.insert(packed).inserted {
                    throw FoldError(message: "The dragon curve repeated a segment at index \(index).")
                }
            }
            mids.append(Point(x: midX, y: midY))
            x = nextX
            y = nextY
            if storeVertices {
                vertices.append(Point(x: x * 2, y: y * 2))
            }
            let n = try turnIndex(skip: pass.skip, index: index)
            let turn = paperTurn(n)
            face = (face + pass.fold * turn) % 4
            if face < 0 { face += 4 }
        }
        return Walk(midpoints: mids, vertices: vertices, faces: faces)
    }

    private static func pack(_ x: Int, _ y: Int) -> Int64? {
        guard let x32 = Int32(exactly: x), let y32 = Int32(exactly: y) else { return nil }
        let high = Int64(x32) << 32
        let low = Int64(UInt32(bitPattern: y32))
        return high | low
    }

    private static func passOrder(count: Int, _ pass: Pass) throws -> [Int] {
        let points = try walk(length: count, pass: pass, storeVertices: false).midpoints
        return try readingOrder(points: points, view: pass.view)
    }

    /// The fast order and the comparator order agree on every page direction.
    static func readingOrdersMatch(count: Int, pass: Pass) throws -> Bool {
        let points = try walk(length: count, pass: pass, storeVertices: false).midpoints
        for view in 0..<8 {
            let fast = try readingOrder(points: points, view: view)
            let slow = try readingOrderSorted(points: points, view: view)
            if fast != slow { return false }
        }
        return true
    }

    private static func readingOrder(points: [Point], view: Int) throws -> [Int] {
        let axes = try axes(for: view)
        let count = points.count
        if count <= 1 { return Array(0..<count) }
        // Primary in the high half, secondary in the low half. A stable
        // least-significant-digit sort keeps the original index when both match,
        // which is the same order as the comparator.
        let bias = Int64(count) * 2 + 4
        var keys = [UInt64](repeating: 0, count: count)
        for index in 0..<count {
            let (primary, secondary) = place(points[index], axes)
            let hi = Int64(primary) + bias
            let lo = Int64(secondary) + bias
            guard hi >= 0, hi <= Int64(UInt32.max), lo >= 0, lo <= Int64(UInt32.max) else {
                throw FoldError(message: "That picture is too large for this curve.")
            }
            keys[index] = (UInt64(hi) << 32) | UInt64(lo)
        }
        var order = Array(0..<count)
        var next = [Int](repeating: 0, count: count)
        for shift in stride(from: 0, to: 64, by: 8) {
            var bins = [Int](repeating: 0, count: 256)
            for index in order {
                bins[Int((keys[index] >> shift) & 0xFF)] += 1
            }
            var sum = 0
            for bin in 0..<256 {
                let tally = bins[bin]
                bins[bin] = sum
                sum += tally
            }
            for index in order {
                let bin = Int((keys[index] >> shift) & 0xFF)
                let dest = bins[bin]
                bins[bin] = dest + 1
                next[dest] = index
            }
            swap(&order, &next)
        }
        return order
    }

    /// The comparator the text vectors were checked against. Tests compare it with the radix sort.
    private static func readingOrderSorted(points: [Point], view: Int) throws -> [Int] {
        let axes = try axes(for: view)
        return points.indices.sorted { left, right in
            let a = place(points[left], axes)
            let b = place(points[right], axes)
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1 != b.1 { return a.1 < b.1 }
            return left < right
        }
    }

    private struct Axes {
        var outer: Int
        var inner: Int
        var columns: Bool
    }

    private static func axes(for view: Int) throws -> Axes {
        guard (0...7).contains(view) else {
            throw FoldError(message: "The reading direction must be one of the eight page orders.")
        }
        return Axes(
            outer: (view & 2) != 0 ? -1 : 1,
            inner: (view & 1) != 0 ? -1 : 1,
            columns: (view & 4) != 0
        )
    }

    private static func place(_ point: Point, _ axes: Axes) -> (Int, Int) {
        if axes.columns {
            return (point.x * axes.outer, -point.y * axes.inner)
        }
        return (-point.y * axes.outer, point.x * axes.inner)
    }
}
