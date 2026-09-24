import Foundation

// Claude Code keeps its own JSON files (settings.json, .claude.json) the way
// `JSON.stringify(value, null, 2)` writes them: two-space indent, `"key": value`, slashes and
// non-ASCII text as they are, keys in insertion order. Measured on 2026-09-25: every settings.json
// and .claude.json on the development machine reproduces byte for byte from that rule. Foundation's
// pretty printer disagrees on all four counts, so a file Tally rewrote came back as a whole-file diff
// in any dotfiles repository tracking it, and flipped back the next time Claude Code saved it.
//
// So a changed document is written in the file's own layout. Every member and element whose value
// did not change is copied from the original bytes exactly as it was; keys keep their order; keys the
// edit added go at the end of their object; only what changed is rendered, in Claude Code's style.

/// The bytes to store for `value`, laid out like `original` (the file's bytes before the edit, or nil
/// or empty for a file that does not exist yet).
///
/// The result is parsed back and compared with `value` before it is returned. A layout that cannot
/// reproduce the value falls back to a fresh rendering, and one that still cannot is thrown rather
/// than written.
func claudeJSONData(_ value: [String: Any], replacing original: Data?) throws -> Data {
    if let original, !original.isEmpty, let layout = ClaudeJSONLayout(original) {
        var writer = ClaudeJSONWriter(original: layout.bytes, indent: layout.indent)
        writer.out += layout.bytes[..<layout.root.range.lowerBound]
        try writer.write(value, old: layout.old, source: layout.root, depth: 0)
        writer.out += layout.bytes[layout.root.range.upperBound...]
        if let data = claudeJSONVerified(writer.out, value) { return data }
    }
    var writer = ClaudeJSONWriter(original: [], indent: Array("  ".utf8))
    try writer.write(value, old: nil, source: nil, depth: 0)
    writer.out.append(0x0A)
    guard let data = claudeJSONVerified(writer.out, value) else { throw claudeJSONEncodingError() }
    return data
}

private func claudeJSONEncodingError() -> NSError {
    NSError(domain: "tally", code: 7, userInfo: [
        NSLocalizedDescriptionKey: "Could not encode the settings document.",
    ])
}

private func claudeJSONVerified(_ bytes: [UInt8], _ value: [String: Any]) -> Data? {
    let data = Data(bytes)
    guard let back = try? JSONSerialization.jsonObject(with: data),
          claudeJSONValuesMatch(back, value) else { return nil }
    return data
}

/// Strict equality of two JSON values: `true` and `1` differ, and strings compare scalar by scalar
/// rather than by canonical equivalence.
func claudeJSONValuesMatch(_ one: Any, _ other: Any) -> Bool {
    switch (one, other) {
    case let (a as [String: Any], b as [String: Any]):
        return a.count == b.count
            && a.allSatisfy { key, value in b[key].map { claudeJSONValuesMatch(value, $0) } ?? false }
    case let (a as [Any], b as [Any]):
        return a.count == b.count && zip(a, b).allSatisfy { claudeJSONValuesMatch($0, $1) }
    case let (a as String, b as String):
        return a.unicodeScalars.elementsEqual(b.unicodeScalars)
    case let (a as NSNumber, b as NSNumber):
        return claudeJSONIsBool(a) == claudeJSONIsBool(b) && a == b
    case (is NSNull, is NSNull):
        return true
    default:
        return false
    }
}

private func claudeJSONIsBool(_ number: NSNumber) -> Bool {
    CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID()
}

/// Where each value sits in the original bytes, and in what order an object's keys came.
private struct ClaudeJSONSource {
    enum Shape {
        case object([(key: String, rawKey: Range<Int>, value: ClaudeJSONSource)])
        case array([ClaudeJSONSource])
        case scalar
    }
    let range: Range<Int>
    let shape: Shape
}

/// The original file as a layout: its bytes, what Foundation parsed out of them, where every value
/// sits, and the indent unit. Nil when there is no usable layout (not an object, trailing garbage,
/// or a duplicate key, where the parsed value and the bytes no longer describe one another).
private struct ClaudeJSONLayout {
    let bytes: [UInt8]
    let old: Any
    let root: ClaudeJSONSource
    let indent: [UInt8]

    init?(_ data: Data) {
        guard let old = try? JSONSerialization.jsonObject(with: data), old is [String: Any]
        else { return nil }
        var scanner = ClaudeJSONScanner(bytes: [UInt8](data))
        guard let root = scanner.value() else { return nil }
        scanner.skipSpace()
        guard scanner.at == scanner.bytes.count else { return nil }
        self.bytes = scanner.bytes
        self.old = old
        self.root = root
        self.indent = Self.indentUnit(scanner.bytes, root) ?? Array("  ".utf8)
    }

    /// The whitespace between the newline and the root object's first key.
    private static func indentUnit(_ bytes: [UInt8], _ root: ClaudeJSONSource) -> [UInt8]? {
        guard case .object(let members) = root.shape, let first = members.first else { return nil }
        var start = first.rawKey.lowerBound
        while start > root.range.lowerBound, bytes[start - 1] == 0x20 || bytes[start - 1] == 0x09 {
            start -= 1
        }
        guard start > 0, bytes[start - 1] == 0x0A, start < first.rawKey.lowerBound else { return nil }
        return Array(bytes[start ..< first.rawKey.lowerBound])
    }
}

/// Finds token boundaries only. The values themselves were already parsed by Foundation; this only
/// has to say where each one is, so scalars are not validated here.
private struct ClaudeJSONScanner {
    let bytes: [UInt8]
    var at = 0

    mutating func skipSpace() {
        while at < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[at]) { at += 1 }
    }

    mutating func value() -> ClaudeJSONSource? {
        skipSpace()
        guard at < bytes.count else { return nil }
        let start = at
        switch bytes[at] {
        case UInt8(ascii: "{"):
            at += 1
            var members: [(key: String, rawKey: Range<Int>, value: ClaudeJSONSource)] = []
            var seen = Set<String>()
            skipSpace()
            if at < bytes.count, bytes[at] == UInt8(ascii: "}") {
                at += 1
                return ClaudeJSONSource(range: start ..< at, shape: .object([]))
            }
            while true {
                skipSpace()
                guard let rawKey = string(), let key = decoded(rawKey), seen.insert(key).inserted
                else { return nil }
                skipSpace()
                guard at < bytes.count, bytes[at] == UInt8(ascii: ":") else { return nil }
                at += 1
                guard let member = value() else { return nil }
                members.append((key, rawKey, member))
                skipSpace()
                guard at < bytes.count else { return nil }
                if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                guard bytes[at] == UInt8(ascii: "}") else { return nil }
                at += 1
                return ClaudeJSONSource(range: start ..< at, shape: .object(members))
            }
        case UInt8(ascii: "["):
            at += 1
            var elements: [ClaudeJSONSource] = []
            skipSpace()
            if at < bytes.count, bytes[at] == UInt8(ascii: "]") {
                at += 1
                return ClaudeJSONSource(range: start ..< at, shape: .array([]))
            }
            while true {
                guard let element = value() else { return nil }
                elements.append(element)
                skipSpace()
                guard at < bytes.count else { return nil }
                if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                guard bytes[at] == UInt8(ascii: "]") else { return nil }
                at += 1
                return ClaudeJSONSource(range: start ..< at, shape: .array(elements))
            }
        case UInt8(ascii: "\""):
            guard let range = string() else { return nil }
            return ClaudeJSONSource(range: range, shape: .scalar)
        default:
            let stops: [UInt8] = [0x2C, 0x5D, 0x7D, 0x20, 0x09, 0x0A, 0x0D]
            while at < bytes.count, !stops.contains(bytes[at]) { at += 1 }
            guard at > start else { return nil }
            return ClaudeJSONSource(range: start ..< at, shape: .scalar)
        }
    }

    private mutating func string() -> Range<Int>? {
        guard at < bytes.count, bytes[at] == UInt8(ascii: "\"") else { return nil }
        let start = at
        at += 1
        while at < bytes.count {
            switch bytes[at] {
            case UInt8(ascii: "\\"): at += 2
            case UInt8(ascii: "\""): at += 1; return start ..< at
            default: at += 1
            }
        }
        return nil
    }

    private func decoded(_ range: Range<Int>) -> String? {
        (try? JSONSerialization.jsonObject(with: Data(bytes[range]), options: .fragmentsAllowed))
            as? String
    }
}

private struct ClaudeJSONWriter {
    let original: [UInt8]
    let indent: [UInt8]
    var out: [UInt8] = []

    /// `old` and `source` always describe the same original value: the parsed one and where its
    /// bytes are. While they match `value`, those bytes are the output.
    mutating func write(_ value: Any, old: Any?, source: ClaudeJSONSource?, depth: Int) throws {
        if let old, let source, claudeJSONValuesMatch(old, value) {
            out += original[source.range]
            return
        }
        if let object = value as? [String: Any] {
            let oldObject = old as? [String: Any]
            var members: [(key: String, rawKey: Range<Int>?, source: ClaudeJSONSource?)] = []
            var placed = Set<String>()
            if case .object(let sourced)? = source?.shape {
                for member in sourced where object[member.key] != nil {
                    members.append((member.key, member.rawKey, member.value))
                    placed.insert(member.key)
                }
            }
            for key in object.keys.sorted() where !placed.contains(key) {
                members.append((key, nil, nil))
            }
            guard !members.isEmpty else { out += "{}".utf8; return }
            out.append(UInt8(ascii: "{"))
            for (index, member) in members.enumerated() {
                out += (index == 0 ? "\n" : ",\n").utf8
                pad(depth + 1)
                if let rawKey = member.rawKey { out += original[rawKey] } else { string(member.key) }
                out += ": ".utf8
                try write(object[member.key]!, old: oldObject?[member.key], source: member.source,
                          depth: depth + 1)
            }
            out.append(0x0A)
            pad(depth)
            out.append(UInt8(ascii: "}"))
        } else if let array = value as? [Any] {
            let oldArray = old as? [Any] ?? []
            var sources: [ClaudeJSONSource] = []
            if case .array(let sourced)? = source?.shape { sources = sourced }
            let paired = min(oldArray.count, sources.count)
            guard !array.isEmpty else { out += "[]".utf8; return }
            var used = Set<Int>()
            out.append(UInt8(ascii: "["))
            for (index, element) in array.enumerated() {
                out += (index == 0 ? "\n" : ",\n").utf8
                pad(depth + 1)
                let candidates = [index] + Array(0 ..< paired)
                if let match = candidates.first(where: {
                    $0 < paired && !used.contains($0) && claudeJSONValuesMatch(oldArray[$0], element)
                }) {
                    used.insert(match)
                    out += original[sources[match].range]
                } else {
                    try write(element, old: index < paired ? oldArray[index] : nil,
                              source: index < paired ? sources[index] : nil, depth: depth + 1)
                }
            }
            out.append(0x0A)
            pad(depth)
            out.append(UInt8(ascii: "]"))
        } else {
            try scalar(value)
        }
    }

    private mutating func pad(_ depth: Int) {
        for _ in 0 ..< depth { out += indent }
    }

    private mutating func scalar(_ value: Any) throws {
        if let text = value as? String { string(text); return }
        if value is NSNull { out += "null".utf8; return }
        if let number = value as? NSNumber {
            if claudeJSONIsBool(number) { out += (number.boolValue ? "true" : "false").utf8; return }
            // Checked first: Foundation raises an Objective-C exception, not a Swift error, for NaN
            // and infinity.
            if JSONSerialization.isValidJSONObject([number]),
               let data = try? JSONSerialization.data(withJSONObject: number,
                                                      options: .fragmentsAllowed) {
                out += data
                return
            }
        }
        throw claudeJSONEncodingError()
    }

    /// `JSON.stringify`'s escaping: quote, backslash and control characters only.
    private mutating func string(_ text: String) {
        out.append(UInt8(ascii: "\""))
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\"".utf8
            case "\\": out += "\\\\".utf8
            case "\u{08}": out += "\\b".utf8
            case "\u{0C}": out += "\\f".utf8
            case "\n": out += "\\n".utf8
            case "\r": out += "\\r".utf8
            case "\t": out += "\\t".utf8
            case _ where scalar.value < 0x20:
                out += String(format: "\\u%04x", scalar.value).utf8
            default:
                out += String(scalar).utf8
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}
