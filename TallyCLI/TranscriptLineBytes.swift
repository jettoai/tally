import Foundation

// Byte-level readers for the catch-up path of `sawCapHit` (TranscriptWatcherScan.swift, issue #3).
//
// A supervisor bound to a long conversation used to decode the whole unread tail into one String
// and run a dozen Foundation searches on every line before asking whether the line was older than
// this child. On a 295 MB transcript that held the poll loop for minutes. Lines older than the
// launch only matter to the two readers that carry no time guard (the context size and the excerpt
// FIFO), so they are answered here straight off the bytes with memmem/memchr, and nothing else is
// done with them.
//
// These are TWINS of `lineTimestamp` (TranscriptSignals.swift), `lineUUID` and `userExcerpt`
// (TranscriptWatcher.swift) and `contextTokens` (SessionContext.swift). Every needle is ASCII and
// a transcript is UTF-8, so a byte match is a character match; change one side and the other in
// the same commit (transcriptcatchupchecks.swift compares them shape by shape).

/// Lines that must keep going through the full scan even when older than the launch: the readers
/// behind them judge time by the TOP-LEVEL stamp after a JSON parse (a cap event with no stamp at
/// all still counts), which the first-match stamp read here does not promise to equal.
let transcriptFullPathNeedles: [[UInt8]] = [
    Array("\"isApiErrorMessage\":true".utf8), Array("authentication_failed".utf8),
    Array("model_refusal_fallback".utf8), Array(nativeModelStdoutPrefix.utf8),
]

private let timestampKey = Array("\"timestamp\":\"".utf8)
private let uuidKey = Array("\"uuid\":\"".utf8)
private let contentKey = Array("\"content\":".utf8)
private let textKey = Array("\"text\":\"".utf8)
private let usageKey = Array("\"usage\":{".utf8)
private let iterationsKey = Array("\"iterations\":".utf8)
private let outputTokensKey = Array("\"output_tokens\":".utf8)
private let contextTokenFieldBytes = contextTokenFields.map { Array($0.utf8) }
let sidechainTrueBytes = Array("\"isSidechain\":true".utf8)
let typeUserBytes = Array("\"type\":\"user\"".utf8)
let typeAssistantBytes = Array("\"type\":\"assistant\"".utf8)

private let quote: UInt8 = 0x22

/// `parseISO` (Snapshot.swift) with its two formatters built once. The history path parses one
/// stamp per line, and building a formatter per call was most of that line's cost; the options are
/// the same two, tried in the same order, so the answer is the same. `nonisolated(unsafe)` because
/// ISO8601DateFormatter is documented thread-safe but not marked Sendable, and these are never
/// mutated after they are built.
private nonisolated(unsafe) let fractionalISO: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()
private nonisolated(unsafe) let plainISO = ISO8601DateFormatter()

func transcriptParseISO(_ string: String) -> Date? {
    fractionalISO.date(from: string) ?? plainISO.date(from: string)
}

/// The offset of the first `byte` at or after `from`, or nil.
func transcriptByteIndex(of byte: UInt8, in raw: UnsafeRawBufferPointer, from: Int = 0) -> Int? {
    guard from < raw.count, let base = raw.baseAddress,
          let hit = memchr(base + from, Int32(byte), raw.count - from) else { return nil }
    return base.distance(to: UnsafeRawPointer(hit))
}

/// The offset of the first occurrence of `needle` at or after `from`, or nil.
func transcriptBytesIndex(of needle: [UInt8], in raw: UnsafeRawBufferPointer,
                          from: Int = 0) -> Int? {
    guard from <= raw.count, let base = raw.baseAddress, !needle.isEmpty else { return nil }
    return needle.withUnsafeBytes { little -> Int? in
        guard let hit = memmem(base + from, raw.count - from, little.baseAddress, little.count)
        else { return nil }
        return base.distance(to: UnsafeRawPointer(hit))
    }
}

func transcriptBytesContain(_ raw: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
    transcriptBytesIndex(of: needle, in: raw) != nil
}

/// The index of the last newline in `data` at or after `from`. `data` must start at index 0.
func transcriptLastNewline(in data: Data, from: Int) -> Int? {
    data.withUnsafeBytes { raw -> Int? in
        var index = raw.count - 1
        while index >= from {
            if raw[index] == 0x0A { return index }
            index -= 1
        }
        return nil
    }
}

/// The string value that starts at `start` and runs to the next quote, decoded.
private func quotedValue(_ raw: UnsafeRawBufferPointer, from start: Int) -> String? {
    guard let end = transcriptByteIndex(of: quote, in: raw, from: start) else { return nil }
    return String(decoding: UnsafeRawBufferPointer(rebasing: raw[start..<end]), as: UTF8.self)
}

/// `lineTimestamp`, off the bytes.
func transcriptLineTimestamp(bytes raw: UnsafeRawBufferPointer) -> Date? {
    guard let key = transcriptBytesIndex(of: timestampKey, in: raw),
          let value = quotedValue(raw, from: key + timestampKey.count) else { return nil }
    return transcriptParseISO(value)
}

/// The launch instant as the first 19 bytes of a UTC stamp (`YYYY-MM-DDTHH:MM:SS`), floored to the
/// second: what `transcriptLineStampedBefore` compares a stamp against without parsing it.
func transcriptSecondKey(_ date: Date) -> [UInt8] {
    let floored = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    return Array(plainISO.string(from: floored).utf8.prefix(19))
}

/// Whether the line's stamp (the first match, as `lineTimestamp` reads it) is before `since`.
///
/// The date parse was most of what the history path cost per line (issue #3, measured on a 300 MB
/// corpus), so the UTC form Claude Code writes, `YYYY-MM-DDTHH:MM:SS[.fff]Z`, is compared as text
/// first: fixed-width digits order the same as the instants they name, and a stamp whose SECOND
/// is earlier than the launch's second is earlier than the launch whatever its fraction says.
/// Anything else (the same second, an offset instead of `Z`, another shape) is parsed as before.
/// A stamp of that shape that `parseISO` would still refuse (a month 13) reads as before here and
/// as no stamp there, and for a line the history path accepts those two do the same thing: only
/// the two unguarded readers run either way.
func transcriptLineStampedBefore(bytes raw: UnsafeRawBufferPointer, since: Date,
                                 sinceKey: [UInt8]) -> Bool {
    guard let key = transcriptBytesIndex(of: timestampKey, in: raw) else { return false }
    let start = key + timestampKey.count
    guard let end = transcriptByteIndex(of: quote, in: raw, from: start) else { return false }
    if sinceKey.count == 19, end - start >= 20, raw[end - 1] == 0x5A,
       raw[start + 19] == 0x5A || raw[start + 19] == 0x2E {
        var shaped = true
        var earlier: Bool?
        for index in 0..<19 {
            let byte = raw[start + index]
            switch index {
            case 4, 7: shaped = byte == 0x2D
            case 10: shaped = byte == 0x54
            case 13, 16: shaped = byte == 0x3A
            default: shaped = byte >= 0x30 && byte <= 0x39
            }
            if !shaped { break }
            if earlier == nil, byte != sinceKey[index] { earlier = byte < sinceKey[index] }
        }
        if shaped, earlier == true { return true }
    }
    let value = String(decoding: UnsafeRawBufferPointer(rebasing: raw[start..<end]), as: UTF8.self)
    guard let stamp = transcriptParseISO(value) else { return false }
    return stamp < since
}

/// `TranscriptWatcher.lineUUID`, off the bytes.
func transcriptLineUUID(bytes raw: UnsafeRawBufferPointer) -> String? {
    guard let key = transcriptBytesIndex(of: uuidKey, in: raw) else { return nil }
    return quotedValue(raw, from: key + uuidKey.count)
}

/// `TranscriptWatcher.userExcerpt`, off the bytes: a string `content`, else the first `text` after
/// the `content` key.
func transcriptUserExcerpt(bytes raw: UnsafeRawBufferPointer) -> String? {
    guard let key = transcriptBytesIndex(of: contentKey, in: raw) else { return nil }
    let rest = key + contentKey.count
    if rest < raw.count, raw[rest] == quote { return quotedValue(raw, from: rest + 1) }
    guard let text = transcriptBytesIndex(of: textKey, in: raw, from: rest) else { return nil }
    return quotedValue(raw, from: text + textKey.count)
}

/// `contextTokens(inLine:)`, off the bytes, with its rules unchanged: top-level totals only (the
/// window stops at `iterations`), all three input figures or nil, output when present, zero is nil.
func transcriptContextTokens(bytes raw: UnsafeRawBufferPointer) -> Int? {
    guard let usage = transcriptBytesIndex(of: usageKey, in: raw) else { return nil }
    let start = usage + usageKey.count
    let end = transcriptBytesIndex(of: iterationsKey, in: raw, from: start) ?? raw.count
    let window = UnsafeRawBufferPointer(rebasing: raw[start..<end])
    var total = 0
    for key in contextTokenFieldBytes {
        guard let value = tokenField(bytes: key, in: window) else { return nil }
        total += value
    }
    total += tokenField(bytes: outputTokensKey, in: window) ?? 0
    return total > 0 ? total : nil
}

/// `tokenField`, off the bytes: the ASCII digits right after `key`; nil when there are none or the
/// number does not fit an Int, which is what `Int(String)` answers too.
private func tokenField(bytes key: [UInt8], in window: UnsafeRawBufferPointer) -> Int? {
    guard let at = transcriptBytesIndex(of: key, in: window) else { return nil }
    var index = at + key.count
    var value = 0
    var digits = 0
    while index < window.count, window[index] >= 0x30, window[index] <= 0x39 {
        let (times, overflowA) = value.multipliedReportingOverflow(by: 10)
        let (sum, overflowB) = times.addingReportingOverflow(Int(window[index] - 0x30))
        if overflowA || overflowB { return nil }
        value = sum
        digits += 1
        index += 1
    }
    return digits > 0 ? value : nil
}
