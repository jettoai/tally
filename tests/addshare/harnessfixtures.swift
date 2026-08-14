import Foundation

// The account shapes both halves of the "share an account that already exists" suite build on:
// shareexistingchecks.swift (what a share MOVES, merges and renames aside) and unlinkchecks.swift
// (what a `--no-share` or a Remove takes back afterwards).
//
// One copy on purpose. These two files assert about the same machine from opposite ends, so a main
// account with one shape on one side and another shape on the other would have them agreeing about
// nothing in particular - and a fixture builder is exactly the kind of thing that gets pasted into
// the second file and then edited in only one of them.

private let fixtureFileManager = FileManager.default

func writeFixture(_ text: String, _ url: URL) {
    try? fixtureFileManager.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
}

func readFixture(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

func fixtureHome(_ name: String, in root: URL) -> URL {
    let url = root.appendingPathComponent(name)
    try? fixtureFileManager.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A main account with one of everything the rule distinguishes: two documents, one tree of
/// documents, two accumulating directories, and a credential that is on no share list at all.
func fixtureMainAccount(_ name: String, in root: URL) -> URL {
    let main = fixtureHome(name, in: root)
    writeFixture("main rules", main.appendingPathComponent("CLAUDE.md"))
    writeFixture("{}", main.appendingPathComponent("settings.json"))
    writeFixture("main skill", main.appendingPathComponent("skills/demo/SKILL.md"))
    writeFixture("main index", main.appendingPathComponent("memory/MEMORY.md"))
    writeFixture("main one", main.appendingPathComponent("projects/proj-a/one.jsonl"))
    writeFixture("main note", main.appendingPathComponent("inboxes/tally/note.md"))
    writeFixture("secret", main.appendingPathComponent(".credentials.json"))
    return main
}
