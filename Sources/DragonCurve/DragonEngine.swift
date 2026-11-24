import CryptoKit
import Foundation

// Heighway dragon transposition, the same rearrangement as
// SynologyDrive/Python_Scripts/Ciphers/dragon_curve/dragon_curve.py.
// A key phrase is hashed. The curve only changes order, never the values.
// Notes are the modern character permutation. TEXT/1 and TEXT/2 are retired.
// Files use DRAGON-CURVE-DATA/3. Folders use DRAGON-CURVE-FOLDER/1 and /2.

enum DragonEngine {
    static let version = "2.0.0"
    static let build = "2"
    static let textPrefix = "DRAGON-CURVE-TEXT/"
    static let dataHeaderPrefix = "DRAGON-CURVE-DATA/3 "
    static let folderPrefix = "DRAGON-CURVE-FOLDER/"
    static let retiredText = "TEXT/1 and TEXT/2 are retired. An earlier Dragon Curve release can still open them."
    static let maxDraw = 8_000
    static let maxLetters = 400
    static let filenameMagic = Data([0x44, 0x43, 0x46, 0x4E, 0x31, 0x00])
    static let filenameMaxBytes = 255

    struct Failure: Equatable {
        var name: String
        var expected: String
        var actual: String
    }

    enum Unit: String, CaseIterable, Identifiable, Sendable {
        case character
        case hex
        case byte
        case bit

        var id: String { rawValue }

        var title: String {
            switch self {
            case .character: return "Character"
            case .hex: return "Hex digit"
            case .byte: return "Byte"
            case .bit: return "Bit"
            }
        }

        var detail: String {
            switch self {
            case .character:
                return "Unicode characters. The file must be UTF-8."
            case .hex:
                return "Two 4-bit digits from each byte."
            case .byte:
                return "Raw bytes. Any file."
            case .bit:
                return "Every bit, most significant bit first. Limited to 1 MB."
            }
        }

        var maxBytes: Int {
            switch self {
            case .bit: return 1_000_000
            case .hex: return 4_000_000
            case .byte, .character: return 8_000_000
            }
        }
    }

    struct Point: Hashable {
        var x: Int
        var y: Int
    }

    struct Mark: Equatable {
        var x: Int
        var y: Int
        var glyph: String
    }

    struct Pass: Equatable {
        var fold: Int
        var heading: Int
        var skip: UInt64
        var view: Int
    }

    struct CurvePicture: Equatable {
        var summary: String
        var path: [Point]
        var marks: [Mark]

        static let empty = CurvePicture(summary: "", path: [], marks: [])

        var minX: Int { bounds.minX }
        var maxX: Int { bounds.maxX }
        var minY: Int { bounds.minY }
        var maxY: Int { bounds.maxY }

        private var bounds: (minX: Int, maxX: Int, minY: Int, maxY: Int) {
            let xs = path.map(\.x) + marks.map(\.x)
            let ys = path.map(\.y) + marks.map(\.y)
            return (
                xs.min() ?? 0,
                xs.max() ?? 0,
                ys.min() ?? 0,
                ys.max() ?? 0
            )
        }
    }

    struct DataHeader {
        var unit: Unit
        var passes: Int
        var keyed: Bool
        var nameToken: String?
        var payload: Data
    }

    static func encrypt(text: String, key: String = "", passes: Int? = nil) throws -> String {
        try rearrangeText(text, key: key, reverse: false, passes: passes)
    }

    static func decrypt(text: String, key: String = "", passes: Int? = nil) throws -> String {
        if text.hasPrefix(textPrefix) {
            throw DragonError.message(retiredText)
        }
        return try rearrangeText(text, key: key, reverse: true, passes: passes)
    }

    /// A header writes a DATA/3 character envelope. Without one, the result is the raw character permutation.
    static func encryptDocument(
        text: String,
        key: String = "",
        header: Bool = false,
        passes: Int? = nil
    ) throws -> String {
        if header {
            let data = try encodeData(
                Data(text.utf8),
                key: key,
                unit: .character,
                passes: passes,
                header: true
            )
            guard let result = String(data: data, encoding: .utf8) else {
                throw DragonError.message("character result is not UTF-8")
            }
            return result
        }
        return try encrypt(text: text, key: key, passes: passes)
    }

    static func decryptDocument(
        data: String,
        key: String = "",
        passes: Int? = nil
    ) throws -> String {
        if data.hasPrefix(textPrefix) {
            throw DragonError.message(retiredText)
        }
        if data.hasPrefix(folderPrefix) {
            throw DragonError.message("This is a folder package. Use Decrypt Folder.")
        }
        if data.hasPrefix(dataHeaderPrefix) {
            guard data.hasPrefix("DRAGON-CURVE-DATA/3 mode=character ") else {
                throw DragonError.message("This is a file header. Drop the file and use Decrypt File.")
            }
            let opened = try decodeData(Data(data.utf8), key: key)
            guard let text = String(data: opened, encoding: .utf8) else {
                throw DragonError.message("character payload is not UTF-8")
            }
            return text
        }
        return try decrypt(text: data, key: key, passes: passes)
    }

    static func encodeData(
        _ data: Data,
        key: String = "",
        unit: Unit = .byte,
        passes: Int? = nil,
        header: Bool = true,
        nameToken: String? = nil
    ) throws -> Data {
        if nameToken != nil && !header {
            throw DragonError.message("A scrambled name needs the version header.")
        }
        let result = try transformUnits(data, key: key, unit: unit, passes: passes, reverse: false)
        guard header else { return result }
        let count = try selectedPlan(key: key, passes: passes).count
        let metadata = nameToken.map { " name=\($0)" } ?? ""
        let line = "DRAGON-CURVE-DATA/3 mode=\(unit.rawValue) passes=\(count) key=\(key.isEmpty ? 0 : 1)\(metadata)\n"
        var out = Data(line.utf8)
        out.append(result)
        return out
    }

    static func decodeData(
        _ data: Data,
        key: String = "",
        unit: Unit = .byte,
        passes: Int? = nil
    ) throws -> Data {
        if data.starts(with: Data(textPrefix.utf8)) {
            throw DragonError.message(retiredText)
        }
        if data.starts(with: Data("DRAGON-CURVE-DATA/".utf8)),
           !data.starts(with: Data(dataHeaderPrefix.utf8)) {
            throw DragonError.message("unsupported DATA format (only DATA/3 is supported)")
        }
        var unit = unit
        var passes = passes
        var payload = data
        if let header = try readDataHeader(data) {
            if header.keyed != !key.isEmpty {
                throw DragonError.message("The key does not match the file header. Leave the phrase empty only when the file had none.")
            }
            unit = header.unit
            passes = header.passes
            payload = header.payload
        }
        return try transformUnits(payload, key: key, unit: unit, passes: passes, reverse: true)
    }

    /// Parsed DATA/3 header. Nil when the bytes are unmarked. Throws when a DATA prefix is broken.
    static func readDataHeader(_ data: Data) throws -> DataHeader? {
        guard data.starts(with: Data(dataHeaderPrefix.utf8)) else { return nil }
        guard let newline = data.firstIndex(of: 0x0A) else {
            throw DragonError.message("incomplete binary header")
        }
        let line = data[..<newline]
        let payload = Data(data[data.index(after: newline)...])
        guard let parsed = parseDataHeader(line) else {
            throw DragonError.message("invalid binary Dragon Curve header")
        }
        return DataHeader(
            unit: parsed.unit,
            passes: parsed.passes,
            keyed: parsed.keyed,
            nameToken: parsed.nameToken,
            payload: payload
        )
    }

    /// Unit and payload size from a v3 header. Nil when the bytes are unmarked or the header is broken.
    static func describedInput(_ data: Data) -> (unit: Unit, count: Int)? {
        guard let header = try? readDataHeader(data) else { return nil }
        return (header.unit, header.payload.count)
    }

    static func openFile(
        _ data: Data,
        key: String,
        unit: Unit,
        passes: Int?
    ) throws -> Data {
        if data.starts(with: Data(folderPrefix.utf8)) {
            throw DragonError.message("This is a folder package. Use Decrypt Folder.")
        }
        return try decodeData(data, key: key, unit: unit, passes: passes)
    }

    static func picture(
        text: String,
        key: String,
        passes: Int? = nil,
        mapPass: Int = 1
    ) -> CurvePicture {
        let plan = (try? self.plan(key: key, passes: passes)) ?? []
        var summary = describe(plan)
        let scalars = Array(text.unicodeScalars)
        guard !scalars.isEmpty else {
            return CurvePicture(summary: summary, path: [], marks: [])
        }
        guard scalars.count <= maxDraw, !plan.isEmpty else {
            return CurvePicture(
                summary: summary + "\nThe curve is too long to draw.",
                path: [],
                marks: []
            )
        }
        let index = min(max(mapPass, 1), plan.count) - 1
        let pass = plan[index]
        let shown: [Unicode.Scalar]
        if index == 0 {
            shown = scalars
        } else if let entered = try? rearrange(scalars, passes: Array(plan.prefix(index)), reverse: false) {
            shown = entered
        } else {
            shown = scalars
        }
        if plan.count > 1 {
            summary += "\nShowing pass \(index + 1) of \(plan.count)."
        }
        guard let walked = try? walk(
            length: shown.count,
            fold: pass.fold,
            heading: pass.heading,
            skip: pass.skip,
            storeVertices: true
        ) else {
            return CurvePicture(summary: summary + "\nThe curve could not be drawn.", path: [], marks: [])
        }
        let showLetters = shown.count <= maxLetters
        let marks: [Mark]
        if showLetters {
            marks = zip(shown, walked.midpoints).map { scalar, point in
                Mark(x: point.x, y: point.y, glyph: glyph(scalar))
            }
        } else {
            marks = []
        }
        if !showLetters {
            summary += "\nThe path is drawn without letters."
        }
        return CurvePicture(summary: summary, path: walked.vertices, marks: marks)
    }

    static func describeCurve(key: String, passes: Int? = nil) -> String {
        describe((try? plan(key: key, passes: passes)) ?? [])
    }

    static func resolvedPassCount(key: String, passes: Int?) throws -> Int {
        try selectedPlan(key: key, passes: passes).count
    }

    static func midpoints(
        length: Int,
        fold: Int = 1,
        heading: Int = 0,
        skip: UInt64 = 0
    ) throws -> [Point] {
        try walk(length: length, fold: fold, heading: heading, skip: skip, storeVertices: false).midpoints
    }

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
    /// turn and 1 for a right turn. That is OEIS A014577, with left as +1.
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

    static func runSelfTest() -> [Failure] {
        var failures: [Failure] = []
        func expect(_ name: String, _ got: String, _ want: String) {
            if got != want {
                failures.append(Failure(name: name, expected: want, actual: got))
            }
        }
        func expectEqual<T: Equatable>(_ name: String, _ got: T, _ want: T) {
            if got != want {
                failures.append(Failure(name: name, expected: String(describing: want), actual: String(describing: got)))
            }
        }
        func expect(_ got: String, _ want: String, name: String) {
            expect(name, got, want)
        }
        func expectThrow(_ name: String, _ body: () throws -> Void) {
            do {
                try body()
                failures.append(Failure(name: name, expected: "throw", actual: "returned"))
            } catch {
                return
            }
        }

        expectEqual("fnv empty", fnv1a64(Data()), 0xCBF29CE484222325)
        expectEqual("fnv a", fnv1a64(Data("a".utf8)), 0xAF63DC4C8601EC8C)
        expectEqual("fnv foobar", fnv1a64(Data("foobar".utf8)), 0x85944171F73967E8)

        let (state, first) = splitmix64(0)
        expectEqual("splitmix first", first, 0xE220A8397B1DCDAF)
        expectEqual("splitmix second", splitmix64(state).1, 0x6E789E6AA1B965F4)

        let turns = (1...16).map { paperTurn(UInt64($0)) }
        expectEqual(
            "turns",
            turns,
            [1, 1, -1, 1, 1, -1, -1, 1, 1, 1, -1, -1, 1, -1, -1, 1]
        )

        if let points = try? midpoints(length: 5) {
            expectEqual(
                "hello midpoints",
                points,
                [
                    Point(x: 1, y: 0),
                    Point(x: 2, y: 1),
                    Point(x: 1, y: 2),
                    Point(x: 0, y: 3),
                    Point(x: -1, y: 4),
                ]
            )
        } else {
            expect("hello midpoints", "threw", "five points")
        }

        expect("windows", windowCheck(), "ok")

        do {
        expect(try encrypt(text: "Hello"), "olleH", name: "hello")
        expect(try encrypt(text: "Hello, World!"), "oorW,ll lde!H", name: "hello world")
        expect(try encrypt(text: "A B"), "B A", name: "a b")
        expect(try encrypt(text: "café"), "éfac", name: "cafe")
        expect(try encrypt(text: "Hello", key: "paper"), "loeHl", name: "paper")
        expect(try encrypt(text: "DRAGON", key: "curve"), "AONRGD", name: "curve")
        expect(try encrypt(text: "Hello, World!", key: "paper"), "!Wl, Hedrlloo", name: "paper world")
        expect(try decrypt(text: "olleH"), "Hello", name: "decrypt hello")
        expect(try decrypt(text: "loeHl", key: "paper"), "Hello", name: "decrypt paper")
        expect(try encrypt(text: ""), "", name: "empty")

        let plain = """
        U-boat 96.
        Resupply Sector 7.
        0500 hours.
        Hull integrity... stable.
        Awaiting contact.
        """
        let cipher = """
        6a.9to
         bR-peUlpsyuc etSor  7li0.ln05
        ut 0rHethus
        giyo.r...t.oc cnals tebtg.aan
        wiiAt
        """
        expect(try encrypt(text: plain), cipher, name: "uboat")
        expect(try decrypt(text: cipher), plain, name: "uboat back")

        expectEqual("paper passes", (try? passPlan(key: "paper").count) ?? -1, 7)
        expectEqual("curve passes", (try? passPlan(key: "curve").count) ?? -1, 4)
        expectEqual("empty passes", (try? passPlan(key: "").count) ?? -1, 1)
        expect(
            "paper describe",
            describeCurve(key: "paper"),
            """
            7 passes
            pass 1: right folds, facing east, segment 11994616190568657
            pass 2: left folds, facing east, segment 141907557425058726, read in columns from the left, bottom to top
            pass 3: left folds, facing south, segment 112749886710556725, read in columns from the left, bottom to top
            pass 4: right folds, facing west, segment 34597077459783303, read in rows from the bottom, left to right
            pass 5: right folds, facing west, segment 51395535641135671, read in rows from the top, right to left
            pass 6: left folds, facing south, segment 211893329079672255
            pass 7: right folds, facing east, segment 214439832454333792, read in rows from the bottom, left to right
            """
        )

        expect(hex(try transformUnits(Data("Hello".utf8), key: "paper", unit: .byte, passes: nil, reverse: false)), "6c6f65486c", name: "byte paper")
        expect(hex(try transformUnits(Data("Hello".utf8), key: "paper", unit: .byte, passes: 4, reverse: false)), "486f6c6c65", name: "byte paper 4")
        expect(hex(try transformUnits(Data("Hello".utf8), key: "", unit: .byte, passes: nil, reverse: false)), "6f6c6c6548", name: "byte empty")
        expect(hex(try transformUnits(Data([0, 1, 2, 3, 4]), key: "paper", unit: .hex, passes: 2, reverse: false)), "0300201004", name: "hex paper 2")
        expect(hex(try transformUnits(Data("Hi".utf8), key: "", unit: .bit, passes: 1, reverse: false)), "6234", name: "bit hi")
        expect(try String(data: transformUnits(Data("café".utf8), key: "paper", unit: .character, passes: nil, reverse: false), encoding: .utf8) ?? "", "éacf", name: "char paper cafe")
        expect(try String(data: transformUnits(Data("Hello".utf8), key: "paper", unit: .character, passes: 7, reverse: false), encoding: .utf8) ?? "", "loeHl", name: "explicit 7")
        expect(try String(data: transformUnits(Data("Hello".utf8), key: "", unit: .character, passes: 2, reverse: false), encoding: .utf8) ?? "", "Hello", name: "two canonical")

        let sevenLines = describeCurve(key: "curve", passes: 7).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        expectEqual("seven count line", sevenLines.first ?? "", "7 passes")
        expectEqual("seven line count", sevenLines.count, 8)
        expectEqual("has pass 6", sevenLines.contains { $0.hasPrefix("pass 6:") }, true)
        expectEqual("has pass 7", sevenLines.contains { $0.hasPrefix("pass 7:") }, true)
        expectEqual("explicit plan 7", (try plan(key: "curve", passes: 7)).count, 7)
        expectEqual("curve stays 4", (try plan(key: "curve", passes: nil)).count, 4)

        var sixKey = ""
        for number in 0..<500 {
            let name = "key\(number)"
            if (try passPlan(key: name)).count == 6 {
                sixKey = name
                break
            }
        }
        expect("found a 6-pass phrase", sixKey.isEmpty ? "none" : sixKey, sixKey.isEmpty ? "found" : sixKey)
        if !sixKey.isEmpty {
            let automatic = describeCurve(key: sixKey).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let extended = describeCurve(key: sixKey, passes: 7).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            expectEqual("automatic stops at 6", automatic.count, 7)
            expectEqual("chosen 7 does not stop at 6", extended.count, 8)
            expectEqual(
                "first six passes stay",
                Array(extended.dropFirst().prefix(6)),
                Array(automatic.dropFirst())
            )
            expectEqual("seventh line", extended.last?.hasPrefix("pass 7:") ?? false, true)
            let sixCipher = try encryptDocument(text: "Hello", key: sixKey, header: false, passes: 6)
            let sevenCipher = try encryptDocument(text: "Hello", key: sixKey, header: false, passes: 7)
            if sixCipher == sevenCipher {
                failures.append(Failure(name: "six differs from seven", expected: "different", actual: sixCipher))
            }
            expect(try decryptDocument(data: sevenCipher, key: sixKey, passes: 7), "Hello", name: "unmarked 7")
            let noted = try encryptDocument(text: "Hello", key: sixKey, header: true, passes: 7)
            expect(
                "note stores 7",
                noted.hasPrefix("DRAGON-CURVE-DATA/3 mode=character passes=7 key=1\n") ? "yes" : noted,
                "yes"
            )
            expect(try decryptDocument(data: noted, key: sixKey, passes: 1), "Hello", name: "stored 7 ignores picker")
        }

        let stored = try encryptDocument(text: "Hello", key: "paper", header: true)
        expect(
            "character header",
            stored.hasPrefix("DRAGON-CURVE-DATA/3 mode=character passes=7 key=1\nloeHl") ? "yes" : stored,
            "yes"
        )
        expect(try decryptDocument(data: stored, key: "paper"), "Hello", name: "character header open")
        expect(
            "plain header",
            try encryptDocument(text: "abc", header: true),
            "DRAGON-CURVE-DATA/3 mode=character passes=1 key=0\ncba"
        )
        let byteHeader = try encodeData(Data("abc".utf8), unit: .byte)
        expect(
            "default data header",
            String(data: byteHeader.prefix(while: { $0 != 0x0A }), encoding: .ascii) ?? "",
            "DRAGON-CURVE-DATA/3 mode=byte passes=1 key=0"
        )

        expectThrow("retired text") {
            _ = try decrypt(text: "DRAGON-CURVE-TEXT/2 key=1\nloeHl", key: "paper")
        }
        expectThrow("retired data") {
            _ = try decodeData(Data("DRAGON-CURVE-TEXT/1 key=0\nolleH".utf8))
        }
        expectThrow("missing key") {
            _ = try decryptDocument(data: stored, key: "")
        }

        let token = try scrambleFilename("notes.txt", key: "paper")
        expect(try restoreFilename(token, key: "paper"), "notes.txt", name: "filename round trip")
        expectThrow("filename wrong key") {
            _ = try restoreFilename(token, key: "other")
        }
        let named = try encodeData(Data("Hello".utf8), key: "paper", unit: .byte, passes: 4, header: true, nameToken: token)
        expect(try restoreFilename(try readDataHeader(named)?.nameToken ?? "", key: "paper"), "notes.txt", name: "name in header")
        expect(hex(try decodeData(named, key: "paper")), "48656c6c6f", name: "named payload")
        expectThrow("name without header") {
            _ = try encodeData(Data("a".utf8), header: false, nameToken: token)
        }

        let sealed = try encodeData(Data("Hello".utf8), key: "paper", unit: .byte, passes: 4, header: true)
        expect("data header prefix", String(data: sealed.prefix(while: { $0 != 0x0A }), encoding: .utf8) ?? "", "DRAGON-CURVE-DATA/3 mode=byte passes=4 key=1")
        expect(hex(try decodeData(sealed, key: "paper")), "48656c6c6f", name: "data header open")
        expectThrow("bad data header") {
            _ = try decodeData(Data("DRAGON-CURVE-DATA/3 mode=unknown passes=4 key=0\n".utf8))
        }
        expectThrow("data key mismatch") {
            _ = try decodeData(sealed, key: "")
        }

        let textSample = Data("Hello 🐉 ω café — line\n".utf8)
        var byteSample = Data()
        for value in 0..<256 {
            byteSample.append(UInt8(value))
        }
        byteSample.append(contentsOf: [0, 255])
        for unit in Unit.allCases {
            let sample = unit == .character ? textSample : byteSample
            for key in ["", "42"] {
                for passes in [1, 7] as [Int?] {
                    let label = "\(unit.rawValue) \(key.isEmpty ? "nokey" : key) \(passes ?? 0)"
                    do {
                        let folded = try transformUnits(sample, key: key, unit: unit, passes: passes, reverse: false)
                        let back = try transformUnits(folded, key: key, unit: unit, passes: passes, reverse: true)
                        if back != sample {
                            failures.append(Failure(name: label, expected: "round trip", actual: "\(back.count) bytes"))
                        }
                        let wrapped = try encodeData(sample, key: key, unit: unit, passes: passes, header: true)
                        let unwrapped = try decodeData(wrapped, key: key)
                        if unwrapped != sample {
                            failures.append(Failure(name: label + " header", expected: "round trip", actual: "header failed"))
                        }
                    } catch {
                        failures.append(Failure(name: label, expected: "round trip", actual: error.localizedDescription))
                    }
                }
            }
        }

        let wrong = try decrypt(text: "loeHl", key: "papers")
        if wrong == "Hello" {
            failures.append(Failure(name: "wrong key", expected: "not Hello", actual: wrong))
        }
        } catch {
            failures.append(Failure(name: "self-test", expected: "no throw", actual: error.localizedDescription))
        }
        return failures
    }

    // MARK: - Curve

    private static let dirs = [Point(x: 1, y: 0), Point(x: 0, y: 1), Point(x: -1, y: 0), Point(x: 0, y: -1)]
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

    private struct Walk {
        var midpoints: [Point]
        var vertices: [Point]
    }

    static func passPlan(key: String) throws -> [Pass] {
        if key.isEmpty {
            return [Pass(fold: 1, heading: 0, skip: 0, view: 0)]
        }
        var (state, word) = splitmix64(fnv1a64(Data(key.utf8)))
        let count = 4 + Int(word >> 62)
        var passes: [Pass] = []
        passes.reserveCapacity(count)
        for _ in 0..<count {
            (state, word) = splitmix64(state)
            passes.append(pass(from: word))
        }
        return passes
    }

    /// Automatic (`passes == nil`) follows the phrase. A number draws that many passes, 1 through 7.
    static func plan(key: String, passes: Int?) throws -> [Pass] {
        if passes == nil {
            return try passPlan(key: key)
        }
        return try selectedPlan(key: key, passes: passes)
    }

    static func selectedPlan(key: String, passes: Int?) throws -> [Pass] {
        if passes == nil {
            return try passPlan(key: key)
        }
        guard let passes, (1...7).contains(passes) else {
            throw DragonError.message("passes must be 1 through 7")
        }
        if key.isEmpty {
            return Array(repeating: Pass(fold: 1, heading: 0, skip: 0, view: 0), count: passes)
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

    private static func pass(from word: UInt64) -> Pass {
        Pass(
            fold: (word & 1) == 1 ? -1 : 1,
            heading: Int((word >> 1) & 3),
            skip: word >> 6,
            view: Int((word >> 3) & 7)
        )
    }

    private static func describe(_ passes: [Pass]) -> String {
        if passes.count == 1 {
            return describePass(passes[0])
        }
        var lines = ["\(passes.count) passes"]
        for (number, pass) in passes.enumerated() {
            lines.append("pass \(number + 1): \(describePass(pass))")
        }
        return lines.joined(separator: "\n")
    }

    private static func describePass(_ pass: Pass) -> String {
        let side = pass.fold == 1 ? "left" : "right"
        var line = "\(side) folds, facing \(headings[pass.heading]), segment \(pass.skip + 1)"
        if pass.view != 0 {
            line += ", read in \(views[pass.view])"
        }
        return line
    }

    /// The pen starts at the origin. `skip` chooses where in the turn
    /// sequence the message begins. The skipped segments are not walked.
    private static func walk(
        length: Int,
        fold: Int,
        heading: Int,
        skip: UInt64,
        storeVertices: Bool
    ) throws -> Walk {
        if length < 0 {
            throw DragonError.message("length must be non-negative")
        }
        if fold != 1 && fold != -1 {
            throw DragonError.message("fold must be 1 or -1")
        }
        if !(0...3).contains(heading) {
            throw DragonError.message("heading must be 0, 1, 2, or 3")
        }
        var x = 0
        var y = 0
        var face = heading
        var vertices: [Point] = []
        if storeVertices {
            vertices.reserveCapacity(length + 1)
            vertices.append(Point(x: 0, y: 0))
        }
        var mids: [Point] = []
        mids.reserveCapacity(length)
        var seen = Set<Point>()
        seen.reserveCapacity(length)
        for index in 0..<length {
            let step = dirs[face]
            let nextX = x + step.x
            let nextY = y + step.y
            let mid = Point(x: x + nextX, y: y + nextY)
            if seen.contains(mid) {
                throw DragonError.message("dragon curve repeated a segment at index \(index)")
            }
            seen.insert(mid)
            mids.append(mid)
            x = nextX
            y = nextY
            if storeVertices {
                vertices.append(Point(x: x * 2, y: y * 2))
            }
            let n = try turnIndex(skip: skip, index: index)
            let turn = paperTurn(n)
            face = (face + fold * turn) % 4
            if face < 0 {
                face += 4
            }
        }
        return Walk(midpoints: mids, vertices: vertices)
    }

    private static func turnIndex(skip: UInt64, index: Int) throws -> UInt64 {
        guard index >= 0 else {
            throw DragonError.message("length must be non-negative")
        }
        let step = UInt64(index)
        guard step < UInt64.max else {
            throw DragonError.message("message is too long")
        }
        let add = step + 1
        guard skip <= UInt64.max - add else {
            throw DragonError.message("message is too long")
        }
        return skip + add
    }

    private static func readingOrder(points: [Point], view: Int) throws -> [Int] {
        guard (0...7).contains(view) else {
            throw DragonError.message("view must be 0 to 7")
        }
        let outer = (view & 2) != 0 ? -1 : 1
        let inner = (view & 1) != 0 ? -1 : 1
        let columns = (view & 4) != 0
        func place(_ point: Point) -> (Int, Int) {
            if columns {
                return (point.x * outer, -point.y * inner)
            }
            return (-point.y * outer, point.x * inner)
        }
        return points.indices.sorted { left, right in
            let a = place(points[left])
            let b = place(points[right])
            if a.0 != b.0 { return a.0 < b.0 }
            return a.1 < b.1
        }
    }

    private static func passOrder(length: Int, _ pass: Pass) throws -> [Int] {
        let points = try walk(
            length: length,
            fold: pass.fold,
            heading: pass.heading,
            skip: pass.skip,
            storeVertices: false
        ).midpoints
        return try readingOrder(points: points, view: pass.view)
    }

    private static func rearrange<T>(_ values: [T], passes: [Pass], reverse: Bool) throws -> [T] {
        if values.isEmpty {
            return []
        }
        var items = values
        let sequence = reverse ? Array(passes.reversed()) : passes
        for pass in sequence {
            let order = try passOrder(length: items.count, pass)
            if reverse {
                var restored = [T?](repeating: nil, count: items.count)
                for (rank, walkIndex) in order.enumerated() {
                    restored[walkIndex] = items[rank]
                }
                items = try restored.map { value in
                    guard let value else {
                        throw DragonError.message("dragon curve reading was not a rearrangement")
                    }
                    return value
                }
            } else {
                items = order.map { items[$0] }
            }
        }
        return items
    }

    private static func rearrangeText(
        _ text: String,
        key: String,
        reverse: Bool,
        passes: Int?
    ) throws -> String {
        let plan = try selectedPlan(key: key, passes: passes)
        let mixed = try rearrange(Array(text.unicodeScalars), passes: plan, reverse: reverse)
        return String(String.UnicodeScalarView(mixed))
    }

    static func transformUnits(
        _ data: Data,
        key: String,
        unit: Unit,
        passes: Int?,
        reverse: Bool
    ) throws -> Data {
        let plan = try selectedPlan(key: key, passes: passes)
        switch unit {
        case .character:
            guard let text = String(data: data, encoding: .utf8) else {
                throw DragonError.message("character mode needs UTF-8 text")
            }
            let mixed = try rearrange(Array(text.unicodeScalars), passes: plan, reverse: reverse)
            return Data(String(String.UnicodeScalarView(mixed)).utf8)
        case .byte:
            let mixed = try rearrange([UInt8](data), passes: plan, reverse: reverse)
            return Data(mixed)
        case .hex:
            var nibbles: [UInt8] = []
            nibbles.reserveCapacity(data.count * 2)
            for byte in data {
                nibbles.append(byte >> 4)
                nibbles.append(byte & 0x0F)
            }
            let mixed = try rearrange(nibbles, passes: plan, reverse: reverse)
            var out = Data(count: mixed.count / 2)
            for index in stride(from: 0, to: mixed.count, by: 2) {
                out[index / 2] = (mixed[index] << 4) | mixed[index + 1]
            }
            return out
        case .bit:
            var bits: [UInt8] = []
            bits.reserveCapacity(data.count * 8)
            for byte in data {
                for shift in stride(from: 7, through: 0, by: -1) {
                    bits.append((byte >> shift) & 1)
                }
            }
            let mixed = try rearrange(bits, passes: plan, reverse: reverse)
            var out = Data(count: mixed.count / 8)
            for index in stride(from: 0, to: mixed.count, by: 8) {
                var byte: UInt8 = 0
                for bit in 0..<8 {
                    byte |= mixed[index + bit] << (7 - bit)
                }
                out[index / 8] = byte
            }
            return out
        }
    }

    private static func parseDataHeader(_ line: Data) -> (unit: Unit, passes: Int, keyed: Bool, nameToken: String?)? {
        guard let text = String(data: line, encoding: .ascii) else { return nil }
        let marker = "DRAGON-CURVE-DATA/3 mode="
        guard text.hasPrefix(marker) else { return nil }
        var rest = text.dropFirst(marker.count)
        guard let unit = Unit.allCases.first(where: { rest.hasPrefix($0.rawValue) }) else { return nil }
        rest = rest.dropFirst(unit.rawValue.count)
        guard rest.hasPrefix(" passes=") else { return nil }
        rest = rest.dropFirst(" passes=".count)
        guard let passChar = rest.first, let passes = Int(String(passChar)), (1...7).contains(passes) else {
            return nil
        }
        rest = rest.dropFirst()
        let keyed: Bool
        if rest.hasPrefix(" key=1") {
            keyed = true
            rest = rest.dropFirst(" key=1".count)
        } else if rest.hasPrefix(" key=0") {
            keyed = false
            rest = rest.dropFirst(" key=0".count)
        } else {
            return nil
        }
        if rest.isEmpty {
            return (unit, passes, keyed, nil)
        }
        guard rest.hasPrefix(" name=") else { return nil }
        let token = String(rest.dropFirst(" name=".count))
        guard token.range(of: #"^[A-Za-z0-9_-]{1,1000}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return (unit, passes, keyed, token)
    }

    static func validateFilename(_ name: String) throws -> String {
        if name.isEmpty || name == "." || name == ".." || name.contains("/") || name.contains("\\") {
            throw DragonError.message("That name cannot be stored. It is empty, or it contains a path.")
        }
        for scalar in name.unicodeScalars where scalar.value < 32 || scalar.value == 127 {
            throw DragonError.message("That name cannot be stored. It contains a control character.")
        }
        if Data(name.utf8).count > filenameMaxBytes {
            throw DragonError.message("That name is longer than 255 UTF-8 bytes.")
        }
        return name
    }

    static func scrambleFilename(_ name: String, key: String) throws -> String {
        let raw = Data(try validateFilename(name).utf8)
        let digest = Data(SHA256.hash(data: raw).prefix(8))
        var packet = filenameMagic
        packet.append(raw)
        packet.append(digest)
        let shuffled = try transformUnits(
            packet,
            key: "Dragon-Curve-Filename/v1:" + key,
            unit: .byte,
            passes: 7,
            reverse: false
        )
        var token = shuffled.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        while token.hasSuffix("=") {
            token.removeLast()
        }
        return token
    }

    static func restoreFilename(_ token: String, key: String) throws -> String {
        guard token.range(of: #"^[A-Za-z0-9_-]{1,1000}$"#, options: .regularExpression) != nil else {
            throw DragonError.message("The stored name is not a Dragon Curve name token.")
        }
        var padded = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        if remainder != 0 {
            padded += String(repeating: "=", count: 4 - remainder)
        }
        guard let shuffled = Data(base64Encoded: padded) else {
            throw DragonError.message("The stored name is not a Dragon Curve name token.")
        }
        let packet: Data
        do {
            packet = try transformUnits(
                shuffled,
                key: "Dragon-Curve-Filename/v1:" + key,
                unit: .byte,
                passes: 7,
                reverse: true
            )
        } catch {
            throw DragonError.message("Wrong key, or the stored name is damaged.")
        }
        guard packet.starts(with: filenameMagic), packet.count >= filenameMagic.count + 9 else {
            throw DragonError.message("Wrong key, or the stored name is damaged.")
        }
        let raw = packet.subdata(in: filenameMagic.count..<(packet.count - 8))
        let checksum = packet.suffix(8)
        let digest = Data(SHA256.hash(data: raw).prefix(8))
        guard digest.elementsEqual(checksum) else {
            throw DragonError.message("Wrong key, or the stored name is damaged.")
        }
        guard let name = String(data: raw, encoding: .utf8) else {
            throw DragonError.message("Wrong key, or the stored name is damaged.")
        }
        return try validateFilename(name)
    }

    /// Compose every folder pass once. The same length is reused for every full chunk.
    static func folderPermutation(length: Int, key: String, passes: Int) throws -> (forward: [Int], inverse: [Int]) {
        if length < 0 {
            throw DragonError.message("length must be non-negative")
        }
        if length == 0 {
            return ([], [])
        }
        let cacheKey = PermKey(length: length, key: key, passes: passes)
        permLock.lock()
        if let hit = permCache[cacheKey] {
            permLock.unlock()
            return hit
        }
        permLock.unlock()

        let plan = try selectedPlan(key: "Dragon-Curve-Folder/v1:" + key, passes: passes)
        var forward = Array(0..<length)
        for pass in plan {
            let ordering = try passOrder(length: length, pass)
            forward = ordering.map { forward[$0] }
        }
        var inverse = [Int](repeating: 0, count: length)
        for (ciphertextIndex, originalIndex) in forward.enumerated() {
            inverse[originalIndex] = ciphertextIndex
        }
        let value = (forward, inverse)
        permLock.lock()
        if permCache[cacheKey] == nil {
            permCache[cacheKey] = value
            permOrder.append(cacheKey)
            while permOrder.count > 20 {
                permCache[permOrder.removeFirst()] = nil
            }
        }
        permLock.unlock()
        return value
    }

    private struct PermKey: Hashable {
        var length: Int
        var key: String
        var passes: Int
    }

    private static let permLock = NSLock()
    private static var permCache: [PermKey: (forward: [Int], inverse: [Int])] = [:]
    private static var permOrder: [PermKey] = []

    static func glyph(_ scalar: Unicode.Scalar) -> String {
        switch scalar {
        case " ": return "␣"
        case "\n": return "↵"
        case "\t": return "→"
        case "\r": return "⏎"
        default:
            if scalar.value < 32 || scalar.value == 127 {
                return "·"
            }
            return String(scalar)
        }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func windowCheck() -> String {
        let windows: [(Int, Int, UInt64)] = [
            (1, 0, 0),
            (-1, 0, 0),
            (1, 2, 7),
            (-1, 3, 1_000_000),
        ]
        for window in windows {
            guard let points = try? midpoints(length: 400, fold: window.0, heading: window.1, skip: window.2) else {
                return "threw \(window)"
            }
            if Set(points).count != 400 {
                return "repeat \(window)"
            }
        }
        return "ok"
    }
}

enum DragonError: Error, Equatable, LocalizedError {
    case failed(String)
    case usage(String)

    var errorDescription: String? {
        switch self {
        case .failed(let text), .usage(let text): return text
        }
    }

    var isUsage: Bool {
        if case .usage = self { return true }
        return false
    }

    static func message(_ text: String) -> DragonError {
        .failed(text)
    }
}
