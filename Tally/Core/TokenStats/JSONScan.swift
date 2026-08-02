import Foundation

/// A shallow reader over one JSON object's top-level members, working directly on bytes.
///
/// Why not `JSONDecoder`: the transcripts are ~5 GB and every line Tally cares about carries the
/// whole assistant turn (reasoning text, tool arguments, file contents) around six integers it
/// actually wants. Decoding the line to reach `message.usage` means materializing all of that.
/// This walker skips over values without interpreting them, so the cost is one linear pass with
/// no allocation, and only the few small members that are asked for are ever converted.
///
/// It is deliberately not a JSON validator: malformed input makes it stop early and report the
/// members it had already read, which is exactly the "skip bad lines quietly" behaviour the
/// scanner wants.
struct JSONScan {
    let bytes: UnsafeRawBufferPointer

    /// Calls `body` for each `key: value` pair directly inside the object that starts at
    /// `object.lowerBound`, with the key's range (quotes excluded) and the value's range
    /// (quotes/braces included). Nested objects and arrays are stepped over, not descended into.
    func forEachMember(in object: Range<Int>, _ body: (Range<Int>, Range<Int>) -> Void) {
        var i = object.lowerBound
        guard i < object.upperBound, bytes[i] == UInt8(ascii: "{") else { return }
        i += 1
        while i < object.upperBound {
            i = skipSpace(i, object.upperBound)
            guard i < object.upperBound else { return }
            let c = bytes[i]
            if c == UInt8(ascii: "}") { return }
            if c == UInt8(ascii: ",") { i += 1; continue }
            guard c == UInt8(ascii: "\"") else { return }   // malformed - stop where we are
            let keyEnd = endOfString(i, object.upperBound)
            let key = (i + 1) ..< (keyEnd - 1)
            i = skipSpace(keyEnd, object.upperBound)
            guard i < object.upperBound, bytes[i] == UInt8(ascii: ":") else { return }
            i = skipSpace(i + 1, object.upperBound)
            guard i < object.upperBound else { return }
            let valueEnd = endOfValue(i, object.upperBound)
            body(key, i ..< valueEnd)
            i = valueEnd
        }
    }

    /// The single member named `key`, or nil. For reading two or more members of the same object,
    /// prefer one `forEachMember` pass: each lookup here walks the object again.
    func member(_ key: StaticString, in object: Range<Int>) -> Range<Int>? {
        var found: Range<Int>?
        forEachMember(in: object) { k, v in
            if found == nil, self.key(k, is: key) { found = v }
        }
        return found
    }

    /// Whether a key range equals an ASCII literal.
    func key(_ range: Range<Int>, is literal: StaticString) -> Bool {
        guard range.count == literal.utf8CodeUnitCount else { return false }
        return literal.withUTF8Buffer { expected in
            for offset in 0 ..< expected.count where bytes[range.lowerBound + offset] != expected[offset] {
                return false
            }
            return true
        }
    }

    /// A non-negative integer member's value. Returns nil for anything that is not a plain
    /// integer (`null`, a float, a string), which is what every caller wants to treat as absent.
    func int64(_ range: Range<Int>) -> Int64? {
        var value: Int64 = 0
        var any = false
        for i in range {
            let c = bytes[i]
            guard c >= UInt8(ascii: "0"), c <= UInt8(ascii: "9") else { return nil }
            value = value * 10 + Int64(c - UInt8(ascii: "0"))
            any = true
        }
        return any ? value : nil
    }

    /// A string member's value, unescaped. `range` is the quoted value as returned by
    /// `forEachMember`.
    func string(_ range: Range<Int>) -> String? {
        guard range.count >= 2, bytes[range.lowerBound] == UInt8(ascii: "\"") else { return nil }
        let inner = (range.lowerBound + 1) ..< (range.upperBound - 1)
        var scalars: [UInt8] = []
        scalars.reserveCapacity(inner.count)
        var i = inner.lowerBound
        while i < inner.upperBound {
            let c = bytes[i]
            if c == UInt8(ascii: "\\"), i + 1 < inner.upperBound {
                let next = bytes[i + 1]
                switch next {
                case UInt8(ascii: "n"): scalars.append(UInt8(ascii: "\n"))
                case UInt8(ascii: "t"): scalars.append(UInt8(ascii: "\t"))
                case UInt8(ascii: "r"): scalars.append(UInt8(ascii: "\r"))
                // \uXXXX is left as written: the only strings read here are POSIX paths and ISO
                // timestamps, and a path spelled with escapes still keys consistently with itself.
                default: scalars.append(next)
                }
                i += 2
            } else {
                scalars.append(c)
                i += 1
            }
        }
        return String(decoding: scalars, as: UTF8.self)
    }

    // MARK: Byte walking

    private func skipSpace(_ from: Int, _ end: Int) -> Int {
        var i = from
        while i < end {
            switch bytes[i] {
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"): i += 1
            default: return i
            }
        }
        return i
    }

    /// Index just past the closing quote of the string starting at `from`.
    private func endOfString(_ from: Int, _ end: Int) -> Int {
        var i = from + 1
        while i < end {
            let c = bytes[i]
            if c == UInt8(ascii: "\\") { i += 2; continue }
            if c == UInt8(ascii: "\"") { return i + 1 }
            i += 1
        }
        return end
    }

    /// Index just past the value starting at `from`, whatever kind it is.
    private func endOfValue(_ from: Int, _ end: Int) -> Int {
        switch bytes[from] {
        case UInt8(ascii: "\""):
            return endOfString(from, end)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var i = from
            while i < end {
                let c = bytes[i]
                if c == UInt8(ascii: "\"") { i = endOfString(i, end); continue }
                if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") { depth += 1 }
                if c == UInt8(ascii: "}") || c == UInt8(ascii: "]") {
                    depth -= 1
                    if depth == 0 { return i + 1 }
                }
                i += 1
            }
            return end
        default:
            var i = from
            while i < end {
                switch bytes[i] {
                case UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"),
                     UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                    return i
                default: i += 1
                }
            }
            return end
        }
    }
}

/// Turns the transcripts' UTC timestamps into local calendar days.
///
/// Neither `ISO8601DateFormatter` nor `Calendar` is on this path: both cost far more per call than
/// the arithmetic, and this runs once per usage record over millions of records. The UTC zone
/// offset is asked of Foundation once per distinct UTC hour, which is exact (zone transitions land
/// on hour boundaries) and effectively free because transcript lines arrive in time order.
struct LocalDayStamper {
    private let zone: TimeZone
    private var cachedHour: Int = .min
    private var cachedOffset: Int = 0

    init(zone: TimeZone = .current) { self.zone = zone }

    /// The local day (days since 1970-01-01) for an ISO-8601 UTC timestamp such as
    /// `2026-07-17T11:52:33.310Z`, or nil if it is not shaped like one.
    mutating func day(fromISO scan: JSONScan, _ range: Range<Int>) -> Int? {
        guard let seconds = Self.epochSeconds(scan, range) else { return nil }
        return day(fromEpoch: seconds)
    }

    mutating func day(fromEpoch seconds: Int) -> Int {
        let hour = Int(floor(Double(seconds) / 3600))
        if hour != cachedHour {
            cachedHour = hour
            cachedOffset = zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(seconds)))
        }
        return Int(floor(Double(seconds + cachedOffset) / 86_400))
    }

    /// Today's local day number, the anchor every range window counts back from.
    static func today(zone: TimeZone = .current, now: Date = Date()) -> Int {
        var stamper = LocalDayStamper(zone: zone)
        return stamper.day(fromEpoch: Int(now.timeIntervalSince1970))
    }

    /// Seconds since the epoch for a `"yyyy-MM-ddTHH:mm:ss…Z"` string value (quotes included).
    /// Only the fixed-width prefix is read; fractional seconds and the trailing zone marker are
    /// ignored, because every writer here emits UTC.
    static func epochSeconds(_ scan: JSONScan, _ range: Range<Int>) -> Int? {
        let start = range.lowerBound + 1                      // skip the opening quote
        guard range.count >= 21 else { return nil }           // "yyyy-MM-ddTHH:mm:ssZ"
        func digits(_ offset: Int, _ count: Int) -> Int? {
            var value = 0
            for i in start + offset ..< start + offset + count {
                let c = scan.bytes[i]
                guard c >= UInt8(ascii: "0"), c <= UInt8(ascii: "9") else { return nil }
                value = value * 10 + Int(c - UInt8(ascii: "0"))
            }
            return value
        }
        guard let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
              month >= 1, month <= 12, day >= 1, day <= 31 else { return nil }
        return daysFromCivil(year, month, day) * 86_400 + hour * 3_600 + minute * 60 + second
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's `days_from_civil`).
    private static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400                                     // [0, 399]
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy             // [0, 146096]
        return era * 146_097 + doe - 719_468
    }
}
