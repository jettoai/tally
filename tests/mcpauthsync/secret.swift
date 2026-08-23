import Foundation

// THE ONE PLACE IN THIS REPO THAT READS A KEYCHAIN SECRET (TallyCLI/KeychainSecret.swift), asserted
// against a real Keychain item this suite creates and removes rather than against its own source.
//
// WHY A REAL ITEM AND NOT A FIXTURE: what this function does is borrow another program's ACL entry
// by running as `/usr/bin/security`, and every way it can be got wrong is a property of that tool
// rather than of any value in this process. The newline `-w` prints, what it does with bytes that
// are not UTF-8, what it exits with when the item is not there: none of those can be stated by a
// fixture, and all of them decide whether a config home is seeded or silently skipped.
//
// The item created here is this suite's own, named after its process, holding an obviously fake
// value, and removed on the way out. It is NOT a `Claude Code-*` item and nothing here reads one.
//
// WHAT THIS SUITE CANNOT COVER, said plainly rather than left to be assumed: it creates its item the
// same way Claude Code creates its own (`security add-generic-password`), so `security` is in the
// ACL and no consent panel is raised. The case where a panel WOULD be raised is an item created by
// some other program, which a test cannot make, and that case is what the timeout in the product
// bounds. Its mechanism is asserted off the source below; its behaviour was measured by hand.

private let testService = "tally-mcpauthsync-test-\(getpid())"
private let testAccount = "tally-test"

/// Run `security` with the given arguments, answering its exit status. Nothing it prints is kept.
@discardableResult
private func security(_ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
}

private func storeTestSecret(_ arguments: [String]) -> Bool {
    security(["add-generic-password", "-U", "-a", testAccount, "-s", testService] + arguments) == 0
}

private func removeTestSecret() {
    security(["delete-generic-password", "-a", testAccount, "-s", testService])
}

func checkTheSecretRead() {
    let secret = source("TallyCLI/KeychainSecret.swift")

    do {
        // BOTH DIRECTIONS ARE THE SUBPROCESS NOW, and the write only joined the read after it had
        // shipped damage: `SecItemUpdate` from a binary that is not `security` silently rewrites the
        // item's partition list to the writer's own identity, which locks Apple's tool - and with it
        // Claude Code, this launcher and the app's usage polling - out of the item behind a consent
        // panel (repair.swift reproduces it end to end).
        expect(secret.contains("func keychainSecret("), "the harness really read the secret reader")
        let reader = body(of: "func keychainSecret(", in: secret)
        expect(reader.contains("URL(fileURLWithPath: \"/usr/bin/security\")")
                && reader.contains("[\"find-generic-password\", \"-s\", service, \"-a\", account, \"-w\"]"),
               "the secret is read by the program the item's ACL already names, with the service and "
                   + "the account passed as arguments rather than through a shell")
        expect(!secret.contains("SecItemCopyMatching("),
               "…and no path in this file asks the Security framework for the data itself, which is "
                   + "the call that raises the consent panel")
        expect(!reader.contains("kSecReturnData"),
               "…so the read carries none of the query that call needs either")
        let writer = body(of: "func updateKeychainSecret(", in: secret)
        expect(!secret.contains("SecItemUpdate("),
               "NO path in this file writes through the framework any more, which is the call that "
                   + "damaged two of this machine's items")
        expect(writer.contains("writeKeychainSecretAsSecurityTool("),
               "…the write runs as the same tool the read borrows, so the partition list it leaves "
                   + "behind is the one `security` writes")
        let tool = body(of: "func writeKeychainSecretAsSecurityTool(", in: secret)
        expect(tool.contains("URL(fileURLWithPath: \"/usr/bin/security\")")
                && tool.contains("\"add-generic-password\", \"-a\", account, \"-s\", service, \"-U\","),
               "…through `add-generic-password -U`, with the service and the account as arguments "
                   + "rather than through a shell")
        expect(tool.contains("\"-X\""), "…and the value as hex, because a document may hold a NUL "
                   + "that `-w`'s C string would truncate")
        expect(tool.contains("process.terminationReason == .exit && process.terminationStatus == 0"),
               "…with a signalled exit refused as a write, the way the read refuses it as a reading")
        expect(writer.contains("KeychainReader.exists(service: service, account: account)")
                && writer.contains("return errSecItemNotFound"),
               "and the one thing `SecItemUpdate` gave for free is bought back explicitly: `-U` "
                   + "would CREATE an item for a config home that has no login, so existence is "
                   + "asked first, by attributes")
    }

    do {
        // The secret exists in this process's memory and nowhere else.
        let reader = body(of: "func keychainSecret(", in: secret)
        expect(reader.contains("process.standardError = FileHandle.nullDevice")
                && reader.contains("process.standardInput = FileHandle.nullDevice"),
               "the child cannot write anywhere but the pipe, and cannot wait on input either")
        expect(!secret.contains("print("), "and nothing in this file prints")
        // A pipe the parent is not draining blocks the child that is filling it, and the parent
        // would then be waiting for a process that is waiting for the parent.
        expect(inOrder("readDataToEndOfFile", "waitUntilExit", in: reader),
               "the pipe is drained before the child is waited on, not after")
        // The bound, and the line that tells a killed read from a completed one: the pipe closes
        // either way, so the bytes read say nothing about which happened.
        expect(reader.contains("DispatchQueue.global().asyncAfter(deadline: .now() + keychainSecretTimeout"),
               "a read that never comes back is given up on rather than holding the launch open")
        expect(reader.contains("process.terminationReason == .exit, process.terminationStatus == 0"),
               "…and a signalled exit is not accepted as a reading")
    }

    // THE BEHAVIOURAL HALF. A failure to create the item is a FAILURE and not a skip: a locked
    // keychain would otherwise turn every assertion below into a silent pass.
    removeTestSecret()
    let value = "not-a-real-secret {\"a\": 1} with a space, a \"quote\" and \u{4e2d}\u{6587}"
    expect(storeTestSecret(["-w", value]),
           "the suite can create a generic-password item to read back")

    do {
        let read = keychainSecret(service: testService, account: testAccount)
        expect(read == Data(value.utf8),
               "the secret comes back byte for byte, with the newline `-w` prints removed and "
                   + "nothing else removed with it")
        expect(read.map { $0.last != 0x0a } ?? false,
               "…so a caller parsing it as a document is not handed a trailing newline")
    }

    do {
        // THE FORMAT THE TOOL SWITCHES TO, which is the whole reason the product decodes anything.
        // A secret with a byte outside 0x20...0x7e in it is printed as hex, and every one of these
        // rows is a byte a real credentials document could grow tomorrow.
        expect(storeTestSecret(["-w", "ends-with-newline\n"]), "the suite can rewrite its item")
        expect(keychainSecret(service: testService, account: testAccount)
                == Data("ends-with-newline\n".utf8),
               "a secret that ends in a newline of its own keeps it, rather than being read as the "
                   + "hex the tool printed it as")
        let nonASCII = "{\"server\":\"\u{4e2d}\u{6587}\"}"
        expect(storeTestSecret(["-w", nonASCII]),
               "the suite can store a document with a non-ASCII character in it")
        expect(keychainSecret(service: testService, account: testAccount) == Data(nonASCII.utf8),
               "one non-ASCII character in a document does not cost a whole config home its "
                   + "seeding, which is what a reading left as hex would have done")
        expect(storeTestSecret(["-X", "00FF41FE"]), "the suite can store bytes that are not text")
        expect(keychainSecret(service: testService, account: testAccount)
                == Data([0x00, 0xFF, 0x41, 0xFE]),
               "a secret that is not text at all comes back as its bytes")
    }

    do {
        // THE AMBIGUITY, asserted so that it is visible rather than discovered. The decoding is the
        // exact inverse of the tool's rule, so the only reading it can get wrong is a secret that is
        // itself even-length lowercase hex AND decodes to something unprintable - which comes back
        // decoded. A credentials document begins with `{` and cannot be this shape.
        expect(storeTestSecret(["-w", "deadbeef"]), "the suite can store a secret that looks like hex")
        expect(keychainSecret(service: testService, account: testAccount)
                == Data([0xde, 0xad, 0xbe, 0xef]),
               "a printable secret that is itself hex is decoded, which is the one shape the two "
                   + "print formats cannot be told apart in")
        expect(storeTestSecret(["-w", "20207e7e"]),
               "the suite can store hex that decodes to printable bytes")
        expect(keychainSecret(service: testService, account: testAccount) == Data("20207e7e".utf8),
               "…while hex whose bytes are all printable is left alone, because the tool would "
                   + "never have printed those as hex in the first place")
    }

    removeTestSecret()
    do {
        // Every kind of nothing is the same nothing to the caller (KeychainSecret.swift says why).
        expect(keychainSecret(service: testService, account: testAccount) == nil,
               "an item that is not there reads as nil rather than as empty bytes")
        expect(storeTestSecret(["-w", "not-a-real-secret"]), "the suite can restore its item")
        expect(keychainSecret(service: testService, account: "no-such-account") == nil,
               "…and so does an item whose account does not match, which is the guard against "
                   + "reading whichever item shares the service name")
    }
    removeTestSecret()
}
