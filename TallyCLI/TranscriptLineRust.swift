import Foundation
#if canImport(TallyRustCore)
import TallyRustCore
#endif

// The live transcript scan's line reader on the Rust core (rust/, scripts/build-rust-core.sh).
// The TallyCLI target links it; the swiftc-built suites compile this file without the module and
// get nothing from it, so their scan runs `StringLineView` exactly as before.

#if TALLY_RUST_REQUIRED && !canImport(TallyRustCore)
#error("TallyRustCore not found: SWIFT_INCLUDE_PATHS must contain $(SRCROOT)/rust/include")
#endif

#if canImport(TallyRustCore)
/// The needle finders, built once per process from `LineNeedle.table` and never freed. nil when the
/// core refuses the table, and then every line takes the substring readers.
private nonisolated(unsafe) let rustNeedles: OpaquePointer? = {
    let table = LineNeedle.table
    let flat = table.flatMap { $0 }
    let lens = table.map(\.count)
    let offsets = lens.reduce(into: [0]) { $0.append($0.last! + $1) }
    return flat.withUnsafeBufferPointer { base -> OpaquePointer? in
        let ptrs: [UnsafePointer<UInt8>?] = offsets.dropLast().map { base.baseAddress! + $0 }
        return ptrs.withUnsafeBufferPointer { p in
            lens.withUnsafeBufferPointer { l in tally_needles_new(p.baseAddress, l.baseAddress, table.count) }
        }
    }
}()

enum RustLineFields {
    /// What the core read off `line`, or nil when it could not answer (no needle table, or a
    /// panic inside it), in which case the caller reads the line the way it always was read.
    static func read(_ line: UnsafeRawBufferPointer) -> TallyLineFields? {
        guard let rustNeedles, let base = line.baseAddress else { return nil }
        var out = TallyLineFields()
        let rc = tally_line_fields(rustNeedles, base.assumingMemoryBound(to: UInt8.self),
                                   line.count, &out)
        return rc == 0 ? out : nil
    }
}

/// The answers `TranscriptLineView` asks for, out of one `TallyLineFields`. Lives only inside the
/// scan's `withUnsafeBytes` closure: `bytes` is not owned.
struct RustLineView: TranscriptLineView {
    let bytes: UnsafeRawBufferPointer
    let f: TallyLineFields

    func has(_ needle: LineNeedle) -> Bool { f.present & (1 << UInt64(needle.rawValue)) != 0 }
    func hasLimitResetToken() -> Bool { f.present >> UInt64(LineNeedle.limitResetBase) != 0 }

    private func string(_ span: TallySpan) -> String? {
        guard span.len >= 0 else { return nil }
        let start = Int(span.off)
        return String(decoding: UnsafeRawBufferPointer(rebasing: bytes[start..<start + Int(span.len)]),
                      as: UTF8.self)
    }

    var uuid: String? { string(f.uuid) }
    var parentUUID: String? { string(f.parent_uuid).flatMap { $0.isEmpty ? nil : $0 } }
    var timestamp: Date? {
        switch f.ts_kind {
        case TALLY_TS_PARSED:
            Date(timeIntervalSince1970: Double(f.ts_seconds) + Double(f.ts_millis) / 1000)
        case TALLY_TS_RAW: string(f.ts_raw).flatMap(transcriptParseISO)
        default: nil
        }
    }
    var modelValue: Substring? { string(f.model).map { $0[...] } }
    var contextTokens: Int? { f.context_tokens < 0 ? nil : Int(f.context_tokens) }
    var excerpt: String? { string(f.excerpt) }
    /// The decoder the scan has always used: it drops a leading byte-order mark, which
    /// `String(decoding:)` keeps. The line is valid UTF-8, so it never fails.
    var text: Substring { (String(bytes: bytes, encoding: .utf8) ?? "")[...] }
}
#endif
