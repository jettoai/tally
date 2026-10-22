import Foundation

// Run by tests/run-usagelayout-tests.sh in two builds (with and without -DDEBUG) and with
// `-TallyUsageLayout <value>` on the command line: the argument domain is what the app reads, so this
// is the flag path end to end. EXPECT names what UsageLayout.active must be (a rawValue, or "nil").
@main
enum FlagCheck {
    static func main() {
        let expect = ProcessInfo.processInfo.environment["EXPECT"] ?? "nil"
        let got = UsageLayout.active?.rawValue ?? "nil"
        print("\(got == expect ? "PASS" : "FAIL") active is \(got), expected \(expect)")
        exit(got == expect ? 0 : 1)
    }
}
