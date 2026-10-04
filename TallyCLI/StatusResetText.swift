import Foundation

/// The reset part of one `tally status` text line, in the four states the app publishes. Not
/// supported prints nothing; unknown is printed, so it never passes for "no resets". An app too
/// old to publish `resetState` falls back to the banked count alone.
func resetStatusSuffix(_ account: Snapshot.Account, now: Date = Date()) -> String {
    let banked = account.resetCreditsAvailable ?? 0
    let bankedText = " · \(banked) reset\(banked == 1 ? "" : "s") banked"
    switch account.resetState {
    case "available" where banked > 0:
        var text = bankedText
        if let expiry = account.resetCreditsNextExpiry {
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.dateFormat = "yyyy-MM-dd HH:mm"
            text += ", expires in \(shortETA(max(60, expiry.timeIntervalSince(now))))"
                + " (\(stamp.string(from: expiry)))"
        }
        if account.resetCreditsExpiryUnknown == true { text += ", expiry unknown" }
        return text
    case "available": return " · reset available"
    case "used": return " · no resets banked"
    case "unknown": return " · resets unknown"
    case "notSupported": return ""
    default: return banked > 0 ? bankedText : ""
    }
}
