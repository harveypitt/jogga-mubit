import Foundation

struct QueuedCue: Equatable {
    var event: CueEvent
    var text: String
    var enqueuedAt: TimeInterval
    var distanceM: Double
}

/// One-cue-at-a-time speech queue: highest priority first, FIFO within equal
/// priority; pacing cues expire fast and wait their turn after other cues.
struct CueQueue {
    /// Seconds a pacing cue stays fresh.
    var pacingExpiryS: TimeInterval = 10
    /// Seconds any other cue stays fresh.
    var otherExpiryS: TimeInterval = 20
    /// Minimum gap after the last spoken cue before another pacing cue.
    var globalGapS: TimeInterval = 60
    /// Minimum gap after a split before a pacing cue.
    var afterSplitS: TimeInterval = 15

    private var items: [QueuedCue] = []
    private var speaking: QueuedCue?
    private var lastFinish: TimeInterval?
    private var lastSplitFinish: TimeInterval?

    /// Queue a cue; a queued cue of the same event kind is replaced (and
    /// logged as "replaced").
    @discardableResult
    mutating func enqueue(_ cue: QueuedCue) -> [CueLog.Entry] {
        var replaced: [CueLog.Entry] = []
        if let i = items.firstIndex(where: { $0.event.name == cue.event.name }) {
            let old = items.remove(at: i)
            replaced.append(CueLog.Entry(
                clock: old.enqueuedAt, distanceM: old.distanceM,
                kind: old.event.name, text: old.text,
                outcome: "replaced", reason: nil
            ))
        }
        let at = items.firstIndex { $0.event.priority < cue.event.priority }
            ?? items.endIndex
        items.insert(cue, at: at)
        return replaced
    }

    /// Next cue allowed to play. Expired cues drop out as "expired"; pacing
    /// cues are held back by the post-speech gaps.
    mutating func next(
        now: TimeInterval, speaking: Bool
    ) -> (cue: QueuedCue?, dropped: [CueLog.Entry]) {
        var dropped: [CueLog.Entry] = []
        items = items.filter { cue in
            let expiry = cue.event.isPacing ? pacingExpiryS : otherExpiryS
            guard now - cue.enqueuedAt > expiry else { return true }
            dropped.append(CueLog.Entry(
                clock: cue.enqueuedAt, distanceM: cue.distanceM,
                kind: cue.event.name, text: cue.text,
                outcome: "expired", reason: nil
            ))
            return false
        }
        guard !speaking else { return (nil, dropped) }
        for cue in items {
            if cue.event.isPacing {
                if let lastFinish, now - lastFinish < globalGapS { continue }
                if let lastSplitFinish, now - lastSplitFinish < afterSplitS { continue }
            }
            items.removeAll { $0 == cue }
            self.speaking = cue
            return (cue, dropped)
        }
        return (nil, dropped)
    }

    /// The currently-spoken cue finished at `now` — records the pacing gaps.
    mutating func didFinishSpeaking(now: TimeInterval) {
        lastFinish = now
        if case .split = speaking?.event { lastSplitFinish = now }
        speaking = nil
    }
}
