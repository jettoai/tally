import Foundation

// WHEN THE FOOTPRINT PASS RUNS, and who is asking for it. Lifted out of ProcessFootprintStore.swift
// past the repo's 500-line cap, along the seam the class already had inside it: over there is what
// a tick READS and what it publishes, and here is the audience, the two rates and the one piece of
// cache that belongs to the panel rather than to the reading (the ports).
//
// THE PASS NEVER STOPS, WHICH IS THE WHOLE OF WHAT THESE FOUR DECIDE. It used to run only while a
// surface was up, and the trend line is why that changed: a history that exists only while somebody
// is looking is empty at the exact moment it is wanted. What a closed panel switches off is the
// RATE and the ports, not the reading (`ProcessFootprintStore` states the measurement).
//
// AND SINCE 2026-09-02, ONE MORE THING THAT IS ABOUT A TICK RATHER THAN ABOUT A CARD: what every
// card says once every card has been read (`painted`). The store passed the cap again when the
// orphan reclaim was wired into the pass, and this is the piece that came out - not because it is
// small, but because it is the only part of `sample()` that cannot be written until the loop above
// it has finished, which is the same "about the tick rather than about the reading" line this file
// was split along in the first place.

/// One card's reading, held until every card has been read.
///
/// A NAMED TYPE RATHER THAN THE TUPLE IT USED TO BE, because it now crosses a file boundary and a
/// four-field tuple spelled out at both ends is two places for a field to change alone.
struct FootprintMeasurement {
    var key: String
    var footprint: ProcessFootprint
    /// How long the rate on it covers, or nil when there is no rate yet. Not the sampler's
    /// interval: the two rates meet inside a bucket every time somebody opens the board
    /// (`FootprintTrendSample.seconds`).
    var interval: TimeInterval?
    /// What the session said it was doing, which is what a warning is decided against.
    var idle: Bool
}

extension ProcessFootprintStore {

    /// WHAT EACH CARD ACTUALLY SAYS, out of what each card READ.
    ///
    /// THREE THINGS IN ONE PASS BECAUSE THEY HAVE TO AGREE. The warnings, the capture's fixtures and
    /// the trend point are all about the same figures, and any two of them a step apart is a card
    /// contradicting itself: a warning painted after the fixtures would be judging invented numbers,
    /// and a ring fed the raw reading under a fixture figure draws a line that ends somewhere the
    /// printed number is not.
    ///
    /// AND NONE OF IT CAN HAPPEN INSIDE THE LOOP THAT READS THE CARDS, which is why this exists at
    /// all: two of its inputs are about the whole BOARD rather than about one card - which tree
    /// holds the most memory (the third witness the memory tier needs), and which cards survived to
    /// be drawn at all (what the capture's fixtures are handed out against).
    ///
    /// - Parameters:
    ///   - pressure: what the machine said about its own memory, once for the whole tick so that
    ///     "the machine was short when this was measured" means one instant on every card.
    ///   - trends: the ring, offered every card's DRAWN footprint and keeping one point in five.
    /// - Returns: what each card draws, and the warning state to carry into the next tick.
    func painted(_ measurements: [FootprintMeasurement], pressure: MachineMemoryPressure,
                 trends: inout FootprintHistory,
                 at now: Date) -> (drawn: [String: ProcessFootprint],
                                   alerts: [String: FootprintAlertState]) {
        var drawn: [String: ProcessFootprint] = [:]
        var alerting: [String: FootprintAlertState] = [:]
        // WHICH FIXTURE EACH CARD GETS DURING A CAPTURE, decided once for the whole tick so a
        // session keeps the same one from tick to tick, and empty on every ordinary launch
        // (`DemoUsage.footprint`).
        //
        // KEYED BY THE CARDS THAT WILL BE DRAWN rather than by the roster the tick started from,
        // which is the fix for a fixture that could go missing: two guards inside the reading loop
        // (`ProcessFootprintStore.sample`) skip a root whose session has just ended or whose tree
        // is all Tally's own, and an index handed out before them left a hole - the first fixture
        // is the WARNED card, the one state a capture
        // cannot wait for, and nothing about the remaining three cards said one was absent. Decided
        // on the survivors, every fixture is on the board whenever there are cards for them.
        let demoOrder = DemoUsage.isActive ? DemoUsage.fixtureOrder(of: measurements.map(\.key))
                                           : [:]
        // WHICH TREE HOLDS THE MOST, which the memory tier's third witness is decided against: a
        // machine being short says nothing about WHICH session to point at, and the same tick's own
        // figures are the only comparison available that costs nothing
        // (`FootprintAlarm.saturatedMemoryShare`). Ties broken on the key so the answer cannot
        // change from tick to tick while nothing else does.
        let heaviest = measurements.sorted {
            $0.footprint.memoryBytes == $1.footprint.memoryBytes
                ? $0.key < $1.key : $0.footprint.memoryBytes > $1.footprint.memoryBytes
        }.first?.key
        for one in measurements {
            var footprint = one.footprint
            // The warnings are decided from THIS tick's reading and the ticks before it, then put
            // back on the same reading: what the card draws and what the card warns about are one
            // value, so they cannot be a tick apart.
            //
            // A TICK IS NOT ALWAYS TWO SECONDS, which is why the rule is handed the INSTANT rather
            // than counting ticks (`FootprintAlarm`): five of them used to mean ten seconds with
            // the board open and fifty behind it, and a warning could be earned by four fast
            // readings and one slow one - evidence over two different spans added together.
            //
            // DECIDED HERE RATHER THAN IN THE READING LOOP, which is where it used to be, because
            // one of its witnesses is about the whole BOARD and no card can be asked about that
            // until every card has been read. Painted before the fixtures below for the same reason the
            // ring is offered the drawn footprint: a capture states its own warnings outright, and
            // an alarm run afterwards would be judging invented numbers.
            let state = FootprintAlarm.advance(alertState[one.key] ?? FootprintAlertState(),
                                               reading: footprint, idle: one.idle, at: now,
                                               pressure: pressure,
                                               largestHolder: one.key == heaviest)
            alerting[one.key] = state
            footprint.alerts = state.alerts
            // FIXTURE READINGS FOR A CAPTURE, and only for one: the flag lives in the volatile
            // argument domain, so an ordinary launch never takes this branch (`DemoUsage`).
            //
            // PAINTED BEFORE THE RING RATHER THAN AFTER IT, which is the whole of what makes the
            // card coherent. Painted after, the fixture figure was the last point of a line drawn
            // from the machine's REAL readings, and the sparkline measures from zero to its own
            // maximum (`FootprintSparkline.points`): a fixture memory of 4.1 GB over a real series
            // of 200 MB flattened every kept point against the floor and stood the last one
            // vertically at the top, on all three metrics, on every fixture card. What a shot is
            // for is what the card looks like, so the fixture reading is the reading - it is what
            // the ring is offered below, and the shapes are as fabricated as the figures.
            if let index = demoOrder[one.key] { footprint = DemoUsage.footprint(footprint, at: index) }
            drawn[one.key] = footprint
            // THE RING IS OFFERED EVERY TICK AND KEEPS ONE POINT IN FIVE OF THEM, folding the rest
            // into it, which is what holds the series to one cadence AND to one meaning across two
            // rates (`FootprintTrendSeries.record`).
            //
            // AND THE RING IS OFFERED THE FOOTPRINT THE CARD DRAWS, not the raw reading it was
            // built from. The two are the same values on every ordinary launch - the fields are
            // copied from these very numbers - and where they are not (a capture's fixtures), a
            // line drawn from one and a figure printed from the other is a card contradicting
            // itself.
            if let interval = one.interval, let percent = footprint.cpuPercent {
                trends.record(FootprintTrendSample(cpuPercent: percent,
                                                   seconds: interval,
                                                   memoryBytes: footprint.memoryBytes,
                                                   processes: footprint.processes),
                              for: one.key, at: now)
            }
        }
        return (drawn, alerting)
    }


    /// Start sampling for the life of the process, at the background rate. Called once at launch,
    /// exactly as the roster's own observer is (`SessionRosterStore.install`), and for the same
    /// reason: a registration that is missed is a feature that silently never runs.
    func install() { retime() }

    /// A surface showing the board has appeared. Samples at once, because what somebody just opened
    /// has to say something before the first tick rather than after it, and resets the tick count so
    /// that first sample is the one that reads the ports.
    func beginViewing() {
        if viewers == 0 { ticks = 0 }
        viewers += 1
        retime()
        sample()
    }

    /// The last surface showing the board has gone. The readings go on being taken, slower: what is
    /// dropped is only what is exclusively the panel's, which is the ports (nothing draws them, and
    /// a pid the machine hands out again must never inherit them).
    func endViewing() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        retime()
        ports = [:]
    }

    /// Put the timer on the rate the current audience deserves, and only when that rate changed.
    private func retime() {
        let wanted = viewers > 0 ? Self.visibleInterval : Self.backgroundInterval
        guard timerInterval != wanted else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: wanted, repeats: true) { _ in
            Task { @MainActor in ProcessFootprintStore.shared.sample() }
        }
        // `.common`, so the readings keep coming while a menu or a scroll is tracking - the same
        // reason the roster's own timer is registered that way.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        timerInterval = wanted
    }
}
