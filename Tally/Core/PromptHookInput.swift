import Foundation

// What a prompt hook hands the tool behind it, named ONCE for both sides of the handover.
//
// A `UserPromptExpansion` hook of type `mcp_tool` carries an `input` block: a dictionary the app
// writes into settings.json, whose values are tokens Claude Code substitutes before calling the
// tool (`${command_args}` and friends). The tool then reads them back out by key.
//
// THE TRAP THIS FILE EXISTS FOR, measured 2026-08-07 in the probe that settled the design: a token
// Claude Code does not recognise is substituted with THE EMPTY STRING, silently. It is not left as
// a literal and it is not an error. So `${comand_args}` (one letter short) reaches the tool as
// `command_args: ""` - which is indistinguishable from a user who typed the command with no
// arguments at all. The picker would open instead of queueing, on every invocation, and nothing
// anywhere would say why.
//
// One misspelling is therefore a silent, permanent behaviour change, and the only defence is that
// the two sides cannot drift and the spellings are asserted verbatim (tests/integrations pins the
// literals; tests/supervisor pins the reading). Hence one enumeration, compiled into both targets
// (project.yml), whose raw value IS the key AND the variable name - a pair that cannot disagree
// because there is only one string.
//
// The names themselves are Claude Code's, not this repo's: they are the fields of the hook payload
// the command-type hook already reads off stdin (`hookCommandArguments`, SwitchHook.swift).

/// One variable a prompt hook passes through to its tool.
enum PromptHookInputField: String, CaseIterable, Sendable {
    /// The slash command that fired, without its leading slash ("tally").
    case commandName = "command_name"
    /// Everything typed after the command, VERBATIM: quotes kept, whitespace kept, `$HOME` not
    /// expanded, nothing tokenised. Splitting it is the reader's business, under the same rule the
    /// command-type hook already applies to the same field.
    case commandArgs = "command_args"
    /// Claude Code's own id for the conversation. Carried for diagnostics and as a second witness;
    /// the session a request is addressed to is found from `cwd` (SwitchRequest.swift).
    case sessionID = "session_id"
    /// The directory the prompt was typed in, which is what identifies the session to Tally. The
    /// tool cannot use its own: an MCP server is a long-lived child of Claude Code, spawned once
    /// per session, and nothing about its working directory tracks the prompt.
    case cwd
    /// The transcript file behind the conversation. A third witness, unused today.
    case transcriptPath = "transcript_path"

    /// The token Claude Code substitutes into the hook's `input` block. Derived rather than
    /// declared, so the written token and the key it arrives under are one spelling.
    var variable: String { "${\(rawValue)}" }
}

/// The `input` block a prompt hook carries: every field, each holding its own substitution token.
/// What the app writes into settings.json, and the shape a test can compare verbatim.
func promptHookInputBlock() -> [String: String] {
    Dictionary(uniqueKeysWithValues: PromptHookInputField.allCases.map { ($0.rawValue, $0.variable) })
}

/// The MCP server Tally registers in each config home, under the name the hooks call it by.
///
/// Here for the same reason as the fields above: the app writes this string into `.claude.json` AND
/// into every hook entry, the CLI answers to it, and a drifted pair is a hook that calls a server
/// that does not exist - which Claude Code reports by letting the expansion through, so the symptom
/// is a model turn rather than an error.
let tallyMCPServerName = "tally"

/// The tools that server offers.
///
/// ONE COMMAND, THREE TOOLS, and the two that are not called any more are the compatibility surface
/// rather than an oversight. `/tally` calls `pick`; `pick_account` and `pick_model` answered the two
/// commands it replaced, and they stay because a registration written by an older app is still in
/// somebody's settings.json until the self-heal rewrites it (IntegrationsSelfHeal.swift), and a tool
/// hook naming a tool this server does not have is answered with an error the expansion then walks
/// straight past - which costs the model turn the hook exists to save.
enum PromptHookTool: String, CaseIterable, Sendable {
    /// The merged picker: both axes on one panel, and the typed forms of both commands.
    case pick
    case pickAccount = "pick_account"
    case pickModel = "pick_model"
}

/// The subcommand that runs the server, as the registration writes it and as the backstop looks for
/// it in the process table (PromptHookBackstop.swift). One spelling, three readers.
let mcpServeCommand = "mcp-serve"

/// The flag that turns a prompt hook into the BACKSTOP beside the tool call: it answers only when
/// the tool cannot (PromptHookBackstop.swift states the judgement). Written by the app into the
/// hook's command line and read by the CLI that runs it, so it lives with the rest of the contract.
let promptHookBackstopFlag = "--backstop"
