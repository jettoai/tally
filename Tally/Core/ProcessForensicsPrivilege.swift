import Foundation

// THE ONE ROOT STEP OF THE EVIDENCE FILE (B-4616, second half): `sample` and `fs_usage` need root, and
// a root process such as fseventsd is the one that most needs them. Albert approved it once
// (2026-11-15, B-4616 card): the system's password window installs two root-owned files, and nothing
// else on this machine is written as root:
//
//   /Library/PrivilegedHelperTools/ai.jetto.tally.forensics   a /bin/sh script, root:wheel 0755
//   /etc/sudoers.d/tally-forensics                            one rule, root:wheel 0440
//
// The rule lets this account run that script, and remove those two files, with no password. It must
// never name `/usr/bin/sample` itself: its `-file` option writes anywhere, and a rule for it would hand
// every program of this account a root file overwrite. So the script is the whole surface: ONE decimal
// pid in, text on stdout out, no path ever taken from the caller, and the only file it writes lives in
// a temp folder only root can open. It lives in /Library/PrivilegedHelperTools (root all the way up),
// never under /usr/local, which this user owns. Foundation only: the CLI compiles it for `status`.
enum ProcessForensicsPrivilege {
    static let wrapperPath = "/Library/PrivilegedHelperTools/ai.jetto.tally.forensics"
    static let sudoersPath = "/etc/sudoers.d/tally-forensics"
    /// The only removal the rule allows, byte for byte; the sudoers text and the unprivileged `sudo -n`
    /// both read this one list, so they cannot drift.
    static let removeArguments = ["/bin/rm", "-f", sudoersPath, wrapperPath]

    // MARK: - the rule

    /// `[a-z_][a-z0-9_.-]*`, scanned by character: a regex's `$` would let a trailing newline through,
    /// and a newline in a sudoers line is a second rule.
    static func isValidUser(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, !name.isEmpty else { return false }
        func lower(_ c: Unicode.Scalar) -> Bool { c.value >= 0x61 && c.value <= 0x7A }
        func digit(_ c: Unicode.Scalar) -> Bool { c.value >= 0x30 && c.value <= 0x39 }
        guard lower(first) || first == "_" else { return false }
        return name.unicodeScalars.allSatisfy { lower($0) || digit($0) || $0 == "_" || $0 == "." || $0 == "-" }
    }

    /// nil for a name that is not a plain account name.
    static func sudoersRule(user: String) -> String? {
        guard isValidUser(user) else { return nil }
        return """
            # Installed by Tally (B-4616): lets this account run one read-only evidence helper as root, and remove it.
            # Remove with: tally forensics remove
            \(user) ALL=(root) NOPASSWD: \(wrapperPath), \(removeArguments.joined(separator: " "))

            """
    }

    // MARK: - the helper

    /// The root script. The two tool paths are parameters only so a suite can put fakes there; the
    /// installed text is `wrapperScript()`.
    static func wrapperScript(sample: String = "/usr/bin/sample", fsUsage: String = "/usr/bin/fs_usage") -> String {
        """
        #!/bin/sh
        # Tally process forensics helper (B-4616). Root-owned; run through one sudoers rule.
        # One argument, a decimal pid: prints a 10 s `sample` of it and a 10 s `fs_usage` of the machine.
        PATH=/usr/bin:/bin:/usr/sbin:/sbin
        LC_ALL=C
        export PATH LC_ALL
        [ "$#" -eq 1 ] || exit 64
        case "$1" in
          ''|*[!0-9]*|0*) exit 64 ;;
        esac
        [ "${#1}" -le 7 ] || exit 64
        pid=$1
        d=$(/usr/bin/mktemp -d) || exit 70
        trap '/bin/rm -rf "$d"' EXIT
        trap 'exit 1' HUP INT TERM
        \(fsUsage) -w -t 10 -f filesys > "$d/fs_usage.txt" 2>&1 &
        \(sample) "$pid" 10 -mayDie -file "$d/sample.txt" > /dev/null 2>&1
        wait
        echo "=== sample $pid ==="
        if [ -s "$d/sample.txt" ]; then /usr/bin/head -c 10485760 "$d/sample.txt"; else echo "(no sample output)"; fi
        echo "=== fs_usage (machine-wide, 10 s) ==="
        if [ -s "$d/fs_usage.txt" ]; then /usr/bin/head -c 10485760 "$d/fs_usage.txt"; else echo "(no fs_usage output)"; fi
        exit 0

        """
    }

    // MARK: - the install

    /// Run as root through the password window: `sh -c <script> sh <wrapper text> <sudoers text>`. Both
    /// texts arrive as argv, never from a file the user could swap while the window waits for the
    /// password. They go to root's own temp folder, the rule is checked with `visudo -cf`, and only then
    /// are the files installed (the helper first, so the rule never names a file that is not there). A
    /// failed second install takes the first back: no half of it is left.
    static func installScript(visudo: String = "/usr/sbin/visudo", install: String = "/usr/bin/install",
                              owner: String = "-o root -g wheel",
                              wrapper: String = wrapperPath, sudoers: String = sudoersPath) -> String {
        """
        umask 077
        d=$(/usr/bin/mktemp -d) || exit 70
        trap '/bin/rm -rf "$d"' EXIT
        printf '%s\\n' "$1" > "$d/wrapper" || exit 70
        printf '%s\\n' "$2" > "$d/sudoers" || exit 70
        \(visudo) -cf "$d/sudoers" > /dev/null 2>&1 || exit 65
        \(install) -S -m 0755 \(owner) "$d/wrapper" '\(wrapper)' || exit 66
        \(install) -S -m 0440 \(owner) "$d/sudoers" '\(sudoers)' || { /bin/rm -f '\(wrapper)'; exit 66; }
        """
    }

    static let removeScript = removeArguments.map { "'\($0)'" }.joined(separator: " ")

    // MARK: - the state

    enum State: Equatable { case notInstalled, installed, incomplete }

    /// Both files there and the rule effective for this account. One file without the other, or both
    /// there and `sudo -n -l` refusing, is `incomplete` (Remove and Set Up both repair it).
    static func state(exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                      allowed: () -> Bool = { sudoAllows() }) -> State {
        let wrapper = exists(wrapperPath), rule = exists(sudoersPath)
        if !wrapper && !rule { return .notInstalled }
        return wrapper && rule && allowed() ? .installed : .incomplete
    }

    /// `sudo -n -l <helper>`: exit 0 only when the rule lets this account run it without a password.
    static func sudoAllows(helper: String = wrapperPath) -> Bool { runSudo(["-n", "-l", helper]) == 0 }

    /// The removal the rule allows, with no password window; false when it is refused.
    static func sudoRemove() -> Bool { runSudo(["-n"] + removeArguments) == 0 }

    private static func runSudo(_ arguments: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = arguments
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return -1 }
        let pid = task.processIdentifier
        let watchdog = DispatchWorkItem { if pid > 0 { kill(pid, SIGTERM) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
        task.waitUntilExit()
        watchdog.cancel()
        return task.terminationReason == .exit ? task.terminationStatus : -1
    }
}
