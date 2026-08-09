import Foundation

/// One entry of the update feed, reduced to what a decision needs.
struct FeedRelease: Equatable, Sendable {
    /// The release's CFBundleVersion, which is what Sparkle ranks releases by (`sparkle:version`).
    /// Held as an integer because this project's pipeline stamps CURRENT_PROJECT_VERSION into it;
    /// an item whose build cannot be read as one is left out rather than guessed at (Sparkle's own
    /// comparator still handles it during an install, so nothing is lost but this reader's opinion).
    let build: Int
    /// CFBundleShortVersionString: the "0.41.0" the header chip shows.
    let display: String
    /// `sparkle:minimumSystemVersion`, nil when the item does not state one.
    let minimumSystemVersion: String?
}

/// Reads the Sparkle appcast well enough to answer one question: what is the newest release the
/// feed offers this machine.
///
/// Tally reads the feed ITSELF rather than asking Sparkle for its opinion, and that is the whole
/// reason this file exists. Sparkle runs one update session at a time, and a session that has
/// found an update does not end when the check ends: it stays open until the update is installed
/// or a dialog is answered. `SPUUpdater` refuses every check while one is open, and it only
/// schedules the next check from the completion handler that the open session never reaches, so
/// the first release found after launch is the last release Sparkle will ever hear about. On a
/// project that ships two or three times a day, that reading is stale within the hour. This reader
/// keeps no session and no state, so it can always answer.
enum AppcastFeed {
    /// Every item of the feed this machine could install, newest first.
    ///
    /// Items are dropped when they carry no readable build number, when they name a channel (a
    /// feed with beta channels must not be offered to a subscriber of none, which is Sparkle's own
    /// default), or when they ask for more macOS than this machine runs.
    ///
    /// A feed that fails to parse partway through still returns the items that were complete: each
    /// `</item>` is self contained, and a truncated response is a reason to know less, not a reason
    /// to know nothing.
    static func releases(from xml: Data, runningSystem: [Int]) -> [FeedRelease] {
        let collector = ItemCollector()
        let parser = XMLParser(data: xml)
        parser.delegate = collector
        _ = parser.parse()
        return collector.releases
            .filter { satisfiesMinimumSystem($0.minimumSystemVersion, running: runningSystem) }
            .sorted { $0.build > $1.build }
    }

    /// The newest release worth telling the user about, or nil when this build is already it.
    static func newest(from xml: Data, runningSystem: [Int], above installedBuild: Int) -> FeedRelease? {
        releases(from: xml, runningSystem: runningSystem).first { $0.build > installedBuild }
    }

    /// Whether a `sparkle:minimumSystemVersion` string admits the running system. Components the
    /// shorter side does not state count as zero, so "14" and "14.0.0" mean the same floor. An
    /// unreadable component answers true: refusing to offer an update because a version string had
    /// a shape this parser did not expect is the more expensive mistake of the two.
    static func satisfiesMinimumSystem(_ minimum: String?, running: [Int]) -> Bool {
        guard let minimum, !minimum.isEmpty else { return true }
        let wanted = minimum.split(separator: ".").map { Int($0) }
        guard !wanted.contains(where: { $0 == nil }) else { return true }
        for index in 0..<max(wanted.count, running.count) {
            let need = index < wanted.count ? (wanted[index] ?? 0) : 0
            let have = index < running.count ? running[index] : 0
            if have != need { return have > need }
        }
        return true
    }
}

/// The XML side, kept private: the shape of an appcast is Sparkle's business and nothing outside
/// this file should learn it.
///
/// Both spellings Sparkle accepts are read. `sparkle:version` and `sparkle:shortVersionString` may
/// be attributes on `<enclosure>` or child elements of `<item>`; the attribute wins where both are
/// present, which is the order `SUAppcastItem` itself applies. Namespace processing stays off so
/// the prefixed names arrive literally, exactly as the feed spells them.
private final class ItemCollector: NSObject, XMLParserDelegate {
    private(set) var releases: [FeedRelease] = []

    private var build: String?
    private var display: String?
    private var minimumSystem: String?
    private var channelled = false
    private var text = ""
    private var insideItem = false

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attributeDict: [String: String]) {
        text = ""
        switch elementName {
        case "item":
            insideItem = true
            build = nil
            display = nil
            minimumSystem = nil
            channelled = false
        case "enclosure" where insideItem:
            build = attributeDict["sparkle:version"] ?? build
            display = attributeDict["sparkle:shortVersionString"] ?? display
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        guard insideItem else { return }
        switch elementName {
        case "sparkle:version":
            if build == nil, !value.isEmpty { build = value }
        case "sparkle:shortVersionString":
            if display == nil, !value.isEmpty { display = value }
        case "sparkle:minimumSystemVersion":
            if !value.isEmpty { minimumSystem = value }
        case "sparkle:channel":
            channelled = true
        case "item":
            insideItem = false
            if !channelled, let build, let number = Int(build) {
                releases.append(FeedRelease(build: number,
                                            display: display ?? build,
                                            minimumSystemVersion: minimumSystem))
            }
        default:
            break
        }
    }
}

/// What a press of the header chip (or an idle moment) should actually do.
enum UpdateStep: Equatable {
    /// Nothing newer than this build is known.
    case nothing
    /// A payload is downloaded and staged, and it is the newest release known. Run it.
    case installStaged
    /// A payload is staged but the feed has moved past it. Sparkle cannot be redirected once an
    /// update is staged (there is no public API that discards one, and the staged installer runs on
    /// quit either way), so running it is the only move left; the poll after the relaunch picks up
    /// the rest. Reaching this state means the staging happened too early, which is what
    /// `UpdaterController` now exists to prevent.
    case installStaleStaged(newest: FeedRelease)
    /// Nothing is staged: fetch this release now and install what comes back.
    case fetchNewest(FeedRelease)
}

/// How the header chip should read.
struct UpdateChip: Equatable {
    let display: String
    /// The payload for exactly this version is already on disk, so a click is a restart rather
    /// than a download. False whenever the newest known release is not the staged one, because a
    /// chip that promises a one click restart into a version nobody has downloaded is a lie the
    /// user only discovers after pressing it.
    let ready: Bool
}

/// The rule the whole feature reduces to. `staged` is what Sparkle has on disk, `newest` is what
/// the feed said the last time anyone looked, and `installedBuild` is this bundle's CFBundleVersion.
///
/// Two properties, in this order:
///
/// 1. The chip always names the version a press would install. It is checked by an assertion over
///    every combination below, because a chip that names one version and installs another is the
///    complaint this file was written for.
/// 2. That version is the newest release the app knows about. Held in every state the app can
///    reach, because a payload is only ever staged by an install that started with a feed read
///    taken moments earlier (see `UpdaterController`). The one exception is `installStaleStaged`,
///    where the feed moved after the payload was staged and Sparkle offers no way to put the
///    payload back; there property 1 wins, and the poll after the relaunch collects the rest.
enum UpdatePlan {
    static func chip(installedBuild: Int, staged: FeedRelease?, newest: FeedRelease?) -> UpdateChip? {
        // Derived from the step rather than worked out again beside it, so property 1 above holds
        // by construction: there is one answer to "which version", and the chip is a rendering of
        // it. The incident this file is named for was two answers drifting apart.
        let step = step(installedBuild: installedBuild, staged: staged, newest: newest)
        guard let display = versionThatWouldInstall(step, staged: staged) else { return nil }
        if case .fetchNewest = step { return UpdateChip(display: display, ready: false) }
        return UpdateChip(display: display, ready: true)
    }

    static func step(installedBuild: Int, staged: FeedRelease?, newest: FeedRelease?) -> UpdateStep {
        let feedNewer = newest.flatMap { $0.build > installedBuild ? $0 : nil }
        if let staged, staged.build > installedBuild {
            guard let feedNewer, feedNewer.build > staged.build else { return .installStaged }
            return .installStaleStaged(newest: feedNewer)
        }
        guard let feedNewer else { return .nothing }
        return .fetchNewest(feedNewer)
    }

    /// The version a press is about to put on the machine. The chip is built out of this, which
    /// is what makes the two impossible to disagree.
    static func versionThatWouldInstall(_ step: UpdateStep, staged: FeedRelease?) -> String? {
        switch step {
        case .nothing: return nil
        case .installStaged, .installStaleStaged: return staged?.display
        case .fetchNewest(let release): return release.display
        }
    }
}
