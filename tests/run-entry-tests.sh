#!/bin/bash
# The Rust `tally` entry (rust/crates/cli) hands every invocation to the Swift CLI beside it
# unchanged. Builds the entry, puts a probe (tests/entry/probe.swift) where the Swift CLI goes
# (Contents/Helpers/swift/tally), and has a launcher fork, set up the process (SIGPIPE disposition,
# a blocked SIGUSR1, fd 3, cwd, environment, stdin) and exec the entry; the probe reports what it
# was started as. Whatever differs is something the entry changed. No Swift CLI build needed.
# Count assertions with `command grep -c '^PASS:'`.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=14.0
(cd rust && cargo build --quiet --release --locked -p tally)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
helpers="$work/App/Contents/Helpers"
mkdir -p "$helpers/swift" "$work/bin" "$work/cwd"
swiftc -O -o "$helpers/swift/tally" tests/entry/probe.swift
cp rust/target/release/tally "$helpers/tally"
ln -s "$helpers/tally" "$work/bin/tally"

python3 - "$work" <<'PY'
import os, signal, subprocess, sys, time

work = sys.argv[1]
entry = f"{work}/App/Contents/Helpers/tally"
link = f"{work}/bin/tally"
swift = f"{work}/App/Contents/Helpers/swift/tally"
failed = 0

def check(name, ok):
    global failed
    print(("PASS: " if ok else "FAIL: ") + name)
    failed += 0 if ok else 1

def launch(path, argv, sigpipe=signal.SIG_DFL, stdin=b"", env_value="probe-env", exit_code="0"):
    """fork, shape the child, exec `path` with `argv` (argv[0] included); returns the fork's pid,
    the exit code, stdout, stderr and the seconds it took."""
    out_r, out_w = os.pipe()
    err_r, err_w = os.pipe()
    in_r, in_w = os.pipe()
    started = time.monotonic()
    pid = os.fork()
    if pid == 0:
        os.dup2(in_r, 0); os.dup2(out_w, 1); os.dup2(err_w, 2)
        fd3 = os.open("/dev/null", os.O_RDONLY)
        os.dup2(fd3, 3); os.set_inheritable(3, True)
        os.chdir(f"{work}/cwd")
        signal.signal(signal.SIGPIPE, sigpipe)
        signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGUSR1})
        env = {"PATH": "/usr/bin:/bin", "TALLY_ENTRY_PROBE": env_value,
               "TALLY_ENTRY_PROBE_EXIT": exit_code}
        try:
            os.execve(path, argv, env)
        finally:
            os._exit(99)
    for fd in (in_r, out_w, err_w):
        os.close(fd)
    os.write(in_w, stdin); os.close(in_w)
    with os.fdopen(out_r, "rb") as o, os.fdopen(err_r, "rb") as e:
        out, err = o.read(), e.read()
    _, status = os.waitpid(pid, 0)
    return pid, os.waitstatus_to_exitcode(status), out, err, time.monotonic() - started

def report(out):
    return dict(line.split("=", 1) for line in out.decode().splitlines() if "=" in line)

def argv_hex(argv):
    return b"\0".join(a if isinstance(a, bytes) else a.encode() for a in argv).hex()

args = [entry, "help", "", "two words", b"\xff\xfe-not-utf8", "--flag=x"]
pid, rc, out, err, _ = launch(entry, args, stdin=b"stdin-bytes\n")
r = report(out)
check("E1 the Swift CLI runs as the same process the caller started", r.get("pid") == str(pid))
check("E2 every argument reaches it byte for byte, argv[0] included", r.get("argv") == argv_hex(args))

pid, rc, out, err, _ = launch(link, [link, "status"])
r = report(out)
check("E3 called through a symlink, argv[0] stays the link", r.get("argv") == argv_hex([link, "status"]))
check("E3 and the Swift CLI is still found beside the resolved entry", rc == 0 and "pid" in r)

for disposition, word in ((signal.SIG_IGN, "ign"), (signal.SIG_DFL, "dfl")):
    _, _, out, _, _ = launch(entry, [entry], sigpipe=disposition)
    check(f"E4 SIGPIPE set to {word} by the caller is {word} in the Swift CLI",
          report(out).get("sigpipe") == word)

_, _, out, _, _ = launch(entry, [entry])
check("E5 the caller's blocked SIGUSR1 stays blocked", report(out).get("usr1blocked") == "true")

_, _, out, _, _ = launch(entry, [entry], stdin=b"\x00in\xff", env_value="v=1 two")
r = report(out)
check("E6 environment, cwd, fd 3 and stdin arrive unchanged",
      r.get("env") == "v=1 two" and r.get("cwd") == os.path.realpath(f"{work}/cwd")
      and r.get("fd3") == "true" and r.get("stdin") == b"\x00in\xff".hex())

for code in ("0", "2", "77"):
    _, rc, out, err, _ = launch(entry, [entry], exit_code=code)
    check(f"E7 exit code {code} and both streams pass through",
          rc == int(code) and out.startswith(b"argv=") and err == b"probe-stderr\n")

os.rename(swift, swift + ".gone")
_, rc, out, err, took = launch(entry, [entry, "help"])
os.rename(swift + ".gone", swift)
want = f"tally: cannot start {os.path.realpath(swift)}: No such file or directory (os error 2)\n"
check("E8 a missing Swift CLI is retried, then reported once with exit 127",
      rc == 127 and out == b"" and err.decode() == want and took >= 0.45)
if not (rc == 127 and err.decode() == want):
    print(f"    rc={rc} err={err!r} took={took:.2f}")

sys.exit(1 if failed else 0)
PY

rust_dir=$(command grep -oE 'SWIFT_CLI_DIR: &str = "[^"]+"' rust/crates/sys/src/paths.rs | command grep -oE '"[^"]+"')
swift_dir=$(command grep -oE 'let swiftCLIDirectoryName = "[^"]+"' TallyCLI/SupervisorRuntime.swift | command grep -oE '"[^"]+"')
if [ -n "$rust_dir" ] && [ "$rust_dir" = "$swift_dir" ]; then
    echo "PASS: E9 the Rust and Swift sides name the same Swift CLI directory ($rust_dir)"
else
    echo "FAIL: E9 the Rust and Swift sides name the same Swift CLI directory (rust=$rust_dir swift=$swift_dir)"
    exit 1
fi
if strings rust/target/release/tally | command grep -q 'tally_entry forward-v1'; then
    echo "PASS: E10 the entry carries the marker build-release.sh looks for"
else
    echo "FAIL: E10 the entry carries the marker build-release.sh looks for"
    exit 1
fi
echo "ALL PASS"
