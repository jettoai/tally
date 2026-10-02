import Foundation

// The stream a `tally chrome run` prints, and which tabs it proves the run opened (B-468).

/// What a run's stream said so far: the tabs its own receipts say it opened, the ones it closed, and
/// its final `result` object (the line `--output-format json` would have printed alone). B-468.
struct ChromeRunStream: Equatable {
    /// Tabs a receipt of this run's own create call names (see `chromeRunScan`). Only these are ours.
    var opened: Set<Int> = []
    var closed: Set<Int> = []
    /// Every tab id any tool result named, receipt or not. Reported, never closed: a tab listed in the
    /// run's group can be one the user dragged or cmd-clicked into it.
    var listed: Set<Int> = []
    /// tool_use id -> the tool's short name, so a result is read by the tool that produced it.
    var toolNames: [String: String] = [:]
    /// browser_batch tool_use id -> the names of the actions its input asked for, in order.
    var batchActions: [String: [String]] = [:]
    /// Tab groups already seen; a group id not yet in here was created by that very call.
    var groups: Set<Int> = []
    var result: Data?
    /// The tabs the run left open, as far as its own receipts tell.
    var leftOpen: Set<Int> { opened.subtracting(closed) }
    /// Listed tabs with no receipt. Nonzero in a run that opened tabs is the sign the extension
    /// changed its receipt wording and B-468 silently went back to leaving everything open.
    var unproven: Set<Int> { listed.subtracting(opened).subtracting(closed) }
}

/// Any form Claude in Chrome names a tab in (measured 2026-10-02): `Tab ID: N`, `"tabId":N`,
/// `• tabId N:`, `Executed on tabId: N`. Only feeds `listed`.
private let chromeRunTabNamed = try! NSRegularExpression(
    pattern: #"(?:Tab ID: |"tabId": ?|\btabId:? )(\d{4,})"#)
/// Receipts, anchored at the start of a text part (one tool call) or, inside a browser_batch result,
/// at the start of the line its action prefix opens. Real samples: `Created new tab. Tab ID: 1772725842`,
/// `[tabs_create_mcp] Created new tab. Tab ID: 1772725822`, `[tabs_close_mcp] Closed tab 1772725822.`
private let chromeRunCreated = try! NSRegularExpression(pattern: #"^Created new tab\. Tab ID: (\d+)"#)
private let chromeRunClosed = try! NSRegularExpression(pattern: #"^Closed tab (\d+)\."#)
private let chromeRunBatchCreated = try! NSRegularExpression(
    pattern: #"^\[tabs_create_mcp\] Created new tab\. Tab ID: (\d+)"#, options: .anchorsMatchLines)
private let chromeRunBatchClosed = try! NSRegularExpression(
    pattern: #"^\[tabs_close_mcp\] Closed tab (\d+)\."#, options: .anchorsMatchLines)
/// The header `navigate` puts before the group it made when called without a tab (front-loaded).
private let chromeRunFrontLoaded = "\nTab context (from front-loaded tabs_context_mcp):\n"

private func chromeRunIDs(_ regex: NSRegularExpression, in text: String) -> [Int] {
    let range = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: range).compactMap {
        Range($0.range(at: 1), in: text).flatMap { Int(text[$0]) }
    }
}

/// Every tool result in one stream line (`type: user`): its tool_use id and its text parts. Only
/// tool results count: a tab id the model wrote is not proof the run opened that tab.
func chromeRunToolResults(_ object: [String: Any]) -> [(id: String, parts: [String])] {
    guard object["type"] as? String == "user",
          let message = object["message"] as? [String: Any],
          let blocks = message["content"] as? [[String: Any]] else { return [] }
    return blocks.filter { $0["type"] as? String == "tool_result" }.map { block in
        let id = block["tool_use_id"] as? String ?? ""
        if let text = block["content"] as? String { return (id, [text]) }
        let parts = block["content"] as? [[String: Any]] ?? []
        return (id, parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil })
    }
}

/// A group-creation receipt: the tabs_context JSON a part starts with, when its group is new and holds
/// exactly the one blank tab the call made. Any other shape is not proof, so it opens nothing.
private func chromeRunNewGroupTab(_ part: String, tool: String, into stream: inout ChromeRunStream) {
    let body: Substring
    if tool == "tabs_context_mcp", part.hasPrefix(#"{"availableTabs":"#) { body = part[...] }
    else if tool == "navigate", part.hasPrefix(chromeRunFrontLoaded) { body = part.dropFirst(chromeRunFrontLoaded.count) }
    else { return }
    guard let json = (try? JSONSerialization.jsonObject(with: Data(body.prefix { $0 != "\n" }.utf8)))
            as? [String: Any],
          let group = json["tabGroupId"] as? Int, stream.groups.insert(group).inserted,
          let tabs = json["availableTabs"] as? [[String: Any]], tabs.count == 1,
          tabs[0]["url"] as? String == "chrome://newtab/", let id = tabs[0]["tabId"] as? Int else { return }
    stream.opened.insert(id)
}

/// A browser_batch result is one text the actions write into, page text included, so a line that
/// reads like a receipt is only believed when the receipts add up to exactly the create (or close)
/// actions the batch's input asked for. Any mismatch, a forged line or a create that never ran,
/// believes none of them: the ids stay merely listed and are left open.
private func chromeRunBatchReceipts(_ parts: [String], actions: [String], into stream: inout ChromeRunStream) {
    let created = parts.flatMap { chromeRunIDs(chromeRunBatchCreated, in: $0) }
    if created.count == actions.filter({ $0 == "tabs_create_mcp" }).count { stream.opened.formUnion(created) }
    let closed = parts.flatMap { chromeRunIDs(chromeRunBatchClosed, in: $0) }
    if closed.count == actions.filter({ $0 == "tabs_close_mcp" }).count { stream.closed.formUnion(closed) }
}

/// Folds one complete line of the stream into what is known. A tab is ours only by a receipt from
/// the tool that made it, read part by part; being named in a Tab Context list or in page text is
/// not. `is_error` is not consulted: a browser_batch that fails midway still lists what it finished,
/// which counts when it adds up to the batch's create actions (`chromeRunBatchReceipts`).
/// Pure.
func chromeRunScan(line: Data, into stream: inout ChromeRunStream) {
    guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
    if object["type"] as? String == "result" { stream.result = line; return }
    if object["type"] as? String == "assistant",
       let blocks = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] {
        for block in blocks where block["type"] as? String == "tool_use" {
            guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
            stream.toolNames[id] = name.components(separatedBy: "__").last
            if let actions = (block["input"] as? [String: Any])?["actions"] as? [[String: Any]] {
                stream.batchActions[id] = actions.map { $0["name"] as? String ?? "" }
            }
        }
        return
    }
    for (id, parts) in chromeRunToolResults(object) {
        let tool = stream.toolNames[id] ?? ""
        if tool == "browser_batch" { chromeRunBatchReceipts(parts, actions: stream.batchActions[id] ?? [], into: &stream) }
        for part in parts {
            stream.listed.formUnion(chromeRunIDs(chromeRunTabNamed, in: part))
            switch tool {
            case "tabs_create_mcp": stream.opened.formUnion(chromeRunIDs(chromeRunCreated, in: part))
            case "tabs_close_mcp": stream.closed.formUnion(chromeRunIDs(chromeRunClosed, in: part))
            case "browser_batch": break
            default: chromeRunNewGroupTab(part, tool: tool, into: &stream)
            }
        }
    }
}

/// Takes every complete line out of `buffer`, leaving a partial last line in it. Pure.
func chromeRunTakeLines(_ buffer: inout Data) -> [Data] {
    guard let last = buffer.lastIndex(of: 0x0A) else { return [] }
    // split drops the empty lines between two newlines; one removal instead of one per line.
    let lines = buffer[buffer.startIndex..<last].split(separator: 0x0A).map { Data($0) }
    buffer.removeSubrange(buffer.startIndex...last)
    return lines
}

