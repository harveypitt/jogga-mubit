import CoreLocation
import Foundation

/// Runs the cue pipeline offline over a sample list — used by tests and by
/// the coach replay view. Speech is simulated: each spoken cue blocks for
/// 0.35 s plus ~2.6 words per second.
enum CueSimulator {
    static func run(
        samples: [RunMath.Sample], context: RunContext,
        tuning: CueTuning = .init(), level: CueLevel = .everyKm, now: Date,
        seed: UInt64 = 0, lines: CoachLines = .defaults
    ) -> CueLog {
        let track = CueTrack()
        var engine = CueEngine(context: context, tuning: tuning)
        var queue = CueQueue()
        var phrases = PhraseBook(seed: seed, lines: lines)
        var log = CueLog(context: context)
        let sorted = samples.sorted { $0.t < $1.t }
        guard let end = sorted.last?.t else { return log }

        var index = 0
        var previousRaw: RunMath.Sample?
        var busyUntil = -Double.greatestFiniteMagnitude
        var clock = 0.0
        while clock <= end {
            // Same acceptance filter as the live recorder; a > 10 s gap
            // between raw samples is a pause.
            while index < sorted.count, sorted[index].t <= clock {
                let s = sorted[index]
                if index > 0, s.t - sorted[index - 1].t > 10 {
                    track.breakLeg()
                }
                if RunMath.accept(s, previousRaw: previousRaw, receivedAt: s.t) {
                    track.ingest(s)
                }
                previousRaw = s
                index += 1
            }
            // Inside a > 10 s sample gap counts as paused.
            var paused = false
            if index > 0, index < sorted.count,
               sorted[index].t - sorted[index - 1].t > 10,
               clock >= sorted[index - 1].t, clock < sorted[index].t {
                paused = true
            }

            let snap = track.snapshot(clock: clock, paused: paused)
            for decision in engine.step(snap) {
                switch decision {
                case .fire(let event) where !level.allows(event):
                    log.entries.append(CueLog.Entry(
                        clock: snap.clock, distanceM: snap.distanceM,
                        kind: event.name,
                        text: phrases.text(for: event, context: context, now: now),
                        outcome: "suppressed", reason: "level"
                    ))
                case .fire(let event):
                    let event = level.eventForSpeaking(event)
                    let text = phrases.text(for: event, context: context, now: now)
                    log.entries.append(contentsOf: queue.enqueue(QueuedCue(
                        event: event, text: text,
                        enqueuedAt: snap.clock, distanceM: snap.distanceM
                    )))
                case .suppress(let event, let reason):
                    log.entries.append(CueLog.Entry(
                        clock: snap.clock, distanceM: snap.distanceM,
                        kind: event.name,
                        text: phrases.text(for: event, context: context, now: now),
                        outcome: "suppressed", reason: reason
                    ))
                }
            }
            let (cue, dropped) = queue.next(
                now: clock, speaking: clock < busyUntil
            )
            log.entries.append(contentsOf: dropped)
            if let cue {
                log.entries.append(CueLog.Entry(
                    clock: cue.enqueuedAt, distanceM: cue.distanceM,
                    kind: cue.event.name, text: cue.text,
                    outcome: "spoken", reason: nil
                ))
                let words = Double(cue.text.split(separator: " ").count)
                let finish = clock + 0.35 + words / 2.6
                queue.didFinishSpeaking(now: finish)
                busyUntil = finish
            }
            clock += 1
        }
        return log
    }

    /// Replay samples for a stored run: route only, no elevation signal.
    static func samples(for run: Run) -> [RunMath.Sample] {
        run.route.map {
            RunMath.Sample(
                t: $0.t, coordinate: $0.coordinate,
                horizontalAccuracy: 5, altitude: $0.alt ?? 0,
                verticalAccuracy: $0.alt == nil ? -1 : 5
            )
        }
    }
}
