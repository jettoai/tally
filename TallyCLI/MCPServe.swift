import Foundation

// `tally mcp-serve` - the MCP server behind the native `/tally-account` and `/tally-model` pickers.
//
// WHY A SERVER AT ALL, when both commands are already answered for free by a command-type hook
// (SwitchHook.swift, ModelHook.swift): a command hook can only PRINT. A bare `/tally-account` lists
// the fleet as text and the person then types a second command with a name in it. Claude Code will
// call an MCP tool from the same hook event, and a tool may raise the same native dialog the
// built-in `/mcp` uses - so the same reading becomes a list they answer with the arrow keys, in one
// step, still without waking a model.
//
// The protocol used here is the small corner of MCP that this needs, measured against Claude Code
// 2.1.224 (probe transcripts, 2026-08-07):
//
//   - stdio, one JSON object per LINE (newline-delimited; no Content-Length framing).
//   - `initialize` / `notifications/initialized` / `tools/list` / `tools/call`.
//   - `elicitation/create`, sent BY the server, from inside a `tools/call` it has not answered yet.
//   - the tool's text result is read as a hook decision, so `{"decision":"block","reason":...}`
//     stops the expansion and shows the reason (MCPPicker.swift).
//
// THE ONE STRUCTURAL RULE: while an elicitation is outstanding, the client keeps talking. It sends
// pings, it lists tools, it may notify. A server that read only for its own reply would leave those
// unanswered and both sides would wait for each other, with a dialog open on the user's screen and
// nothing behind it. So the wait re-dispatches everything that is not the reply (`ask` below), which
// is what the probe server had to do before any of this worked.

/// The two ends of one stdio conversation. Injected so the whole round trip - initialize, a tool
/// call, the dialog, the decision - can be driven in a test without a client to talk to.
struct MCPConnection {
    /// One message line, or nil at end of input.
    var read: () -> String?
    var write: (String) -> Void

    /// The real one: stdin and stdout, unbuffered, one line per message.
    static var stdio: MCPConnection {
        MCPConnection(read: { readLine(strippingNewline: true) },
                      write: { line in
                          FileHandle.standardOutput.write(Data((line + "\n").utf8))
                      })
    }
}

/// The protocol version this server speaks when the client does not name one. Claude Code always
/// does, and its value is echoed rather than overridden - a client that asked for an older revision
/// gets told what it asked for, which is what every reference server does.
let mcpProtocolVersion = "2025-11-25"

/// The tools `tools/list` publishes.
///
/// The input schema names the hook's own fields (PromptHookInputField, shared with the app that
/// writes them) and still accepts anything else: the block is composed by a settings file that a
/// future version may add to, and refusing an unknown key would turn that into a broken command.
func mcpToolDescriptors() -> [[String: Any]] {
    let properties = Dictionary(uniqueKeysWithValues: PromptHookInputField.allCases.map {
        ($0.rawValue, ["type": "string"] as Any)
    })
    let schema: [String: Any] = ["type": "object", "properties": properties,
                                 "additionalProperties": true]
    return [
        ["name": PromptHookTool.pickAccount.rawValue,
         "title": "Pick an account",
         "description": "Answers /tally-account: queues the move when one is named, and otherwise "
             + "asks which account this conversation should continue on.",
         "inputSchema": schema],
        ["name": PromptHookTool.pickModel.rawValue,
         "title": "Pick a model",
         "description": "Answers /tally-model: queues the pair when one is named, and otherwise "
             + "asks which model and effort this conversation should run.",
         "inputSchema": schema],
    ]
}

/// The server itself: read a message, answer it, repeat until the client goes away.
///
/// A class because the elicitation counter and the connection are shared by the dispatch and by the
/// nested wait inside it. Single-threaded throughout - one conversation, one reader.
final class MCPServer {
    private let connection: MCPConnection
    private let world: MCPPickerWorld
    private var elicitations = 0
    /// The Claude Code that started this server, recorded while the answer is still true.
    ///
    /// Read at START-UP rather than per request, and that is the whole point: this process outlives
    /// individual prompts, and a Claude Code that exits while it is still running leaves it
    /// reparented to launchd, where `getppid()` answers 1 and would match no session at all. It is
    /// the witness that says which conversation a prompt belongs to (PromptOrigin,
    /// SwitchRequest.swift).
    private let claudeCodePID: pid_t?

    init(connection: MCPConnection, world: MCPPickerWorld = MCPPickerWorld(),
         claudeCodePID: pid_t? = getppid()) {
        self.connection = connection
        self.world = world
        self.claudeCodePID = claudeCodePID
    }

    /// Read until end of input. Returning IS the shutdown: the client closing the pipe is how an
    /// MCP server is stopped, and there is nothing of ours to flush.
    func serve() {
        while let message = receive() { handle(message) }
    }

    /// One message, parsed. A line that is blank or is not an object is SKIPPED rather than
    /// answered: there is no id to answer it with, and a server that gave up on the first stray
    /// byte would take the pickers down with it.
    private func receive() -> [String: Any]? {
        while let line = connection.read() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            return object
        }
        return nil
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: []),
              let line = String(data: data, encoding: .utf8) else { return }
        connection.write(line)
    }

    private func reply(to id: Any?, result: [String: Any]) {
        guard let id else { return }   // a notification: nothing to answer
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func handle(_ message: [String: Any]) {
        let id = message["id"]
        // A response we are not waiting on here: `ask` reads its own reply off the same stream.
        guard let method = message["method"] as? String else { return }
        switch method {
        case "initialize":
            let params = message["params"] as? [String: Any] ?? [:]
            reply(to: id, result: [
                "protocolVersion": params["protocolVersion"] as? String ?? mcpProtocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": tallyMCPServerName,
                               "version": supervisorBuildVersion() ?? "dev"],
            ])
        case "tools/list":
            reply(to: id, result: ["tools": mcpToolDescriptors()])
        case "tools/call":
            call(message)
        case "ping":
            reply(to: id, result: [:])
        // Answered empty rather than left to the error branch: a client that lists these at start-up
        // (Claude Code does) would otherwise log a protocol error on every session. Each key is
        // written out, because the protocol's names for them are not derivable from the methods.
        case "resources/list":
            reply(to: id, result: ["resources": []])
        case "resources/templates/list":
            reply(to: id, result: ["resourceTemplates": []])
        case "prompts/list":
            reply(to: id, result: ["prompts": []])
        default:
            guard let id, !method.hasPrefix("notifications/") else { return }
            send(["jsonrpc": "2.0", "id": id,
                  "error": ["code": -32601, "message": "method not found: \(method)"]])
        }
    }

    /// Run one tool and answer with its decision.
    ///
    /// A tool this server does not have is an ERROR RESULT rather than a JSON-RPC error, because
    /// the two are read differently at the far end: an error result still carries text, so the
    /// prompt is answered rather than falling through to a model turn.
    private func call(_ message: [String: Any]) {
        let params = message["params"] as? [String: Any] ?? [:]
        let input = MCPHookInput(arguments: params["arguments"] as? [String: Any] ?? [:],
                                 claudeCodePID: claudeCodePID)
        let text: String
        switch PromptHookTool(rawValue: params["name"] as? String ?? "") {
        case .pickModel:
            text = mcpPickModel(input: input, world: world, ask: ask)
        case .pickAccount:
            text = mcpPickAccount(input: input, world: world, ask: ask)
        case nil:
            reply(to: message["id"], result: [
                "content": [["type": "text",
                             "text": "tally has no tool called "
                                 + "\(params["name"] as? String ?? "(unnamed)")"]],
                "isError": true,
            ])
            return
        }
        reply(to: message["id"], result: ["content": [["type": "text", "text": text]],
                                          "isError": false])
    }

    /// Raise a dialog and wait for the answer, answering everything else that arrives meanwhile.
    ///
    /// End of input while waiting is a DECLINE, not a crash and not a retry: the client went away,
    /// so nothing was chosen and nothing may be queued on a guess.
    private func ask(_ message: String, _ schema: [String: Any]) -> MCPPickReply {
        elicitations += 1
        let id = "tally-elicit-\(elicitations)"
        send(["jsonrpc": "2.0", "id": id, "method": "elicitation/create",
              "params": ["message": message, "mode": "form", "requestedSchema": schema]])
        while let next = receive() {
            guard next["id"] as? String == id,
                  next["result"] != nil || next["error"] != nil else {
                handle(next)
                continue
            }
            guard let result = next["result"] as? [String: Any],
                  result["action"] as? String == "accept" else { return .declined }
            // Values are read as strings and anything else is dropped: every field this server asks
            // for is an enumerated string, and a client that answered with a number is not
            // describing one of the rows it was given.
            let content = result["content"] as? [String: Any] ?? [:]
            return .accepted(content.compactMapValues { $0 as? String })
        }
        return .declined
    }
}

/// `tally mcp-serve`: the server entry. Registered by the app in each config home's `.claude.json`,
/// never typed by hand, so it is absent from the usage text (the same rule the hook entries follow).
func runMCPServe() -> Int32 {
    MCPServer(connection: .stdio).serve()
    return 0
}
