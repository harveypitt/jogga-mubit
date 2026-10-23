import SwiftUI

/// Home tab: date header, coach "next run" card, activity, goals, recent runs, big Start.
struct RunTabView: View {
    @Environment(RunStore.self) private var store
    @Environment(RunRecorder.self) private var recorder
    @Environment(AudioCoach.self) private var coach
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showActiveRun = false
    @State private var showSettings = false
    @State private var targetSheet: TargetRoute?
    @State private var mode: CoachMode?
    @State private var breathe = false

    private struct TargetRoute: Identifiable {
        var distance: String
        var id: String { distance }
    }

    var body: some View {
        NavigationStack {
            JoggaScreen {
                header
                nextRunCard
                ActivityCard(runs: store.runs)
                goals
                recent
                Color.clear.frame(height: 150)
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 14) {
                    if CueLevel.current != .off { todayPicker }
                    startButton
                }
                    .frame(maxWidth: .infinity)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .fullScreenCover(isPresented: $showActiveRun) {
                ActiveRunView()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(item: $targetSheet) { route in
                TargetSheet(distance: route.distance)
            }
            .onAppear {
                if recorder.state == .countdown || recorder.state == .running { showActiveRun = true }
            }
            .onChange(of: recorder.state) { _, state in
                if state == .countdown { showActiveRun = true }
            }
            .task {
                CoachLineProvider.generate(
                    mode: mode ?? defaultMode, store: store
                )
            }
            .task(id: store.hasSyncedMe) {
                guard store.hasSyncedMe, store.targets.isEmpty,
                      recorder.state == .idle, !showActiveRun else { return }
                try? await Task.sleep(for: .milliseconds(900))
                guard store.hasSyncedMe, store.targets.isEmpty,
                      recorder.state == .idle, !showActiveRun else { return }
                targetSheet = TargetRoute(distance: "5k")
            }
            .onChange(of: mode) { _, new in
                CoachLineProvider.generate(mode: new ?? defaultMode, store: store)
            }
        }
        .trackScreen(.run)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Date.now.formatted(.dateTime.day().month(.wide)).uppercased())
                .font(.footnote.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(Color.brand)
            Text(Date.now.formatted(.dateTime.weekday(.wide)))
                .font(Jogga.rounded(.largeTitle, weight: .bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    // MARK: Next run card

    @ViewBuilder
    private var nextRunCard: some View {
        let today = Activity.runsToday(store.runs, now: .now, calendar: Activity.calendar())
        if let next = store.latestCoach?.payload.next {
            Card(spacing: 14) {
                HStack {
                    Text(today.isEmpty ? "Next run" : "Tomorrow").statLabel()
                    Spacer()
                    Chip(text: next.kind.capitalized)
                }
                if !today.isEmpty { doneToday(today) }
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Metric(value: Fmt.kmShort(next.km), unit: "km", size: 56, weight: .bold)
                    Metric(value: Fmt.pace(Double(next.pace)), unit: "/km", size: 30)
                        .foregroundStyle(Color.brand)
                }
                Text(next.why)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Card(spacing: 10) {
                Text("Next run").statLabel()
                Text("Go for a run and I'll plan the next one.")
                    .font(Jogga.rounded(.title3, weight: .medium))
                Text("After each run you'll get a pace and distance to aim for.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func doneToday(_ runs: [Run]) -> some View {
        let km = runs.reduce(0) { $0 + $1.distanceM }
        return Label {
            Text("Done today · \(Fmt.km(km)) km")
                .font(.subheadline.weight(.semibold).monospacedDigit())
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.brand)
        }
    }

    // MARK: Recent

    @ViewBuilder
    private var recent: some View {
        if !store.runs.isEmpty {
            Text("Recent")
                .font(Jogga.rounded(.title3, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.top, 10)
            ForEach(store.runs.prefix(3)) { run in
                NavigationLink {
                    RunSummaryView(run: run)
                } label: {
                    RunCard(run: run)
                }
                .buttonStyle(PressableStyle(scale: 0.98))
                .tint(.primary)
            }
        }
    }

    // MARK: Goals

    @ViewBuilder
    private var goals: some View {
        let keys = RunMath.standardDistances.map(\.key).filter { store.targets[$0] != nil }
        if keys.isEmpty {
            Button {
                targetSheet = TargetRoute(distance: "5k")
            } label: {
                HStack {
                    Image(systemName: "scope")
                        .font(.title3)
                        .foregroundStyle(Color.brand)
                    Text("Set a target time")
                        .font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .card()
            }
            .buttonStyle(PressableStyle(scale: 0.98))
            .tint(.primary)
        } else {
            ForEach(keys, id: \.self) { key in
                Button {
                    targetSheet = TargetRoute(distance: key)
                } label: {
                    goalCard(key: key, target: store.targets[key] ?? 0)
                }
                .buttonStyle(PressableStyle(scale: 0.98))
                .tint(.primary)
            }
        }
    }

    private func goalCard(key: String, target: Int) -> some View {
        let efforts = store.runs.compactMap { $0.efforts[key] }
        let best = store.stats[key]?.bestS ?? efforts.min()
        let count = store.stats[key]?.count ?? efforts.count
        return Card(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.distanceName(key))
                    .font(Jogga.rounded(.title2, weight: .bold))
                Spacer()
                Text("Target \(RunMath.formatTime(Double(target)))")
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                Metric(value: best.map(RunMath.formatTime) ?? "–", size: 34)
                Text("best").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if let best {
                    let gap = best - Double(target)
                    Text(gap > 0 ? "\(RunMath.formatTime(gap)) to go" : "Target beaten")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(gap > 0 ? Color.primary : Color.brand)
                }
            }
            Bar(fraction: progress(best: best, target: target))
            Text(count == 1 ? "1 run" : "\(count) runs")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// 1.0 at target; empty when best is 25% or more slower than target.
    private func progress(best: Double?, target: Int) -> Double {
        guard let best, best > 0, target > 0 else { return 0 }
        return 1 - (best / Double(target) - 1) / 0.25
    }

    // MARK: Start button

    private var startButton: some View {
        Button {
            recorder.reset()
            coach.begin(mode: mode ?? defaultMode, store: store)
            recorder.beginCountdown(title: modeLabel)
            showActiveRun = true
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.brand.opacity(0.18), lineWidth: 10)
                    .frame(width: 112, height: 112)
                    .scaleEffect(breathe ? 1.06 : 1)
                Circle()
                    .fill(Color.brand.gradient)
                    .frame(width: 92, height: 92)
                    .shadow(color: Color.brand.opacity(0.35), radius: 16, y: 8)
                Text("GO")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(PressableStyle())
        .padding(.bottom, 20)
        .accessibilityLabel("Start run")
        .sensoryFeedback(.impact(weight: .medium), trigger: showActiveRun)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }

    // MARK: Today selector

    /// Planned session when the coach has one, else a free run.
    private var defaultMode: CoachMode {
        if let next = store.latestCoach?.payload.next {
            return .plan(kind: next.kind, km: next.km,
                         paceSPerKm: Double(next.pace))
        }
        return .free
    }

    private var todayPicker: some View {
        Menu {
            if let next = store.latestCoach?.payload.next {
                Button {
                    mode = .plan(kind: next.kind, km: next.km,
                                 paceSPerKm: Double(next.pace))
                } label: {
                    Text("\(next.kind.capitalized) \(Fmt.kmShort(next.km)) km · \(Fmt.pace(Double(next.pace)))/km")
                }
            }
            ForEach(RunMath.standardDistances.map(\.key), id: \.self) { key in
                if store.targets[key] != nil {
                    Button("Race \(Fmt.distanceName(key))") {
                        mode = .race(distanceKey: key)
                    }
                }
            }
            Button("Free run") { mode = .free }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "waveform")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.brand)
                Text(modeLabel)
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .transaction(value: modeLabel) { $0.animation = nil }
        }
        .accessibilityLabel("Today's run: \(modeLabel)")
    }

    private var modeLabel: String {
        switch mode ?? defaultMode {
        case let .plan(kind, km, pace):
            return "\(kind.capitalized) \(Fmt.kmShort(km)) km · \(Fmt.pace(pace))/km"
        case let .race(key):
            return "Race \(Fmt.distanceName(key))"
        case .free:
            return "Free run"
        }
    }
}
