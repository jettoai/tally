import Foundation

// WHICH object a path names, asked of the kernel rather than worked out from the text.
//
// Everything that shares a harness has one question underneath it: does this path lead to the main
// account's home, or to that home's `agents`, or somewhere else entirely. That question was
// answered by comparing PATHS for a long time, and comparing paths lost four times in three days -
// once per spelling of the same place (a home reached through a symlink, a destination written
// relative, a `..` following a link, an item named `item/.`). Each fix taught the comparison one
// more spelling, and the spelling space of a POSIX pathname is open: there is always another one.
//
// So this file does not compare paths. It asks the filesystem which OBJECT a path arrives at and
// compares that, which is the same question `stat` answers for the kernel when a file is opened.
// Aliases, `..` after a symlink, doubled separators, `/private` against `/var`, a chain of links -
// every one of them is the kernel's own business, and none of them is a rule written here that
// could be written wrong. What is left in the text layer is one component, the LAST one, because
// the links this exists to recognise are allowed to dangle: an item the main account no longer has
// resolves to nothing at all, and a link to it still has to be recognisable as one of ours.
//
// The residual assumption, named rather than pretended away: identity is read one path at a time,
// so a topology rewritten BETWEEN two reads is compared across two states of the machine. Home
// directories on the local disk make that a theoretical concern rather than a practical one, and
// file ids are stable there; a network filesystem is where it would stop being true.

/// The identity of a filesystem OBJECT: the volume it lives on and which file it is there. Two
/// paths naming this same pair are two names for one thing, whatever they look like written down.
struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}

/// The object a path arrives at, or nil when it arrives at none - which is what a path through a
/// missing component, through a file where a directory is required, or to something that is simply
/// not there all report.
///
/// Nil is never equal to nil here, and callers must not treat it as agreement: "cannot be walked"
/// is an absence of an answer, not an answer that two paths lead to one place.
///
/// The symlink at the end is FOLLOWED, which is the whole point (a home reached through an alias is
/// that home). Note that `URLResourceKey.fileResourceIdentifierKey` does NOT follow it and so
/// cannot answer this: measured, it reports the link itself, and an alias of the main home compares
/// unequal to it.
func fileIdentity(atPath path: String) -> FileIdentity? {
    var info = stat()
    guard path.withCString({ stat($0, &info) }) == 0 else { return nil }
    return FileIdentity(device: info.st_dev, inode: info.st_ino)
}

/// Whether two paths name ONE object. False when either cannot be walked, for the reason above.
func pathsAreOne(_ one: URL, _ other: URL) -> Bool {
    guard let first = fileIdentity(atPath: one.path),
          let second = fileIdentity(atPath: other.path) else { return false }
    return first == second
}

/// What a symlink's text CLAIMS, split at the one seam the kernel cannot help with.
///
/// `leadIn` is everything ahead of the last component, walked and identified by the filesystem, so
/// no rule about `..`, symlinks, separators or aliases is written here to be got wrong. `leaf` is
/// the last component exactly as written, because for a dangling link that is the one part nothing
/// can resolve. `slashForm` records that the text asked for the leaf as a DIRECTORY (`item/`,
/// `item/.`, and every stack of those), which is a demand the kernel enforces and therefore part of
/// what the text claims rather than noise to be trimmed away.
struct LinkClaim {
    let leadIn: FileIdentity
    let leaf: String
    let slashForm: Bool
}

/// Reads a link's destination text as the claim it makes, from the directory the link sits in (a
/// relative destination means nothing without it).
///
/// Nil when what leads up to the last component cannot be walked, and it says so rather than
/// guessing: the only place this is ever compared against is a home that DOES exist, so "cannot be
/// walked" and "is not ours" are the same answer, and the safe one.
func linkClaim(ofText text: String, in directory: URL) -> LinkClaim? {
    // The trailing `/` and `/.` are taken off rather than walked, and REMEMBERED rather than
    // discarded: `hooks/.` names the item `hooks` names, so the leaf is `hooks` - but it names it
    // only if `hooks` is a directory, which is the caller's business to know.
    var trimmed = text
    while trimmed.count > 1, trimmed.hasSuffix("/") || trimmed.hasSuffix("/.") {
        trimmed.removeLast(trimmed.hasSuffix("/.") ? 2 : 1)
    }
    let slashForm = trimmed.count != text.count
    if trimmed.isEmpty { trimmed = "/" }   // `/.` is the root directory, not an empty path
    var leaf = trimmed, leadIn = "."
    if let seam = trimmed.lastIndex(of: "/") {
        leaf = String(trimmed[trimmed.index(after: seam)...])
        leadIn = seam == trimmed.startIndex ? "/" : String(trimmed[..<seam])
    }
    // Joined as text rather than through URL, which normalises some of the very spellings this is
    // here to hand over intact (a doubled separator, a `..` that must not be collapsed).
    if !leadIn.hasPrefix("/") { leadIn = directory.path + "/" + leadIn }
    guard let identity = fileIdentity(atPath: leadIn) else { return nil }
    return LinkClaim(leadIn: identity, leaf: leaf, slashForm: slashForm)
}
