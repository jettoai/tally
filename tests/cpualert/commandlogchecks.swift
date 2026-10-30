import Foundation

// The command-line record (Tally/Core/CPUAlertCommandLog.swift): the masker, the argument-vector
// reader, the parent chain, the line format, the 0600 file and its rotation. Uses main.swift's
// `expect`, `L` and `t0`.

func runCommandLogChecks() {
    let home = "/Users/a"
    func mask(_ args: [String]) -> String { CPUAlertCommandMask.mask(arguments: args, home: home) }
    let hex64 = "094809342edbfad14d6c54f4e4cfca889f1c65063eb50fb83a8b6b7098f5e16d"

    // M1 the real argument: a flag naming an audience, then a 64-digit hex
    let anchor = mask(["pm-board.py", "--port", "3190", "--access-aud", hex64, "--worker-fd", "3"])
    expect(!anchor.contains(hex64) && anchor.contains("--access-aud <redacted>") && anchor.contains("--port 3190"),
           "M1 the sample's access-aud value is gone and its port stays")
    expect(!mask(["x", "--access-aud=\(hex64)"]).contains(hex64), "M1 the --flag=value form is masked too")
    // a secret with no flag name to give it away: only the shape (rule 6) can catch it
    expect(!mask(["curl", hex64]).contains(hex64) && mask(["curl", hex64]).contains("<redacted:64>"),
           "M1 a bare 64-digit hex is masked by its shape")

    // M2 variable assignments and flag names
    expect(mask(["env", "TOKEN=abc123", "node"]).contains("TOKEN=<redacted>") && !mask(["env", "TOKEN=abc123"]).contains("abc123"),
           "M2 a TOKEN= assignment is masked")
    expect(mask(["x", "--api-key=abc123"]) == "x --api-key=<redacted>", "M2 --api-key=value is masked")
    expect(mask(["x", "--password", "hunter2", "--port", "1"]) == "x --password <redacted> --port 1",
           "M2 the value after a sensitive flag is masked, the next flag is not")
    expect(mask(["x", "--no-auth", "--port", "1"]) == "x --no-auth --port 1", "M2 a flag followed by a flag takes nothing")
    expect(mask(["docker", "run", "-e", "OPENAI_API_KEY=zzz", "img"]).contains("OPENAI_API_KEY=<redacted>"),
           "M2 -e NAME=value is masked")

    // M3 token shapes and URLs
    let ant = "sk-ant-api03-AAAAAAAAAAAAAAAAAAAA"
    let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTYifQ.abc"
    let masked3 = mask(["x", ant, "ghp_abcdefghijklmnop", jwt, "AKIAABCDEFGHIJKLMNOP", "xoxb-1234-abcd-efgh"])
    expect(!masked3.contains("sk-ant") && !masked3.contains("ghp_") && !masked3.contains("eyJ")
           && !masked3.contains("AKIA") && !masked3.contains("xoxb"), "M3 known token shapes are masked")
    expect(mask(["curl", "https://user:pw@host/x"]) == "curl https://<redacted>@host/x", "M3 URL userinfo is masked")
    expect(mask(["curl", "https://h/x?token=abc&page=2"]) == "curl https://h/x?token=<redacted>&page=2",
           "M3 a sensitive query parameter is masked, the others stay")

    // M4 what must survive: a session id, a path
    let uuid = "5e4da23d-3f28-4ebf-bcc6-b34c9a1d2e3f"
    expect(mask(["claude", "--resume", uuid]) == "claude --resume \(uuid)", "M4 a UUID is kept")
    let longPath = "/Users/a/workspace/some/very/long/directory/name/with/many/parts/file123.txt"
    expect(mask(["cat", longPath]) == "cat ~" + longPath.dropFirst("/Users/a".count), "M4 a path is kept (home to ~)")

    // M4b a secret inside a script argument, the form a coding agent starts commands in
    let script = mask(["/bin/zsh", "-c", "export OPENAI_API_KEY=sk_live_abc; PORT=3000 node x.js --api-key hunter2 "
                       + "--token=\"t 0k\" -H 'Authorization: Bearer zzz' --port 80"])
    expect(!script.contains("sk_live_abc") && !script.contains("hunter2") && !script.contains("t 0k")
           && !script.contains("zzz") && script.contains("PORT=3000") && script.contains("--port 80"),
           "M4b secrets inside a shell script argument are masked, ordinary settings stay")

    // M4c an Authorization header keeps its scheme word and loses the credential, as one argument
    // and inside a shell string
    for (header, expected) in [("Authorization: Basic dXNlcjpwdw", "Authorization: Basic <redacted>"),
                               ("Authorization: Token abc123xyz", "Authorization: Token <redacted>"),
                               ("Proxy-Authorization: Basic dXNlcjpwdw", "Proxy-Authorization: Basic <redacted>"),
                               ("Authorization:Basic dXNlcjpwdw", "Authorization:Basic <redacted>")] {
        let credential = String(header.split(separator: " ").last ?? "")
        for (form, masked) in [("argv", mask(["curl", "-H", header])),
                               ("shell", mask(["/bin/zsh", "-c", "curl -s -H \"\(header)\" https://h/x"]))] {
            expect(!masked.contains(credential) && masked.contains(expected), "M4c \(form) form: \(header)")
        }
    }

    // M5 home
    expect(mask(["ls", "/Users/a/x"]) == "ls ~/x", "M5 the home directory is ~")

    // M6 only the argument vector, never the environment that follows it in the buffer
    func procargs(_ path: String, argv: [String], env: [String]) -> Data {
        var data = withUnsafeBytes(of: Int32(argv.count)) { Data($0) }
        data.append(contentsOf: Array(path.utf8) + [0, 0, 0])
        for field in argv + env { data.append(contentsOf: Array(field.utf8) + [0]) }
        return data
    }
    let buffer = procargs("/bin/zsh", argv: ["zsh", "-c"], env: ["SECRET=xyz", "PATH=/usr/bin"])
    let args = CPUAlertCommandMask.arguments(procargs: buffer)
    expect(args == ["zsh", "-c"] && !(args ?? []).joined().contains("xyz"), "M6 the environment block is never returned")
    expect(CPUAlertCommandMask.arguments(procargs: procargs("/bin/x", argv: [], env: ["A=1"])) == []
           && CPUAlertCommandMask.arguments(procargs: Data([1, 0])) == nil
           && CPUAlertCommandMask.arguments(procargs: procargs("/bin/x", argv: ["a", "b", "c"], env: []).dropLast(4)) == nil,
           "M6 an empty vector, a short buffer and a truncated one do not crash")

    // M7 one line whatever the argument holds
    let multi = mask(["echo", "a\nb\r\nc\td\u{1B}[31m", "x y", ""])
    expect(!multi.contains("\n") && !multi.contains("\r") && !multi.contains("\u{1B}") && multi.contains("\"x y\"")
           && multi.hasSuffix("\"\""), "M7 control characters are gone, spaces and empties quoted")

    // the shell command an ancestor was asked to run
    expect(CPUAlertCommandMask.shellCommand(in: ["/bin/zsh", "-c", "-l", "npx playwright test"]) == "npx playwright test"
           && CPUAlertCommandMask.shellCommand(in: ["bash", "-lc", "pnpm e2e"]) == "pnpm e2e"
           && CPUAlertCommandMask.shellCommand(in: ["node", "-c", "x"]) == nil
           && CPUAlertCommandMask.shellCommand(in: ["zsh", "--no-rcs"]) == nil,
           "C1 a shell's -c command is found, a non-shell or a shell with no -c is not")

    // C2 the parent chain
    let parents: [Int32: Int32] = [38090: 1200, 1200: 1180, 1180: 900, 900: 1, 1: 0]
    let names: [Int32: String] = [38090: "Python", 1200: "zsh", 1180: "claude", 900: "tally", 1: "launchd"]
    expect(CPUAlertCommandLog.chain(of: 38090, parent: { parents[$0] }, name: { names[$0] })
           == "38090:Python<1200:zsh<1180:claude", "C2 the chain stops at the Claude Code session root")
    var noClaude = names; noClaude[1180] = "node"
    expect(CPUAlertCommandLog.chain(of: 38090, parent: { parents[$0] }, name: { noClaude[$0] })
           == "38090:Python<1200:zsh<1180:node<900:tally<1:launchd", "C2 otherwise it runs to launchd")
    expect(CPUAlertCommandLog.chain(of: 38090, parent: { parents[$0] }, name: { $0 == 1180 ? nil : names[$0] })
           == "38090:Python<1200:zsh<1180:?", "C2 an unreadable level ends the chain as pid:?")
    expect(CPUAlertCommandLog.chain(of: 5, parent: { _ in 6 }, name: { _ in "x" }, limit: 4).split(separator: "<").count == 2,
           "C2 a parent cycle ends")

    // L1 the block: one header and at most five records, argv last
    func record(_ rank: Int) -> CPUAlertCommandRecord {
        CPUAlertCommandRecord(rank: rank, pid: Int32(100 + rank), share: 12.4, group: "baton", category: "command",
                              chain: "1:launchd", origin: "npx \"x\"", argv: "python a.py")
    }
    let block = CPUAlertCommandLog.block(.alarm(silence: nil), busy: 95, cores: 16,
                                         records: (1...9).map(record), now: t0)
    let lines = block.split(separator: "\n")
    expect(lines.count == 6 && block.hasSuffix("\n"), "L1 a banner writes six lines at most (header and five)")
    expect(lines[0].contains("cpu-alert-cmd=alarm cpu=95 cores=16 records=9"), "L1 the header")
    expect(lines[1].contains("rank=1 pid=101 cpu=12 group=baton cat=command chain=1:launchd origin=\"npx \\\"x\\\"\"")
           && lines[1].hasSuffix(" argv=python a.py"), "L1 a record's fields, argv last")
    expect(!block.contains("pool="), "L1 no pool field when nothing judges")

    // L1b the argv field: 16 KB, with a marker that says how much was cut
    let long = CPUAlertCommandLog.argvField([String(repeating: "word ", count: 6000)], home: home)
    expect(long.utf8.count < 16 * 1024 + 40 && long.contains("...(+") && long.hasSuffix(" bytes)"),
           "L1b a huge argument is cut at 16 KB and says how much")

    // L2 and L3 the file, in a scratch directory: rotation and the mode
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cpualert-\(UUID().uuidString)")
    let file = dir.appendingPathComponent("logs/cpu-alert-commands.log")
    func mode(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? nil
    }
    func size(_ url: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1 }
    let previous = umask(0o022)
    CPUAlertCommandLog.append("first line\n", to: file, limit: 100)
    umask(previous)
    expect(mode(file) == 0o600, "L3 a new file is 0600 even under a 022 umask")
    CPUAlertCommandLog.append(String(repeating: "x", count: 80) + "\n", to: file, limit: 100)
    expect(!FileManager.default.fileExists(atPath: file.path + ".1") && size(file) == 11 + 81, "L2 under the limit it appends")
    CPUAlertCommandLog.append(String(repeating: "y", count: 50) + "\n", to: file, limit: 100)
    expect(FileManager.default.fileExists(atPath: file.path + ".1") && size(file) == 51 && size(URL(fileURLWithPath: file.path + ".1")) == 92,
           "L2 past the limit the file moves to .1 and a new one starts")
    CPUAlertCommandLog.append(String(repeating: "z", count: 60) + "\n", to: file, limit: 100)
    expect(size(URL(fileURLWithPath: file.path + ".1")) == 51 && size(file) == 61, "L2 only one older generation is kept")
    expect(mode(file) == 0o600 && mode(URL(fileURLWithPath: file.path + ".1")) == 0o600, "L3 both generations are 0600")
    try? FileManager.default.removeItem(at: dir)
}
