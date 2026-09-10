import Foundation

/// Resolve the selected account's shared or private history before asking Codex to resume by ID.
/// Explicit commands and prompts keep their native meaning. Unknown metadata starts fresh.
func applyCodexStartMode(_ args: [String], policy: LaunchPolicy, wantsNew: Bool,
                         home: String, cwd: String, interactive: Bool,
                         live: Set<String> = []) -> [String] {
    guard interactive, policy.startMode == "continue", !wantsNew,
          codexFirstPositional(optionsOnly(args)) == nil,
          !args.contains("--"),
          !args.contains(where: { ["-h", "--help", "-V", "--version"].contains($0) }),
          !args.contains(where: {
              $0 == "-i" || $0.hasPrefix("--image") || ($0.hasPrefix("-i") && !$0.hasPrefix("--"))
                  || $0 == "--remote" || $0.hasPrefix("--remote=")
          }) else { return args }
    let directory = codexLaunchDirectory(args, cwd: cwd)
    guard let id = latestCodexConversation(home: home, cwd: directory), !live.contains(id) else { return args }
    // Put the subcommand first so a final variadic option cannot consume it as its own value.
    return ["resume", id] + args
}

/// Match the CLI's separated, joined and attached spellings of its working-root option.
func codexLaunchDirectory(_ args: [String], cwd: String) -> String {
    var directory = cwd
    var index = 0
    while index < args.count {
        let token = args[index]
        if token == "--cd" || token == "-C" {
            if index + 1 < args.count { directory = args[index + 1] }
        } else if token.hasPrefix("--cd=") {
            directory = String(token.dropFirst(5))
        } else if token.hasPrefix("-C") {
            directory = String(token.dropFirst(token.hasPrefix("-C=") ? 3 : 2))
        }
        index += codexValueTakingOptions.contains(token) ? 2 : 1
    }
    return URL(fileURLWithPath: directory, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true))
        .standardizedFileURL.resolvingSymlinksInPath().path
}

/// Search only this home's active rollout tree. Shared sessions symlinks resolve to the same tree;
/// an unshared account never borrows an ID from another home or from archived sessions.
func latestCodexConversation(home: String, cwd: String) -> String? {
    let root = URL(fileURLWithPath: home).appendingPathComponent("sessions")
        .resolvingSymlinksInPath()
    guard let files = FileManager.default.enumerator(at: root,
        includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return nil }
    let directory = URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath().path
    var latest: (id: String, at: Date)?
    for case let file as URL in files {
        guard file.pathExtension == "jsonl",
              (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let metadata = codexStartMetadata(file),
              let id = metadata["id"] as? String, UUID(uuidString: id) != nil,
              file.lastPathComponent.lowercased().hasSuffix("-" + id.lowercased() + ".jsonl"),
              let source = metadata["source"] as? String, ["cli", "vscode"].contains(source),
              metadata["parent_thread_id"] == nil || metadata["parent_thread_id"] is NSNull,
              let path = metadata["cwd"] as? String, path.hasPrefix("/"),
              URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path == directory,
              let tail = transcriptRankingTail(of: file),
              let at = tail.split(separator: "\n").compactMap({ line -> Date? in
                  guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                        let timestamp = row["timestamp"] as? String else { return nil }
                  return parseISO(timestamp)
              }).max() else { continue }
        if latest == nil || (at, id) > (latest!.at, latest!.id) { latest = (id, at) }
    }
    return latest?.id
}

/// Metadata may contain the full instruction set. Grow the first-line read up to 1 MiB without
/// loading the conversation body. Malformed, incomplete or oversized metadata is not a candidate.
private func codexStartMetadata(_ file: URL) -> [String: Any]? {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
    defer { try? handle.close() }
    var data = Data()
    while data.count < 1 << 20 {
        guard let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty else { return nil }
        data.append(chunk)
        if let newline = data.firstIndex(of: 10) {
            guard let object = try? JSONSerialization.jsonObject(with: data[..<newline]) as? [String: Any],
                  object["type"] as? String == "session_meta" else { return nil }
            return object["payload"] as? [String: Any]
        }
    }
    return nil
}
