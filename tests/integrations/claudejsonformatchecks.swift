import Foundation

// settings.json written in the file's own layout (ClaudeJSONFormat.swift). Claude Code keeps the file
// the way `JSON.stringify(value, null, 2)` writes it; a rewrite in Foundation's pretty printer
// (sorted keys, `\/`, `"key" : value`, no final newline) showed up as a whole-file diff in the
// dotfiles repository tracking it, for an edit that added one entry. What has to hold: an edit
// changes the lines it changes and no others, and undoing it gives back the original bytes.
@MainActor
func runClaudeJSONFormatChecks(tmp: URL) throws {
    let file = tmp.appendingPathComponent("format-settings.json")
    func read() -> String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }
    func parse(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }
    func render(_ value: [String: Any], _ original: String?) -> String {
        let data = try? claudeJSONData(value, replacing: original.map { Data($0.utf8) })
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "<threw>"
    }

    // F1: not in key order, paths with slashes, two-space indent, final newline, a user hook that
    // stays when ours go, and the two quota knock hooks in their current form, so launch upkeep has
    // exactly one entry (the Chrome-gap hook) to add.
    let f1 = #"""
    {
      "env": {
        "PATH_HINT": "/opt/homebrew/bin:/usr/bin"
      },
      "permissions": {
        "allow": [
          "Bash(ls /tmp/*)",
          "Read(~/workspace/**)"
        ],
        "deny": []
      },
      "hooks": {
        "Stop": [
          {
            "matcher": "",
            "hooks": [
              {
                "type": "command",
                "command": "/Users/me/.claude/hooks/stop.sh"
              }
            ]
          }
        ],
        "UserPromptSubmit": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "/usr/local/bin/tally hook-knock UserPromptSubmit"
              }
            ]
          }
        ],
        "PostToolUse": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "/usr/local/bin/tally hook-knock PostToolUse"
              }
            ]
          }
        ]
      },
      "cleanupPeriodDays": 99999,
      "alwaysThinkingEnabled": true
    }

    """#
    let added = #"""
        "PostToolUseFailure": [
          {
            "hooks": [
              {
                "command": "/usr/local/bin/tally hook-knock PostToolUseFailure",
                "type": "command"
              }
            ],
            "matcher": "mcp__claude-in-chrome__.*"
          }
        ]
    """#
    let tail = "    ]\n  },\n  \"cleanupPeriodDays\""
    let expected = f1.replacingOccurrences(of: tail,
                                           with: "    ],\n\(added)\n  },\n  \"cleanupPeriodDays\"")
    check("format: the fixture's tail is where the new event lands", f1.components(separatedBy: tail).count == 2)

    // T1/T2: launch upkeep over a file carrying the older install adds its one entry and nothing else.
    try f1.write(to: file, atomically: true, encoding: .utf8)
    check("format: the fixture is one launch upkeep would bring up to date",
          IntegrationsStore.knockHookFilesNeedingUpdate([file]) == [file])
    let upkeep = IntegrationsStore.autoUpdateKnockHooks(in: [file])
    check("format: upkeep rewrote the file", upkeep.updated == [file] && upkeep.error == nil)
    let upgraded = read()
    check("format: upkeep changes only the added entry and the comma before it", upgraded == expected)
    let diff = lineDiff(f1, upgraded)
    // A minimal diff is 11/0 (the new block's closing `]` pairs with the old one); git shows 12/1.
    check("format: upkeep diff is the 11 new lines and at most the one comma line (got \(diff.added)/\(diff.removed))",
          diff.added - diff.removed == 11 && diff.removed <= 1)
    check("format: no escaped slashes, no space before colons, final newline kept",
          !upgraded.contains(#"\/"#) && !upgraded.contains("\" : ") && upgraded.hasSuffix("}\n"))

    // T3: a second launch has nothing to do and touches nothing.
    let again = IntegrationsStore.autoUpdateKnockHooks(in: [file])
    check("format: a second upkeep is a no-op byte for byte", again.updated.isEmpty && read() == upgraded)

    // T4: the row's install and uninstall round trip back to the original bytes.
    var f0Object = parse(f1)
    var f0Hooks = f0Object["hooks"] as? [String: Any] ?? [:]
    f0Hooks.removeValue(forKey: "UserPromptSubmit")
    f0Hooks.removeValue(forKey: "PostToolUse")
    f0Object["hooks"] = f0Hooks
    let f0 = render(f0Object, f1)
    check("format: removing members keeps every other line (F0 derived from F1)",
          lineDiff(f1, f0).removed - lineDiff(f1, f0).added == 20 && lineDiff(f1, f0).added <= 1)
    try f0.write(to: file, atomically: true, encoding: .utf8)
    try IntegrationsStore.upsertKnockHooks(in: file)
    check("format: install added the three events", read() != f0 && !read().contains(#"\/"#))
    try IntegrationsStore.removeKnockHooks(in: file)
    check("format: install then uninstall gives back the original bytes", read() == f0)

    // T9: a replaced value (status line) is a local change and its removal restores the file.
    try f1.write(to: file, atomically: true, encoding: .utf8)
    _ = try IntegrationsStore.upsertStatusLine(in: file, command: "/usr/local/bin/tally statusline claude")
    let status = lineDiff(f1, read())
    check("format: status line install is a local diff (got \(status.added)/\(status.removed))",
          status.added <= 5 && status.removed <= 1)
    try IntegrationsStore.removeStatusLine(in: file, command: "/usr/local/bin/tally statusline claude")
    check("format: status line uninstall gives back the original bytes", read() == f1)

    // T6: an unchanged document is its own bytes, whatever the layout.
    let fourSpace = f1.replacingOccurrences(of: "  ", with: "    ")
    let compact = #"{"b":1,"a":{"y":[1,2],"x":"/p"}}"#
    let handWritten = #"""
    {
      "float": 1.0,
      "exp": 1e3,
      "big": 12345678901234567890,
      "accent": "é",
      "slash": "a\/b",
      "flag": true
    }
    """#
    for (name, text) in [("F1", f1), ("four-space", fourSpace), ("compact", compact),
                         ("hand-written", handWritten)] {
        check("format: identity for \(name)", render(parse(text), text) == text)
    }
    // Siblings of a changed key keep their literal spelling.
    var edited = parse(handWritten)
    edited["added"] = "x/y"
    let editedText = render(edited, handWritten)
    check("format: untouched literals survive an edit beside them",
          ["\"float\": 1.0", "\"exp\": 1e3", "\"big\": 12345678901234567890", "\"accent\": \"é\"",
           #""slash": "a\/b""#, "\"added\": \"x/y\""].allSatisfy { editedText.contains($0) })
    check("format: the new key goes at the end of its object",
          editedText.hasSuffix("  \"flag\": true,\n  \"added\": \"x/y\"\n}"))
    var fourEdited = parse(fourSpace)
    fourEdited["zz"] = 1
    check("format: a new key takes the file's own indent",
          render(fourEdited, fourSpace).contains("\n    \"zz\": 1\n}"))
    var compactEdited = parse(compact)
    compactEdited["c"] = 3
    let compactOut = render(compactEdited, compact)
    check("format: a one-line file still round trips its value",
          claudeJSONValuesMatch(parse(compactOut), compactEdited) && compactOut.contains(#""y":[1,2]"#))
    var flagged = parse(handWritten)
    flagged["flag"] = 1
    let flaggedText = render(flagged, handWritten)
    check("format: true changed to 1 is written as 1",
          flaggedText.contains("\"flag\": 1\n") && !flaggedText.contains("\"flag\": true"))

    // T7: duplicate keys give no usable layout; the document is still written, and correctly.
    let duplicate = #"{"a": 1, "a": 2}"#
    var dupValue = parse(duplicate)
    dupValue["b"] = true
    let dupOut = render(dupValue, duplicate)
    check("format: a duplicate-key file is rewritten without a layout, value intact",
          dupOut != "<threw>" && claudeJSONValuesMatch(parse(dupOut), dupValue))

    // T8: no original, or an empty one, is Claude Code's own layout from scratch.
    let fresh: [String: Any] = ["statusLine": ["type": "command", "command": "/usr/local/bin/tally"],
                                "list": [] as [Any], "empty": [:] as [String: Any]]
    for (name, original) in [("nil", nil), ("empty", "")] as [(String, String?)] {
        let out = render(fresh, original)
        check("format: fresh document (\(name) original) in Claude Code's layout",
              out.hasPrefix("{\n  \"") && out.hasSuffix("}\n") && out.contains("\": ")
                  && !out.contains("\" : ") && !out.contains(#"\/"#)
                  && out.contains("\"list\": []") && out.contains("\"empty\": {}"))
    }
}

/// Lines added and removed between two texts, by longest common subsequence (what a line diff
/// counts). The fixtures are small, so the quadratic table is fine.
func lineDiff(_ a: String, _ b: String) -> (added: Int, removed: Int) {
    let x = a.components(separatedBy: "\n"), y = b.components(separatedBy: "\n")
    var table = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
    for i in stride(from: x.count - 1, through: 0, by: -1) {
        for j in stride(from: y.count - 1, through: 0, by: -1) {
            table[i][j] = x[i] == y[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
        }
    }
    let common = table[0][0]
    return (y.count - common, x.count - common)
}
