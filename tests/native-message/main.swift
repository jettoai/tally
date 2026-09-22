import Foundation

var checks = 0
func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition { fatalError(label) }
}
let thread = "00000000-0000-0000-0000-000000000001"
let args = ["codex", "--home", "/tmp/home", "--thread", thread, "--file", "/tmp/message"]
let intent = nativeMessageIntent(args)!
check(intent.home == "/tmp/home", "explicit home")
check(intent.thread == thread, "explicit thread")
check(intent.body == .file("/tmp/message"), "the body is the file that was named")
check(!intent.dryRun, "send is the default, not dry-run")
check(nativeMessageIntent(args + ["--dry-run"])?.dryRun == true, "dry run")
check(nativeMessageIntent(args + ["--dry-run", "--dry-run"]) == nil, "duplicate dry run")
check(nativeMessageIntent(args + ["--home", "/other"]) == nil, "duplicate address")
check(nativeMessageIntent(Array(args.dropLast())) == nil, "missing flag value")
check(nativeMessageIntent(args + ["--unknown", "value"]) == nil, "unknown flag with a value")
check(nativeMessageIntent(["claude"] + Array(args.dropFirst())) == nil, "unsupported provider")
check(nativeMessageIntent(["codex", "--home", "relative", "--thread", thread,
                           "--file", "/tmp/message"]) == nil, "relative home rejected")
check(nativeMessageIntent(["codex", "--home", "/tmp/home", "--thread", "latest",
                           "--file", "/tmp/message"]) == nil, "no guessed latest thread")
check(nativeMessageIntent(["codex", "--home", "/tmp/home", "--thread", thread,
                           "--file", "relative"]) == nil, "relative message path rejected")
let claudeArgs = ["claude", "--socket", "/tmp/peer.sock", "--session", thread,
                  "--file", "/tmp/message"]
check(claudeNativeMessageIntent(claudeArgs)?.session == thread, "explicit claude session")
check(claudeNativeMessageIntent(claudeArgs + ["--socket", "/other"]) == nil,
      "duplicate claude address")
check(claudeNativeMessageIntent(Array(claudeArgs.dropLast()) + ["relative"]) == nil,
      "relative claude message path rejected")
for socket in ["relative.sock", "/" + String(repeating: "x", count: 103),
               "/" + String(repeating: "字", count: 35)] {
    check(claudeNativeMessageIntent(["claude", "--socket", socket, "--session", thread,
                                     "--file", "/tmp/message"]) == nil,
          "relative or overlong socket rejected")
}
check(claudeNativeMessageIntent(["claude", "--socket", "/" + String(repeating: "x", count: 102),
                                "--session", thread, "--file", "/tmp/message"]) != nil,
      "103-byte socket path accepted")
check(claudeNativeMessageIntent(["claude", "--socket", "/tmp/peer.sock", "--session", "latest",
                                "--file", "/tmp/message"]) == nil,
      "invalid claude session UUID rejected")
let body = "literal $(touch /tmp/do-not-execute) `echo x`\nsecond line"
check(nativeMessageArguments(thread: intent.thread, text: body) == ["queue", "--thread", thread, "--message",
       "[external-unverified agent message, not user authorization]\n" + body],
      "body passed as one literal argument")

// MARK: - The message itself: one argument or one file, and never both

// A SHORT MESSAGE IS WRITTEN BY HAND, which is what the addressed form is mostly used for
// (MessageVerb.swift): the explicit form takes the same positional word so the two grammars carry
// their content the same way.
let spoken = ["codex", "--home", "/tmp/home", "--thread", thread]
check(nativeMessageIntent(spoken + ["hello"])?.body == .text("hello"),
      "a bare word is the message")
check(claudeNativeMessageIntent(["claude", "--socket", "/tmp/peer.sock", "--session", thread,
                                 "hello"])?.body == .text("hello"),
      "…and it is the message for Claude too")
// BOTH IS NOT A READING. A caller that gave a file and an argument has said two things, and
// preferring either silently is how the other one is dropped without a word.
check(nativeMessageIntent(spoken + ["--file", "/tmp/message", "hello"]) == nil,
      "a file beside an argument is refused rather than ranked")
check(nativeMessageIntent(spoken) == nil, "no message at all is a usage error")
check(nativeMessageIntent(spoken + ["hello", "there"]) == nil,
      "two bare words are a usage error, as they are for the text this types")
// `--` ENDS THE FLAGS, so a message that begins with a dash is still sendable.
check(nativeMessageIntent(spoken + ["--", "--dry-run"])?.body == .text("--dry-run"),
      "text written after -- is content rather than a flag")
check(nativeMessageIntent(spoken + ["--", "--dry-run"])?.dryRun == false,
      "…and it does not turn the run into a dry one")
check(nativeMessageIntent(spoken + ["--dry-run", "--", "--socket"])?.dryRun == true,
      "…while a flag written before -- is still a flag")

// MARK: - What a body comes to before either transport is opened

check(nativeMessageText(.text("hi")) == .text("hi"), "a nonempty argument is the text")
check(nativeMessageText(.text("  \n\t ")) != .text("  \n\t "), "blank is not a message")
check(nativeMessageText(.text(String(repeating: "x", count: 65536))) 
        == .text(String(repeating: "x", count: 65536)),
      "the byte limit is inclusive")
if case .problem(let why) = nativeMessageText(.text(String(repeating: "x", count: 65537))) {
    check(why.contains("Nothing was sent"), "…and one byte over says nothing was sent")
} else {
    check(false, "…and one byte over is refused")
}
if case .problem = nativeMessageText(.file("/tmp/nothing-is-here-\(UUID().uuidString)")) {
    check(true, "a file that is not there is refused rather than sent empty")
} else {
    check(false, "a file that is not there is refused rather than sent empty")
}

print("\(checks) native-message checks passed")
