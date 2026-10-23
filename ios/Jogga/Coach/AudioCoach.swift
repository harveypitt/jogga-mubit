import Foundation

/// How much the on-device coach says during a run.
enum CueLevel: String, Codable, CaseIterable {
    case off, splitsOnly, everyKm

    init?(rawValue: String) {
        switch rawValue {
        case "off": self = .off
        case "splitsOnly": self = .splitsOnly
        case "everyKm", "full": self = .everyKm
        default: return nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let level = CueLevel(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unknown cue level: \(value)"
            )
        }
        self = level
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var label: String {
        switch self {
        case .off: return "Off"
        case .splitsOnly: return "Km splits only"
        case .everyKm: return "Splits + coaching"
        }
    }

    var footer: String {
        switch self {
        case .off:
            return "No spoken cues during a run."
        case .splitsOnly:
            return "Hear the start, each kilometre split and distance milestones, without coaching comments."
        case .everyKm:
            return "Hear splits, coaching cues and distance milestones. Coaching cues are spaced by at least five minutes."
        }
    }

    func allows(_ event: CueEvent) -> Bool {
        switch self {
        case .everyKm: return true
        case .splitsOnly:
            switch event {
            case .start, .split, .toGo500: return true
            default: return false
            }
        case .off: return false
        }
    }

    func eventForSpeaking(_ event: CueEvent) -> CueEvent {
        guard self == .splitsOnly,
              case let .split(km, seconds, totalS, _, progress) = event
        else { return event }
        return .split(
            km: km, seconds: seconds, totalS: totalS, comment: false,
            progress: progress
        )
    }

    static var current: CueLevel {
        CueLevel(rawValue: UserDefaults.standard
            .string(forKey: "jogga.coachLevel") ?? "") ?? .everyKm
    }

    static var logVisible: Bool {
        UserDefaults.standard.object(forKey: "jogga.coachLog") == nil
            || UserDefaults.standard.bool(forKey: "jogga.coachLog")
    }
}

/// Drives the cue engine during a live run and speaks cues through
/// SystemVoice. One tick per second on the main run loop.
@Observable
final class AudioCoach {
    private let recorder: RunRecorder
    private(set) var mode: CoachMode = .free
    private var voice: CoachVoice = SystemVoice()
    private var engine: CueEngine?
    private var context = RunContext(mode: .free, style: .none)
    private var queue = CueQueue()
    private var phrases = PhraseBook()
    private var log = CueLog(context: RunContext(mode: .free, style: .none))
    private var timer: Timer?

    var spokenCueCount: Int {
        log.entries.filter { $0.outcome == "spoken" }.count
    }

    init(recorder: RunRecorder) {
        self.recorder = recorder
    }

    private func attachVoice(_ voice: CoachVoice) {
        self.voice = voice
        voice.onFinish = { [weak self] in
            self?.queue.didFinishSpeaking(now: self?.recorder.elapsed ?? 0)
        }
        voice.onStats = { [weak self] stats in
            self?.applyStats(stats)
        }
        (voice as? NeuTTSVoice)?.onFailed = { [weak self] _ in
            guard let i = self?.log.entries
                .lastIndex(where: { $0.outcome == "spoken" }) else { return }
            self?.log.entries[i].outcome = "failed"
            self?.log.entries[i].reason = "voice"
        }
        (voice as? NeuTTSVoice)?.prepare()
    }

    /// Stamp synthesis metrics onto the most recent spoken entry.
    private func applyStats(_ stats: CoachVoiceStats) {
        guard let i = log.entries.lastIndex(where: { $0.outcome == "spoken" })
        else { return }
        log.entries[i].voice = stats.voice
        log.entries[i].firstAudioMs = stats.firstAudioMs
        log.entries[i].synthS = stats.synthS
        log.entries[i].audioS = stats.audioS
        log.entries[i].prefillS = stats.prefillS
        log.entries[i].genTokens = stats.genTokens
        log.entries[i].genS = stats.genS
        log.entries[i].decodeS = stats.decodeS
    }

    /// Build the context and start ticking. Called when the run starts.
    func begin(mode: CoachMode, store: RunStore) {
        self.mode = mode
        context = RunContext.make(
            mode: mode, history: store.runs, targets: store.targets,
            serverBest: store.stats.compactMapValues(\.bestS), now: .now
        )
        engine = CueEngine(context: context)
        queue = CueQueue()
        // begin() is called on the main thread when the run starts.
        let lines = MainActor.assumeIsolated {
            CoachLineProvider.lines(for: mode)
        }
        phrases = PhraseBook(
            seed: UInt64(Date.now.timeIntervalSince1970),
            lines: lines
        )
        log = CueLog(context: context)
        log.context.linesSource = lines.source
        attachVoice(CoachVoiceChoice.make())
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let level = CueLevel.current
        guard level != .off else { return }
        guard recorder.state == .running || recorder.state == .paused else { return }
        let snap = recorder.cueTrack.snapshot(
            clock: recorder.elapsed, paused: recorder.state == .paused
        )
        for decision in engine?.step(snap) ?? [] {
            switch decision {
            case .fire(let event) where !level.allows(event):
                log.entries.append(CueLog.Entry(
                    clock: snap.clock, distanceM: snap.distanceM,
                    kind: event.name,
                    text: phrases.text(for: event, context: context, now: .now),
                    outcome: "suppressed", reason: "level"
                ))
            case .fire(let event):
                let event = level.eventForSpeaking(event)
                let text = phrases.text(for: event, context: context, now: .now)
                log.entries.append(contentsOf: queue.enqueue(QueuedCue(
                    event: event, text: text,
                    enqueuedAt: snap.clock, distanceM: snap.distanceM
                )))
            case .suppress(let event, let reason):
                log.entries.append(CueLog.Entry(
                    clock: snap.clock, distanceM: snap.distanceM,
                    kind: event.name,
                    text: phrases.text(for: event, context: context, now: .now),
                    outcome: "suppressed", reason: reason
                ))
            }
        }
        let (cue, dropped) = queue.next(
            now: snap.clock, speaking: voice.isSpeaking
        )
        log.entries.append(contentsOf: dropped)
        if let cue {
            log.entries.append(CueLog.Entry(
                clock: cue.enqueuedAt, distanceM: cue.distanceM,
                kind: cue.event.name, text: cue.text,
                outcome: "spoken", reason: nil
            ))
            voice.speak(cue.text, emotion: .forEvent(cue.event))
            Analytics.capture(.cuePlayed, [
                "kind": .string(cue.event.name),
                "coach_level": .string(level.rawValue),
                "voice": .string(CoachVoiceChoice.current.rawValue),
            ])
        }
    }

    /// Run finished: stop and save the log under the run's id.
    func finish(runID: UUID) {
        timer?.invalidate()
        timer = nil
        voice.stop()
        (voice as? NeuTTSVoice)?.unload()
        log.runID = runID
        CueLogStore.save(log)
    }

    /// Run discarded: stop without saving.
    func cancel() {
        timer?.invalidate()
        timer = nil
        voice.stop()
        (voice as? NeuTTSVoice)?.unload()
        engine = nil
    }
}
