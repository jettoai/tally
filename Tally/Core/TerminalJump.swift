import AppKit
import Darwin
import os

/// TAKING SOMEBODY TO THE SESSION THEY JUST CLICKED, which is the whole point of a status board: a
/// row that says a session is waiting and cannot be got to has moved the hunt rather than ended it.
///
/// FOUR WAYS, in falling order of how precisely each can answer "which surface".
///
///   1. Ask Ghostty for the surface whose `tty` IS the device the session's own process is attached
///      to. A tty belongs to exactly one surface, so this cannot pick the wrong tab. ONLY A GHOSTTY
///      THAT CARRIES THAT PROPERTY IS ASKED, which is 1.4.0 and later and no version anybody is
///      running today (`readsSurfaceTTY`).
///   2. Failing that, WRITE a name nobody else can be carrying to that same device and ask which
///      surface came to be called it, then put the old name back (`focusGhostty`). Every terminal
///      reads that escape, so this answers on the versions in the world: it reaches the same one
///      surface way 1 does, by telling the session to say where it is rather than by reading a
///      property that is not published yet.
///   3. Failing that, ask for the FIRST surface whose working directory IS that checkout. Right
///      repository, arbitrary tab within it. This is what answers when the session has no child
///      process left to ask about, or is running in a terminal that is not Ghostty at all and
///      therefore appears in no surface's `tty`.
///   4. Failing that, walk the Claude Code process's ancestors until one of them is an application,
///      and activate it. This knows nothing about windows, so it lands the user in the right APP
///      rather than the right tab, and it works for every terminal there is.
///
/// WHAT IS STILL NOT ANSWERED, named rather than papered over. Way 2 rests on the title being the
/// app's to set for a moment, and there are two surfaces where it is not:
///
///   - A TAB SOMEBODY NAMED BY HAND keeps that name, and the escape is ignored (Ghostty's own
///     rename holds the title against the program running in it).
///   - A SESSION WRITING ITS OWN TITLE AS IT STREAMS can overwrite the mark inside the grace it is
///     looked for in.
///
/// Both fall through to way 3, which is the behaviour that stood before way 2 existed: the right
/// repository and an arbitrary tab within it. The first of those two is also the case way 3
/// happens to be good at, since a hand-picked name is usually the repository's. What neither of
/// them is, is silent: `pass=` in the line below says which way answered.
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

    /// How long an activation is given to settle before it is judged, and asked again another way.
    /// The same span the pick panel gives its own foreground ask (`pickPanelActivationGrace`) and
    /// for the same reason: the request does not complete on the turn it is made, so a reading
    /// taken straight afterwards is a reading of nothing.
    private static let activationGrace: Duration = .milliseconds(600)

    /// WHERE A JUMP THAT DID NOT LAND CAN BE READ AFTERWARDS, which is the only way this rides on a
    /// desktop nobody may synthesize clicks on:
    ///
    ///     log show --last 10m --predicate 'subsystem == "ai.jetto.tally"'
    ///
    /// One line per click, carrying the values that separate the ways this can go wrong from each
    /// other (`report`). At notice rather than info or debug, because those two live only in a
    /// memory buffer a stream can watch and `log show` cannot find afterwards, which is the wrong
    /// way round for a line read AFTER somebody says the keyboard did not follow. The
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
    /// controlling terminal names the surface exactly; `directory` is the checkout, which names the
    /// repository and only the repository.
    ///
    /// EVERY WAY OUT OF HERE ENDS IN `land`, because finding the surface is only half of the click:
    /// the other half is the keyboard, and since macOS 14 that half is given away rather than taken
    /// (`prepare`) - and given away is not the same as arrived, which is why each exit then looks.
    @MainActor
    static func jump(directory: String?, childPid: Int?, from handover: Handover) async {
        let directory = directory ?? ""
        let folder = (directory as NSString).lastPathComponent
        // The session's own device, which both exact passes are built on: the marked pass WRITES
        // to it (so any Ghostty at all can be asked which surface is the session's), and the
        // device pass matches on it directly.
        //
        // ONLY WHEN GHOSTTY IS THE APP THE SESSION IS ACTUALLY RUNNING IN. The mark renames
        // whatever terminal owns that device, and the only titles this app read a moment ago are
        // Ghostty's: a session living in another terminal (or under a multiplexer, whose pty is
        // not a surface at all) would be renamed by this and never renamed back. The same walk the
        // last exit takes, asked one question earlier.
        let device: String? = {
            guard let childPid, let ghostty = handover.terminal,
                  let owner = owningApplication(of: pid_t(childPid)),
                  owner.processIdentifier == ghostty.processIdentifier else { return nil }
            return controllingTTY(of: pid_t(childPid))
        }()
        // Asking Ghostty ABOUT a device is worth a pass only when this one publishes one: on an
        // older dictionary that pass raises on every surface and matches nothing, which is a scan
        // spent to learn what the version already said.
        let tty: String? = {
            guard let terminal = handover.terminal, readsSurfaceTTY(terminal) else { return nil }
            return device
        }()
        // Nothing to match on at all (no device, no recorded checkout) means nothing to ask, and
        // asking anyway would focus whichever surface happens to stand in "".
        if device != nil || !directory.isEmpty, let ghostty = handover.terminal,
           let answer = await focusGhostty(directory: directory, tty: tty, device: device) {
            await land(on: ghostty, matched: answer.match, surface: answer.surface,
                       from: handover, directory: folder)
            return
        }
        if let childPid, let owner = owningApplication(of: pid_t(childPid)) {
            await land(on: owner, matched: nil, surface: nil, from: handover, directory: folder)
            return
        }
        // Nothing could be matched, so the last useful act is to put the terminal in front and let
        // the user find the tab: better than a click that visibly does nothing. Only for an app
        // that was ALREADY running, for the reason the bundle id above is checked at all.
        if let ghostty = handover.terminal {
            await land(on: ghostty, matched: nil, surface: nil, from: handover, directory: folder)
            return
        }
        // Not one of the three had anywhere to go, and this app is holding a foreground it took for
        // the trip: it goes straight back, or a click that could do nothing would still have moved
        // somebody out of what they were in.
        handover.giveBack()
        report(handover: handover, matched: nil, surface: nil, target: nil,
               front: NSWorkspace.shared.frontmostApplication, key: NSApp.keyWindow,
               directory: folder)
    }

    /// Bring an app forward AND THEN LOOK, once, a grace later - which is the difference between a
    /// request and an outcome. `NSRunningApplication.activate(from:options:)` returns whether the
    /// system ALLOWED the ask, and its own header adds that the app may not be activated at all; the
    /// pinned panel's own foreground ask is judged after exactly this kind of pause, for exactly
    /// this reason (`PickPanelController.judgeGrace`).
    ///
    /// A JUMP THAT FOUND ITS SURFACE ASKS FOR NOTHING HERE, which is the difference between landing
    /// on a tab and landing on a terminal: the script has already brought the app forward and
    /// focused the one surface, and an activation made from this side afterwards puts the window
    /// GHOSTTY calls frontmost back on top of it (`bringForward`). So the ask is made only where no
    /// surface was found and "the right app" is the whole of what was aimed at. THE LOOKING BELOW
    /// STILL HAPPENS ON EVERY EXIT: the script's `activate` is as declinable as this one, and an
    /// outcome nobody read is the defect this grace exists for.
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
                             surface: String?, from handover: Handover, directory: String) async {
        if matched == nil { bringForward(target) }
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
        report(handover: handover, matched: matched, surface: surface, target: target, front: front,
               key: key, directory: directory)
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
    /// which pass answered, WHICH SURFACE THAT PASS LANDED ON, which checkout was being aimed at,
    /// where the foreground was before and after, and whether a window here is still holding the
    /// keyboard. Every value is public because none of them is more than a bundle id, a window
    /// class, a pass name, a surface's own identity or the LAST COMPONENT of the checkout - the
    /// path itself is deliberately still not among them, and the folder is here because "the wrong
    /// tab" and "the wrong repository" read identically without it.
    ///
    /// `sid=` IS WHAT MAKES TWO CLICKS COMPARABLE. A pass name says how the surface was found and
    /// nothing about which one it was, so two clicks on two different cards that both answered
    /// `dir` read identically whether they reached two tabs or the same tab twice - which is the
    /// exact complaint this line exists to settle.
    @MainActor
    private static func report(handover: Handover, matched: SurfaceMatch?, surface: String?,
                               target: NSRunningApplication?, front: NSRunningApplication?,
                               key: NSWindow?, directory: String) {
        log.notice("""
            jump surface=\(handover.surface, privacy: .public) \
            pass=\(matched?.rawValue ?? "none", privacy: .public) \
            sid=\(surface ?? "none", privacy: .public) \
            dir=\(directory.isEmpty ? "none" : directory, privacy: .public) \
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
    ///
    /// NO WINDOW IS REORDERED BY THIS. `activateAllWindows` is documented to bring ALL of the app's
    /// windows forward, which on a terminal with several windows open is a request to put every one
    /// of them over whichever one the jump just picked out - the wrong tab arriving on top, by this
    /// app's own hand, after the right one had been focused. The default is the app coming forward
    /// with the window IT considers frontmost, which is what a person clicking a status row means,
    /// and is all this call is for now that the exits that found a surface no longer make it.
    @discardableResult
    @MainActor
    private static func bringForward(_ app: NSRunningApplication) -> Bool {
        NSApp.yieldActivation(to: app)
        return app.activate(from: .current, options: []) || app.activate(options: [])
    }

    // MARK: Ghostty

    /// The script sent to Ghostty, the version gate in front of it and the marker that comes back,
    /// all in `TerminalJumpScript.swift`: this file is the foreground and the process table, and
    /// that one is a conversation with a dictionary that is not this app's.
    private static func runningApplication(_ bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
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
