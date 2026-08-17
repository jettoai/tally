import Foundation

// WHAT A CLEARED WINDOW'S OWN TRANSCRIPT SAYS ABOUT IT: the reading behind the free move next door
// (WindowRepick.swift), split out when that file reached this repo's size cap.
//
// The seam is the one the readers already draw. Everything here answers a question about a FILE - is
// there a turn in it, when was it last written, can it be read at all - and knows nothing about
// arming, landing, accounts or relaunches. Everything there decides what to do with the answer.
// `TranscriptWatcher` and `SessionQuiet` are split on the same line for the same reason.

/// What the cleared conversation's own transcript says about the window this move rests on.
enum WindowRepickWindow: Equatable {
    /// A turn is in it: a prompt somebody typed, a tool result, an answer. The window is in use.
    case used
    /// Nothing in it but the records the `/clear` itself wrote, as of this write.
    case empty(writtenAt: Date)
    /// Nothing could be read: no file, no stat, no tail. Decides neither way.
    case unreadable
}

/// That reading, off the file the watcher is bound to.
///
/// Fresh URL for the mtime, for the reason `boundFileQuietness` states: resourceValues are cached
/// per URL instance, and a held one would report a window that has been typed into as untouched.
///
/// A TRANSCRIPT TOO BIG FOR THE TAIL IS A WINDOW THAT HAS BEEN USED, which is a verdict rather than
/// a shrug. `transcriptTail` reads the last `openTurnTailBytes` and drops the partial line the
/// window opens on, so a first prompt that is ONE line larger than that window takes itself out of
/// view and leaves nothing behind but the `attachment` / `last-prompt` / `mode` records written
/// after it, which read as an empty window (codex review of 1db9ebf; this machine's corpus holds
/// typed prompts of 344 KB and 519 KB, both carrying `imagePasteIds`, and 13 windows blinded by
/// exactly this). `.unreadable` would be the wrong answer as well as a weaker one: a cleared window
/// whose transcript has grown past a quarter of a megabyte is not ambiguous, it is a window
/// somebody has put a quarter of a megabyte into. The fresh ones measured here are 8 to 17 KB.
func clearedWindow(of file: URL?) -> WindowRepickWindow {
    guard let file,
          let values = try? URL(fileURLWithPath: file.path)
              .resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
          let modified = values.contentModificationDate else { return .unreadable }
    if let size = values.fileSize, size > openTurnTailBytes { return .used }
    guard let tail = transcriptTail(of: file) else { return .unreadable }
    return windowRepickUsed(inTail: tail) ? .used : .empty(writtenAt: modified)
}

/// The two records a `/clear` writes into the transcript it creates, which are the ONLY two this
/// reader forgives: the invocation itself, and the caveat beside it. Anything else in that window
/// is somebody using it.
let windowClearCommandRecord = "<command-name>/clear</command-name>"
let windowClearCaveatRecord = "<local-command-caveat>"

/// Whether this event is that caveat: a meta expansion whose content opens with the tag.
///
/// THE STRUCTURE RATHER THAN THE FLAG, which is the whole correction here (codex review of 1db9ebf,
/// with a corpus count of my own beside it). Forgiving every `isMeta` user event forgives the wrong
/// family: Claude Code opens real turns with them. Counted on this machine 2026-08-17, over 1,000
/// transcripts, 1,963 turns whose opening user event was `isMeta` and nothing else, 311 of them
/// carrying `promptSource:"system"` - a SessionStart injection waking the session up - and in 83
/// cleared windows that was the FIRST turn of the window. One of them with the clock on it:
/// `fc9f8cdd`, meta user event at 06:40:30.912, first assistant event 6.1s later, which is past
/// the 5s quiet bar with the arm still up.
private func isWindowClearCaveat(_ object: [String: Any]) -> Bool {
    guard object["isMeta"] as? Bool == true,
          let content = (object["message"] as? [String: Any])?["content"] as? String
    else { return false }
    return content.trimmingCharacters(in: .whitespacesAndNewlines)
        .hasPrefix(windowClearCaveatRecord)
}

/// Whether this tail shows the window has been used, rather than holding only what the `/clear`
/// left behind.
///
/// WHAT A CLEARED TRANSCRIPT ACTUALLY CONTAINS had to be measured rather than assumed, and the
/// obvious rule ("any main-chain user or assistant event means it was used") is refuted by it: the
/// `/clear` writes its OWN invocation into the file it creates, as a main-chain `user` event, next
/// to a `<local-command-caveat>` meta record - so that rule reads every fresh window as used and
/// turns this feature off entirely. Read off this machine's corpus 2026-08-17, 208 transcripts a
/// `/clear` created: the fresh ones hold `mode`, `file-history-snapshot`, `attachment`, that caveat,
/// the invocation, a `system subtype=local_command` and `last-prompt` / `queue-operation`, and no
/// assistant event anywhere.
///
/// NOT `newestMainChainMessage` NEXT DOOR, which walks the same tail for a different question. That
/// one asks WHEN the newest message was written, to compare against a turn-end boundary, and every
/// main-chain message counts because any of them can be newer than that boundary. This one asks
/// whether a window has anything in it at all, where the records the `/clear` itself wrote are the
/// baseline rather than content - so the two cannot share a walk without one of them lying.
///
/// `isMeta` IS WHERE THAT DIFFERENCE BITES, and the two readers point opposite ways on it ON
/// PURPOSE. There it is counted, and that is what stops a Stop attempt another hook BLOCKED from
/// reading as a finished turn: Claude Code writes the block reason as a main-chain `isMeta` user
/// event (1,908 such records across 189 transcripts here). Here it is forgiven, but only for the
/// one structure the `/clear` itself writes, because meta events open real turns as well. NEITHER
/// SIDE MAY BE "MADE CONSISTENT" WITH THE OTHER: making this one count every meta event turns the
/// feature off (the caveat is in every cleared window), and making that one skip them opens the
/// blocked-Stop hole. Each is load-bearing where it stands, which is why both say so.
///
/// SKIPPING A RECORD IS THE UNSAFE DIRECTION HERE, which is why the forgiveness is a whitelist of
/// two structures rather than a family: a record passed over lets a live turn read as an empty
/// window, and the cost of counting one it need not have is a free move declined.
///
/// MEASURED AT THE MOMENT THIS IS ASKED, which is the reading that counts and the one the previous
/// number in this comment did not use. The repick asks while a window is still supposed to be
/// empty, so every window below is judged against the bytes that existed BEFORE its first
/// main-chain assistant event. Judged against the FINISHED transcript instead - which is what the
/// "198 of 198" written here before was - the answer is trivially `used` for anything that was ever
/// worked in, and the same corpus that scores 193 here scored 97 at the moment that matters.
///
/// Corpus of 1,000 transcripts on this machine, 2026-08-17, 209 windows a `/clear` opened:
///  - 199 were then worked in. This answers `used` for 193 of them at ask time.
///  - the 6 it still reads as empty are one class: no user record of ANY kind between the clear and
///    the first assistant event. Their clear-to-turn gaps run from 135s to three days, every one of
///    them past the 60s window, so the arm has expired before the question is asked. Named rather
///    than hidden: it is the residue, and it is out of reach rather than covered.
///  - 10 were never worked in. This answers `empty` for 9, and `used` for the one whose owner ran a
///    `/model` in the window, which is the safe direction rather than a miss.
///
/// The `type` that decides is the parsed one and the content is read through `lineIsCommandRecord`,
/// because an attachment can carry another event's JSON inside it and a prompt can quote one. A line
/// that CLAIMS to be one of the two types and will not parse counts as use for the same reason: the
/// last line of a tail may be half written, and half an object is not evidence of an empty window.
func windowRepickUsed(inTail tail: String) -> Bool {
    for line in tail.split(separator: "\n").reversed() {
        guard line.contains("\"type\":\"assistant\"") || line.contains("\"type\":\"user\"")
        else { continue }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                  as? [String: Any],
              let type = object["type"] as? String, type == "assistant" || type == "user"
        else { return true }
        // The caveat the clear wrote, and the invocation that opened the window. Two structures,
        // not two families: every other meta expansion counts, because Claude Code opens turns with
        // them (`isWindowClearCaveat`).
        if type == "user", isWindowClearCaveat(object)
            || lineIsCommandRecord(line, opening: windowClearCommandRecord) { continue }
        return true
    }
    return false
}
