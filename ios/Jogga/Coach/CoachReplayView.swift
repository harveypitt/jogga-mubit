import SwiftUI

/// One cue log row: distance, the cue text, and an outcome badge for
/// anything that wasn't spoken.
struct CueRowView: View {
    var entry: CueLog.Entry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(RunMath.formatDistance(entry.distanceM))
                .font(Jogga.numerals(13))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                    .font(.subheadline)
                    .foregroundStyle(entry.outcome == "spoken" ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let meta = entry.voiceMeta {
                    Text(meta)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if entry.outcome != "spoken" {
                Text(entry.reason.map { "\(entry.outcome): \($0)" } ?? entry.outcome)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(.secondary)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Replays a finished run through the cue engine under a chosen mode —
/// what the coach would have said, with optional speech.
struct CoachReplayView: View {
    let run: Run

    @Environment(RunStore.self) private var store
    @State private var mode: CoachMode = .free
    @State private var log: CueLog?
    @State private var voice: CoachVoice = CoachVoiceChoice.make()
    @State private var listening = false

    private var spokenEntries: [CueLog.Entry] {
        (log?.entries ?? []).filter { $0.outcome == "spoken" }
    }

    var body: some View {
        JoggaScreen {
            Card(spacing: 12) {
                HStack {
                    Text("Coach replay").statLabel()
                    Spacer()
                    modePicker
                }
                if let log {
                    ForEach(Array(log.entries.enumerated()), id: \.offset) { _, entry in
                        Button {
                            voice.onFinish = nil
                            voice.speak(entry.text, emotion: .neutral)
                        } label: {
                            CueRowView(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button {
                listening ? stopListening() : listen()
            } label: {
                Label(listening ? "Stop" : "Listen",
                      systemImage: listening ? "stop.fill" : "play.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(spokenEntries.isEmpty)
        }
        .navigationTitle("Replay")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            mode = defaultMode
            simulate()
            (voice as? NeuTTSVoice)?.prepare()
        }
        .onDisappear { voice.stop() }
    }

    private var defaultMode: CoachMode {
        if let key = run.primaryDistance, store.targets[key] != nil {
            return .race(distanceKey: key)
        }
        if let next = store.latestCoach?.payload.next {
            return .plan(kind: next.kind, km: next.km,
                         paceSPerKm: Double(next.pace))
        }
        return .free
    }

    private var modePicker: some View {
        Menu {
            ForEach(RunMath.standardDistances.map(\.key), id: \.self) { key in
                if store.targets[key] != nil {
                    Button("Race \(Fmt.distanceName(key))") {
                        mode = .race(distanceKey: key)
                        simulate()
                    }
                }
            }
            if let next = store.latestCoach?.payload.next {
                Button("\(next.kind.capitalized) \(Fmt.kmShort(next.km)) km") {
                    mode = .plan(kind: next.kind, km: next.km,
                                 paceSPerKm: Double(next.pace))
                    simulate()
                }
            }
            Button("Free run") {
                mode = .free
                simulate()
            }
        } label: {
            HStack(spacing: 4) {
                Text(modeLabel)
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.brand)
        }
    }

    private var modeLabel: String {
        switch mode {
        case let .plan(kind, km, _):
            return "\(kind.capitalized) \(Fmt.kmShort(km)) km"
        case let .race(key):
            return "Race \(Fmt.distanceName(key))"
        case .free:
            return "Free run"
        }
    }

    private func simulate() {
        let history = store.runs.filter { $0.startedAt < run.startedAt }
        let context = RunContext.make(
            mode: mode, history: history, targets: store.targets,
            serverBest: [:], now: run.startedAt
        )
        log = CueSimulator.run(
            samples: CueSimulator.samples(for: run),
            context: context, level: CueLevel.current, now: run.startedAt,
            seed: UInt64(run.startedAt.timeIntervalSince1970),
            lines: CoachLineProvider.lines(for: mode)
        )
    }

    private func listen() {
        let entries = spokenEntries
        guard !entries.isEmpty else { return }
        var index = 0
        listening = true
        func next() {
            guard listening, index < entries.count else {
                listening = false
                return
            }
            let entry = entries[index]
            index += 1
            voice.speak(entry.text, emotion: .neutral)
        }
        voice.onFinish = { DispatchQueue.main.async { next() } }
        next()
    }

    private func stopListening() {
        listening = false
        voice.onFinish = nil
        voice.stop()
    }
}
