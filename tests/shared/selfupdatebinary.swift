import Foundation

/// SelfUpdate.swift's lookup, standing in so a suite that compiles ProviderReopen.swift need not
/// compile the supervisor (same stand-in as tests/projectpolicy/reopenparitychecks.swift).
func selfUpdateBinary(_ candidate: String? = Bundle.main.executableURL?.path) -> String? {
    guard let candidate, FileManager.default.isExecutableFile(atPath: candidate) else { return nil }
    return candidate
}
