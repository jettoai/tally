import AppKit
import Darwin
import os

/// TAKING SOMEBODY TO THE SESSION THEY JUST CLICKED, which is the whole point of a status board: a
/// row that says a session is waiting and cannot be got to has moved the hunt rather than ended it.
///
/// THREE WAYS, in falling order of how precisely each can answer "which surface".
///
///   1. Ask Ghostty for the surface whose `tty` IS the device the session's own process is attached
///      to. A tty belongs to exactly one surface, so this cannot pick the wrong tab: it is the only
///      one of the three that survives the ordinary case of one repository open in several tabs,
///      splits, or windows at once. ONLY A GHOSTTY THAT CARRIES THAT PROPERTY IS ASKED, which is
///      1.4.0 and later and no version anybody is running today (`readsSurfaceTTY`).
///   2. Failing that, ask for the surface whose working directory IS that checkout, breaking ties
///      on the session's name. Right repository, arbitrary tab within it. This is what answers when
///      the session has no child process left to ask about, or is running in a terminal that is not
///      Ghostty at all and therefore appears in no surface's `tty`.
///   3. Failing that, walk the Claude Code process's ancestors until one of them is an application,
///      and activate it. This knows nothing about windows, so it lands the user in the right APP
///      rather than the right tab, and it works for every terminal there is.
///
/// WHAT THIS CANNOT DO BEFORE GHOSTTY 1.4.0, named rather than papered over: with no device on a
/// surface the only thing left to match on is the checkout, so one repository open in several tabs
/// resolves to an arbitrary one of them - the tie-break reads the surface's title, and a title
/// carries the session's name only by chance. That is the WRONG TAB rather than a failure, nothing
/// here can tell the two apart, and no amount of care in this file fixes it: the surface's identity
/// is simply not published by the versions in the world (ghostty-org/ghostty#11592, milestone
/// 1.4.0). Until then way 1 above is a pass that is never built.
///
/// THE FOREGROUND IS TAKEN BEFORE ANY OF THAT AND HANDED ON THROUGH IT (`prepare`), which is the
/// half of the click that has nothing to do with finding a surface. Since macOS 14 an app cannot
/// take the front; it can only be GIVEN it by whoever holds it, and the surface most of these
/// clicks arrive in is a non-activating panel that deliberately never made this app active. So the
/// click's own synchronous turn is where the foreground is taken and released, and the script's
/// `activate` becomes the target asking for something that has already been let go of.
///
/// EVERY FAILURE FALLS THROUGH RATHER THAN STOPPING. Driving another app is a permission macOS asks
/// the user for once, and a refusal is permanent and silent from here; a Ghostty too old to be
/// asked answers with an error; a session launched from a terminal that has since closed has no
/// ancestor left. None of those is worth a dialog, and all of them end in the same place: the user
/// is where they were, and the panel is still open.
enum TerminalJump {
    /// Ghostty's bundle id, which is also how "is it even running" is asked before an Apple event
    /// is sent: sending one to an app that is not running LAUNCHES it, and a status board must
    /// never open a terminal nobody asked for.
    private static let ghosttyBundleID = "com.mitchellh.ghostty"

    /// How long the AppleScript may take. Generous rather than tight for one reason: the FIRST call
    /// stops inside osascript while macOS asks whether Tally may control the terminal, and a
    /// watchdog firing mid-question would report a refusal that never happened (the same number,
    /// and the same reasoning, as `LoginTerminalFallback`).
    private static let scriptTimeout: TimeInterval = 120

    /// How long an activation is given to settle before it is judged, and asked again another way.
    /// The same span the pick panel gives its own foreground ask (`pickPanelActivationGrace`) and
    /// for the same reason: the request does not complete on the turn it is made, so a reading
    /// taken straight afterwards is a reading of nothing.
    private static let activationGrace: Duration = .milliseconds(600)

    /// WHERE A JUMP THAT DID NOT LAND CAN BE READ AFTERWARDS, which is the only way this rides on a
    /// desktop nobody may synthesize clicks on:
    ///
    ///     log show --last 10m --info --predicate 'subsystem == "ai.jetto.tally"'
    ///
    /// One line per click, carrying the values that separate the ways this can go wrong from each
    /// other (`report`). At info rather than debug so the line is in the buffer to be read AFTER
    /// somebody says the keyboard did not follow, rather than only while a stream is open. The
    /// subsystem is a literal rather than the bundle id, so a dev build and the installed one
    /// answer one predicate.
    private static let log = Logger(subsystem: "ai.jetto.tally", category: "jump")

    /// WHAT A CLICK HAS TO TAKE IN ITS OWN TURN, because none of it can be taken afterwards: an app
    /// may activate itself while it is handling a user event, and the `Task` that runs the jump is
    /// scheduled after that event has been answered.
    struct Handover: Sendable {
        /// Whatever was in front when the card was clicked, so a click that reaches no terminal can
        /// put it back rather than leaving somebody in a status board they only clicked a row in
        /// (the same hand-back the pick panel does with its own `previousApp`). Nil when this app
        /// was already the one in front, which is nothing borrowed and so nothing to return.
        let previousApp: NSRunningApplication?
        /// Ghostty, or nil when it is not running - which is also the standing refusal to launch a
        /// terminal nobody asked for (see `ghosttyBundleID`).
        let terminal: NSRunningApplication?
        /// The window the click landed in, for the log line and nothing else. READ RATHER THAN
        /// DECLARED: the key window at the moment of the press IS the clicked surface (a
        /// non-activating panel makes itself key as the press lands - `MeasuredHostingView`), so a
        /// host passed down from the view would be a second statement of the same fact, able to
        /// disagree with it.
        let surface: String

        /// Put the foreground back where the click found it, for a trip that did not happen. ONE
        /// STATEMENT OF IT, because both exits that can fail want it and a second copy is the one
        /// that forgets the guard: an app that no longer holds the foreground has nothing to hand
        /// over, and handing one anyway would take the screen from whatever the person moved on to
        /// (the pick panel's deadline refuses for the same reason).
        @MainActor
        func giveBack() { if NSApp.isActive { previousApp?.activate() } }
    }

    /// Take the foreground and release it to the terminal, in the click's own synchronous turn.
    ///
    /// THE ORDER IS THE WHOLE OF IT. `NSApplication.yieldActivation(to:)` is what the HOLDER of the
    /// foreground does BEFORE the target asks for it, and both halves of that sentence used to be
    /// missing here: this app was never active at all (a click in a non-activating panel makes the
    /// panel key without making the app active), and the yield was made after the script had
    /// already asked. An app with no foreground yielding one is a cheque with nothing behind it,
    /// which is why the window came up and the typing stayed where it was.
    ///
    /// HARMLESS WHERE IT IS NOT NEEDED: the menu bar popover and the dashboard window each activate
    /// this app before they can be clicked at all (`StatusItemController`, `MainWindowController`),
    /// so on those two surfaces this is the app asking for what it already holds. One path rather
    /// than three, because the difference between the surfaces is a fact about activation that this
    /// call reads for itself.
    @MainActor
    static func prepare() -> Handover {
        let surface = NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none"
        let front = NSWorkspace.shared.frontmostApplication
        let ours = front?.processIdentifier == NSRunningApplication.current.processIdentifier
        let terminal = runningApplication(ghosttyBundleID)
        NSApp.activate()
        if let terminal { NSApp.yieldActivation(to: terminal) }
        return Handover(previousApp: ours ? nil : front, terminal: terminal, surface: surface)
    }

    /// Focus the terminal this session is running in. `childPid` is the session's own process, whose
    /// controlling terminal names the surface exactly; `hint` is the session's own name (the
    /// repository, or the parallel line), used only to break a tie between several windows standing
    /// in one directory once that exact answer is unavailable.
    ///
    /// EVERY WAY OUT OF HERE ENDS IN `land`, because finding the surface is only half of the click:
    /// the other half is the keyboard, and since macOS 14 that half is given away rather than taken
    /// (`prepare`) - and given away is not the same as arrived, which is why each exit then looks.
    @MainActor
    static func jump(directory: String?, hint: String?, childPid: Int?,
                     from handover: Handover) async {
        let directory = directory ?? ""
        // The device is worth reading only when the terminal in front of us can be asked ABOUT one:
        // on an older dictionary the pass built from it raises on every surface and matches
        // nothing, which is a round trip and a scan spent to learn what the version already said.
        let tty: String? = {
            guard let terminal = handover.terminal, readsSurfaceTTY(terminal),
                  let childPid else { return nil }
            return controllingTTY(of: pid_t(childPid))
        }()
        // Nothing to match on at all (no usable device, no recorded checkout) means nothing to ask,
        // and asking anyway would focus whichever surface happens to stand in "".
        if tty != nil || !directory.isEmpty, let ghostty = handover.terminal,
           let matched = await focusGhostty(directory: directory, hint: hint ?? "", tty: tty) {
            await land(on: ghostty, matched: matched, from: handover)
            return
        }
        if let childPid, let owner = owningApplication(of: pid_t(childPid)) {
            await land(on: owner, matched: nil, from: handover)
            return
        }
        // Nothing could be matched, so the last useful act is to put the terminal in front and let
        // the user find the tab: better than a click that visibly does nothing. Only for an app
        // that was ALREADY running, for the reason the bundle id above is checked at all.
        if let ghostty = handover.terminal {
            await land(on: ghostty, matched: nil, from: handover)
            return
        }
        // Not one of the three had anywhere to go, and this app is holding a foreground it took for
        // the trip: it goes straight back, or a click that could do nothing would still have moved
        // somebody out of what they were in.
        handover.giveBack()
        report(handover: handover, matched: nil, target: nil,
               front: NSWorkspace.shared.frontmostApplication, key: NSApp.keyWindow)
    }

    /// Bring an app forward AND THEN LOOK, once, a grace later - which is the difference between a
    /// request and an outcome. `NSRunningApplication.activate(from:options:)` returns whether the
    /// system ALLOWED the ask, and its own header adds that the app may not be activated at all; the
    /// pinned panel's own foreground ask is judged after exactly this kind of pause, for exactly
    /// this reason (`PickPanelController.judgeGrace`).
    ///
    /// TWO THINGS CAN STILL BE WRONG AT THAT POINT, and they are not the same thing:
    ///
    ///   - THE TERMINAL IS NOT IN FRONT: the ask went nowhere. It is then made along the other
    ///     road, LaunchServices - the one `open -a` uses - which reaches activation by a different
    ///     authorisation than an app-to-app transfer does. Never for an app that has since exited,
    ///     because that call would LAUNCH it, and never over somebody who has moved on
    ///     (`retryMayTakeForeground`).
    ///   - THE TERMINAL IS IN FRONT AND THE KEYBOARD IS STILL HERE: a non-activating panel can hold
    ///     the key window while another app is active, which puts the window up and leaves the
    ///     typing behind - the same symptom as the first case and a different cause. Giving up the
    ///     activation this click took is the only lever AppKit sanctions here: `NSWindow.resignKey`
    ///     is documented as never to be called directly, and ordering the panel out would take away
    ///     the surface the person pinned. Whether that is enough is what `key=` in the log line
    ///     says, and it is the one question the source cannot answer on its own.
    @MainActor
    private static func land(on target: NSRunningApplication, matched: SurfaceMatch?,
                             from handover: Handover) async {
        bringForward(target)
        try? await Task.sleep(for: activationGrace)
        let settled = frontmost(is: target)
        if !settled.landed,
           retryMayTakeForeground(front: settled.app?.processIdentifier, handover: handover,
                                  target: target),
           !target.isTerminated, let bundle = target.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: bundle,
                                                             configuration: configuration)
            try? await Task.sleep(for: activationGrace)
        }
        let key = NSApp.keyWindow
        let (front, landed) = frontmost(is: target)
        if landed, key != nil { NSApp.deactivate() }
        // The foreground was borrowed for a trip that did not happen, so it goes back to whoever
        // had it rather than being left with a status board (`Handover.giveBack`).
        if !landed { handover.giveBack() }
        report(handover: handover, matched: matched, target: target, front: front, key: key)
    }

    /// Who is in front, and whether that is the app that was asked for - BOTH OUT OF ONE READ. Two
    /// looks a line apart can disagree, and then the decision below and the line that reports it
    /// would be describing different moments.
    private static func frontmost(is app: NSRunningApplication)
        -> (app: NSRunningApplication?, landed: Bool) {
        let front = NSWorkspace.shared.frontmostApplication
        return (front, front?.processIdentifier == app.processIdentifier)
    }

    /// Whether the second road is still ours to take, asked of who is in front a grace after the
    /// first ask.
    ///
    /// A CLICK IS NOT A STANDING CLAIM ON THE SCREEN. The retry runs 600ms after the press, and in
    /// that window the person may have gone somewhere else entirely - a browser, their editor. The
    /// LaunchServices road then does exactly what it is for and takes the foreground away from
    /// whatever they moved to, for a trip they have already abandoned. The first ask cannot do
    /// this (an app-to-app transfer needs the holder to yield, and a third party has not), which is
    /// why the guard belongs on the retry alone.
    ///
    /// THE CHAIN THE CLICK ITSELF INVOLVED IS WHAT MAY BE TAKEN FROM: this app, whatever it
    /// borrowed the foreground from, and the terminal being aimed at. Anything else in front means
    /// somebody chose it. The same shape as `Handover.giveBack`, which refuses to hand a foreground
    /// back once this app has stopped holding one.
    ///
    /// FRONT UNREADABLE FAILS OPEN, deliberately: no third party can be named, so there is nobody
    /// to interrupt, and this is the reading that keeps the behaviour that stood before the guard.
    private static func retryMayTakeForeground(front: pid_t?, handover: Handover,
                                               target: NSRunningApplication) -> Bool {
        retryMayTakeForeground(front: front, ours: NSRunningApplication.current.processIdentifier,
                               previous: handover.previousApp?.processIdentifier,
                               target: target.processIdentifier)
    }

    /// The rule itself, over pids, so it can be asserted without a desktop to arrange.
    static func retryMayTakeForeground(front: pid_t?, ours: pid_t, previous: pid_t?,
                                       target: pid_t) -> Bool {
        guard let front else { return true }
        return front == ours || front == previous || front == target
    }

    /// One line per click, in the terms that tell the failures apart: which surface it came from,
    /// which pass answered, where the foreground was before and after, and whether a window here is
    /// still holding the keyboard. Every value is public because none of them is more than a bundle
    /// id, a window class or a pass name - the checkout is deliberately not among them.
    @MainActor
    private static func report(handover: Handover, matched: SurfaceMatch?,
                               target: NSRunningApplication?, front: NSRunningApplication?,
                               key: NSWindow?) {
        log.info("""
            jump surface=\(handover.surface, privacy: .public) \
            pass=\(matched?.rawValue ?? "none", privacy: .public) \
            target=\(target?.bundleIdentifier ?? "none", privacy: .public) \
            was=\(handover.previousApp?.bundleIdentifier ?? "none", privacy: .public) \
            now=\(front?.bundleIdentifier ?? "none", privacy: .public) \
            key=\(key.map { String(describing: type(of: $0)) } ?? "none", privacy: .public)
            """)
    }

    /// Hand the foreground over to another application FROM THIS ONE, which since macOS 14 is what
    /// carrying the keyboard across takes.
    ///
    /// AN APP CANNOT SIMPLY TAKE THE FRONT ANY MORE. `NSApplication.activate` is documented to need
    /// whoever holds the foreground to yield first, and the script below asks Ghostty to activate
    /// ITSELF, which is precisely the request the system is free to decline. Declined, the window
    /// still comes up (ordering windows was never restricted, and `focus` raises the surface's
    /// window on its own), so the failure looks exactly like a working jump until the user types
    /// and the letters go wherever they were going before.
    ///
    /// THE YIELD IS MADE TWICE, and deliberately: `prepare` releases the foreground to Ghostty in
    /// the click's own turn (which is the only turn in which this app can have taken one), and this
    /// releases it to whichever app the exit actually settled on - the ancestor walk can land on a
    /// terminal that is not Ghostty at all. A yield to an app that was already yielded to is free.
    @discardableResult
    @MainActor
    private static func bringForward(_ app: NSRunningApplication) -> Bool {
        NSApp.yieldActivation(to: app)
        return app.activate(from: .current, options: [.activateAllWindows])
            || app.activate(options: [.activateAllWindows])
    }

    // MARK: Ghostty

    private static func runningApplication(_ bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    /// WHICH PASS ANSWERED, which is the difference between "this is the surface" and "this is the
    /// repository, pick a tab". Carried out of the script rather than reduced to a bool on the way,
    /// because one of the two has never once answered on a shipped Ghostty (`readsSurfaceTTY`) and
    /// a bool is unable to say so: a jump reporting success while its precise pass is dead code
    /// looks exactly like a jump that worked.
    enum SurfaceMatch: String, Sendable {
        case tty
        case directory = "dir"
    }

    /// Ask Ghostty to focus the surface this session occupies. Returns which pass found it, or nil
    /// when none did - and nil is also what a REFUSED focus reports, because to everything upstream
    /// those are one answer: no surface was focused, so the exits below this one are still owed.
    private static func focusGhostty(directory: String, hint: String,
                                     tty: String?) async -> SurfaceMatch? {
        let result = await CLIRunner.run("/usr/bin/osascript",
                                         arguments: ["-e", script(directory: directory, hint: hint,
                                                                  tty: tty)],
                                         timeout: scriptTimeout)
        guard result?.exitCode == 0, let stdout = result?.stdout else { return nil }
        return SurfaceMatch(rawValue: stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The first Ghostty whose scripting dictionary answers `tty` on a surface
    /// (ghostty-org/ghostty#11592, added by #11922 for the 1.4.0 milestone). EVERY RELEASE BEFORE
    /// IT CARRIES THREE PROPERTIES on a terminal - id, name, working directory - so a pass written
    /// on the device raises on every surface, is swallowed by the wraps, and matches nothing: the
    /// jump has been a directory match all along, on precisely the machines whose several tabs on
    /// one repository the device pass was written for.
    private static let ttyDictionaryVersion = [1, 4, 0]

    /// Whether THIS Ghostty can be asked for a surface's device.
    ///
    /// READ OFF THE BUNDLE THAT IS RUNNING rather than asked over an Apple event: `version` in the
    /// scripting dictionary is this same string, and asking for it would be a second round trip -
    /// and a second thing that can stop inside the permission question - before the first one can
    /// be built at all.
    @MainActor
    static func readsSurfaceTTY(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL, let bundle = Bundle(url: url) else { return false }
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        return readsSurfaceTTY(version: version)
    }

    /// COMPONENT BY COMPONENT rather than as text, or 1.10 would read as older than 1.4; missing
    /// components count as zero, so "2" is newer than 1.4.0 and "1.4" IS 1.4.0.
    ///
    /// A VERSION THAT CANNOT BE READ IS AN OLD ONE, which is the safe direction of a wrong guess:
    /// the device pass is the precision and the directory pass is the floor, so treating a new
    /// Ghostty as old costs a tie-break on a machine that would still be taken to its repository,
    /// while the reverse spends a scan on a lookup that raises on every surface.
    static func readsSurfaceTTY(version: String?) -> Bool {
        guard let version else { return false }
        let parts = version.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard !parts.isEmpty else { return false }
        for (index, floor) in ttyDictionaryVersion.enumerated() {
            let component = index < parts.count ? parts[index] : 0
            if component != floor { return component > floor }
        }
        return true
    }

    /// The script, built rather than templated because every value comes from a file on disk or
    /// from the process table.
    ///
    /// EVERY LOOKUP IS WRAPPED, because this is written against a scripting dictionary that is not
    /// this app's: a Ghostty without `terminals`, or without `working directory` or `tty` on one,
    /// raises rather than returning nothing, and an unhandled raise is an osascript that exits
    /// non-zero with the user staring at a row that did nothing. Wrapped, the same version simply
    /// reports no match and the pass below it (or the ancestor walk) takes over.
    ///
    /// THE PASSES ARE ORDERED AND EACH ONE STANDS DOWN FOR AN EARLIER ANSWER, which is the whole
    /// reason the tty pass exists: a match on the device is the surface, and a match on the
    /// directory is only the repository, so the second must never be allowed to overwrite the
    /// first. Every pass is guarded by `if matched is missing value`, so the order of the passes IS
    /// the precedence and nothing downstream can quietly invert it.
    ///
    /// IT SAYS WHICH PASS ANSWERED, and it says nothing at all when none did. The word it used to
    /// return meant "a surface was found" while every reader took it for "the terminal has the
    /// keyboard now", and it was returned even when `focus` had raised inside its own wrap - three
    /// different outcomes wearing one word, one of which then SKIPPED the ancestor walk that was
    /// the fallback for it. A refused focus now leaves by the same door as no match at all.
    static func script(directory: String, hint: String, tty: String?) -> String {
        var passes: [String] = []
        if let tty, !tty.isEmpty { passes.append(ttyPass(tty)) }
        if !directory.isEmpty { passes.append(directoryPass(directory: directory, hint: hint)) }
        return """
        tell application "Ghostty"
            set matched to missing value
            set hit to ""
        \(passes.joined(separator: "\n"))
            if matched is missing value then return ""
            try
                focus matched
            on error
                return ""
            end try
            activate
            return hit
        end tell
        """
    }

    /// One scan over Ghostty's surfaces, running `test` against each and standing down entirely
    /// for an answer an earlier pass already found.
    ///
    /// THE GUARD AND THE TWO WRAPS LIVE HERE AND NOWHERE ELSE, so a pass added later cannot be the
    /// one that forgets either: not the guard (and so overwrites a precise match with a vaguer
    /// one), nor the wrap (and so lets an older dictionary's raise out of the script).
    private static func pass(_ test: String) -> String {
        """
            if matched is missing value then
                try
                    repeat with t in terminals
                        try
        \(test)
                        end try
                    end repeat
                end try
            end if
        """
    }

    /// The exact pass: one device, one surface, so the first hit ends the search outright. Built
    /// only for a Ghostty that has the property at all (`readsSurfaceTTY`), which is what makes its
    /// marker below worth reading: `pass=dir` on a machine whose session HAS a live child is the
    /// old dictionary saying so, out loud, instead of a raise being swallowed.
    private static func ttyPass(_ tty: String) -> String {
        pass("""
                            if (tty of t) is equal to \(literal(tty)) then
                                set matched to t
                                set hit to "tty"
                                exit repeat
                            end if
        """)
    }

    /// The approximate pass, kept for the session whose child is gone or is not in Ghostty at all.
    ///
    /// THE HINT ONLY BREAKS TIES. The directory is the match; the name is consulted to choose
    /// AMONG windows that already matched it, and the first match is kept as the answer for when
    /// none of them carries the name. A tie broken arbitrarily is still the right repository.
    private static func directoryPass(directory: String, hint: String) -> String {
        pass("""
                            if (working directory of t) is equal to \(literal(directory)) then
                                if matched is missing value then
                                    set matched to t
                                    set hit to "dir"
                                end if
                                if \(literal(hint)) is not "" and (name of t) contains \(literal(hint)) then
                                    set matched to t
                                    set hit to "dir"
                                    exit repeat
                                end if
                            end if
        """)
    }

    /// An AppleScript string literal. Both interpolated values are read off disk (a checkout path,
    /// a repository name), so neither is trusted to be free of the two characters that would end
    /// the literal early and turn the rest into script.
    static func literal(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: The process table

    /// The device a process is attached to, in the form Ghostty reports it ("/dev/ttys001").
    ///
    /// ASKED OF THE KERNEL RATHER THAN OF `ps`, because this runs on a click in the panel and a
    /// spawn is both slower and one more thing that can fail; `proc_pidinfo` is the same call the
    /// ancestor walk below already makes.
    ///
    /// nil IS AN ORDINARY ANSWER, not an error: a session whose child has exited, a child owned by
    /// another user (the kernel refuses), and a process with no controlling terminal at all (a
    /// daemon, or anything under launchd) all land here, and all of them are exactly the cases the
    /// directory pass was written for.
    static func controllingTTY(of pid: pid_t) -> String? {
        guard let info = bsdInfo(pid), info.e_tdev != UInt32.max else { return nil }
        guard let name = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) else { return nil }
        let text = String(cString: name)
        // Older devname reports an unknown device as "??" rather than by returning nothing.
        guard !text.isEmpty, text != "??" else { return nil }
        return text.hasPrefix("/") ? text : "/dev/" + text
    }

    /// A process's kernel record, or nil when the pid is gone or belongs to another user.
    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    // MARK: The universal fallback

    /// Walk up from the Claude Code process until an ancestor is an application, and answer with
    /// it. FOUND RATHER THAN BROUGHT FORWARD, so this exit is carried across by the same `land` the
    /// other two are: an app that is asked for and does not arrive has to be judged wherever it was
    /// asked for, and a second copy of that judgement here is a copy that drifts.
    ///
    /// A TERMINAL EMULATOR IS AN APPLICATION AND A SHELL IS NOT, which is the whole rule and the
    /// reason this needs no list of terminal names: `claude` is a child of a shell, which is a
    /// child of the emulator, and `NSRunningApplication` answers for exactly the last of those.
    /// Bounded, because a cycle in the process table (or a pid reused underneath the walk) would
    /// otherwise be an infinite loop in the app's main actor; eight is the same ceiling the CLI's
    /// own ancestor walk uses.
    @MainActor
    private static func owningApplication(of pid: pid_t) -> NSRunningApplication? {
        var current = pid
        for _ in 0 ..< 8 {
            if let app = NSRunningApplication(processIdentifier: current),
               app.activationPolicy == .regular {
                return app
            }
            guard let parent = parentProcess(current), parent > 1, parent != current else {
                return nil
            }
            current = parent
        }
        return nil
    }

    /// A process's parent, straight from the kernel. nil when the pid is gone or belongs to another
    /// user, both of which end the walk.
    private static func parentProcess(_ pid: pid_t) -> pid_t? {
        bsdInfo(pid).map { pid_t($0.pbi_ppid) }
    }
}
