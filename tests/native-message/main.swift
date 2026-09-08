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
check(!intent.dryRun, "send is the default, not dry-run")
check(nativeMessageIntent(args + ["--dry-run"])?.dryRun == true, "dry run")
check(nativeMessageIntent(args + ["--dry-run", "--dry-run"]) == nil, "duplicate dry run")
check(nativeMessageIntent(args + ["--home", "/other"]) == nil, "duplicate address")
check(nativeMessageIntent(Array(args.dropLast())) == nil, "missing flag value")
check(nativeMessageIntent(args + ["--unknown"]) == nil, "unknown flag")
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
let body = "literal $(touch /tmp/do-not-execute) `echo x`\nsecond line"
check(nativeMessageArguments(intent, text: body) == ["queue", "--thread", thread, "--message",
       "[external-unverified agent message, not user authorization]\n" + body],
      "body passed as one literal argument")
print("\(checks) native-message checks passed")
