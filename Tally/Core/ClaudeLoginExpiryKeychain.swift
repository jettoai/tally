import Foundation
import Security

/// A read-only adapter. No credential data is returned outside ClaudeLoginExpiry's read operation.
enum ClaudeLoginExpiryKeychain {
    static func read(service: String) -> ClaudeLoginExpiry.Source {
        let account = NSUserName()
        let modifiedAt = KeychainReader.modifiedAt(service: service, account: account)
        guard permitsSecurityRead(service: service, account: account) else {
            let status = SecItemCopyMatching([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ] as CFDictionary, nil)
            return .init(data: nil, modifiedAt: modifiedAt, isAbsent: status == errSecItemNotFound)
        }
        return .init(data: readSecret(service: service, account: account), modifiedAt: modifiedAt)
    }

    private static func readSecret(service: String, account: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // A timeout bounds a changed ACL or Keychain lock between the probe and the child read.
        // It cannot suppress a child-process dialog; the preflight rejects known prompting states.
        let watchdog = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: watchdog)
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return ClaudeLoginExpiry.decodeSecurityOutput(printed)
    }

    private typealias ItemTypeID = @convention(c) () -> CFTypeID
    private typealias ItemKeychain =
        @convention(c) (SecKeychainItem, UnsafeMutablePointer<SecKeychain?>) -> OSStatus
    private typealias KeychainStatus =
        @convention(c) (SecKeychain?, UnsafeMutablePointer<SecKeychainStatus>) -> OSStatus
    private typealias ItemAccess =
        @convention(c) (SecKeychainItem, UnsafeMutablePointer<SecAccess?>) -> OSStatus
    private typealias AccessList =
        @convention(c) (SecAccess, UnsafeMutablePointer<CFArray?>) -> OSStatus
    private typealias Authorizations = @convention(c) (SecACL) -> Unmanaged<CFArray>?
    private typealias Contents =
        @convention(c) (SecACL, UnsafeMutablePointer<CFArray?>, UnsafeMutablePointer<CFString?>,
                       UnsafeMutablePointer<SecKeychainPromptSelector>) -> OSStatus
    private typealias ApplicationData =
        @convention(c) (SecTrustedApplication, UnsafeMutablePointer<CFData?>) -> OSStatus

    private static func symbol<Function>(_ name: String, as type: Function.Type) -> Function? {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    /// Metadata only: require an unlocked item, Apple's tool partition, and a trusted security tool.
    /// An unavailable legacy Security API makes the login deadline unknown instead of prompting.
    static func permitsSecurityRead(service: String, account: String) -> Bool {
        var reference: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnRef as String: true,
        ] as CFDictionary, &reference)
        guard status == errSecSuccess, let reference,
              let typeID = symbol("SecKeychainItemGetTypeID", as: ItemTypeID.self),
              CFGetTypeID(reference) == typeID(),
              let copyKeychain = symbol("SecKeychainItemCopyKeychain", as: ItemKeychain.self),
              let getStatus = symbol("SecKeychainGetStatus", as: KeychainStatus.self),
              let copyAccess = symbol("SecKeychainItemCopyAccess", as: ItemAccess.self),
              let copyACLs = symbol("SecAccessCopyACLList", as: AccessList.self),
              let authorizations = symbol("SecACLCopyAuthorizations", as: Authorizations.self),
              let contents = symbol("SecACLCopyContents", as: Contents.self),
              let applicationData = symbol("SecTrustedApplicationCopyData", as: ApplicationData.self)
        else { return false }
        let item = unsafeDowncast(reference, to: SecKeychainItem.self)
        var keychain: SecKeychain?
        var keychainStatus: SecKeychainStatus = 0
        guard copyKeychain(item, &keychain) == errSecSuccess, let keychain,
              getStatus(keychain, &keychainStatus) == errSecSuccess,
              keychainStatus & UInt32(kSecUnlockStateStatus) != 0 else { return false }
        var access: SecAccess?
        var list: CFArray?
        guard copyAccess(item, &access) == errSecSuccess, let access,
              copyACLs(access, &list) == errSecSuccess,
              let acls = list as? [SecACL] else { return false }
        var trustsSecurity = false
        var hasAppleToolPartition = false
        for acl in acls {
            guard let rights = authorizations(acl)?.takeRetainedValue() as? [String] else { continue }
            var applications: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector()
            guard contents(acl, &applications, &description, &prompt) == errSecSuccess else { continue }
            if rights.contains(kSecACLAuthorizationPartitionID as String),
               let hex = description as String?,
               let bytes = ClaudeLoginExpiry.hexDecoded(Data(hex.utf8)),
               let plist = try? PropertyListSerialization.propertyList(from: bytes, options: [], format: nil),
               let document = plist as? [String: Any],
               let partitions = document["Partitions"] as? [String] {
                hasAppleToolPartition = partitions.contains("apple-tool:")
            }
            guard rights.contains(kSecACLAuthorizationDecrypt as String),
                  let apps = applications as? [SecTrustedApplication] else { continue }
            for app in apps {
                var bytes: CFData?
                guard applicationData(app, &bytes) == errSecSuccess, let bytes,
                      let path = String(data: bytes as Data, encoding: .utf8) else { continue }
                if path.trimmingCharacters(in: CharacterSet(charactersIn: "\0")) == "/usr/bin/security" {
                    trustsSecurity = true
                }
            }
        }
        return trustsSecurity && hasAppleToolPartition
    }
}
