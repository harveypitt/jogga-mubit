import MapKit
import SwiftUI

/// Run summary: title, route map, headline stats, efforts, coach, splits.
struct RunSummaryView: View {
    let run: Run
    /// True straight after recording: uploads the run and waits for the coach.
    var isNew = false
    var onDone: (() -> Void)?

    @Environment(RunStore.self) private var store
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var coach: CoachNote?
    @State private var coachLoading = true
    @State private var showMap = false
    @State private var showDiscardConfirm = false
    @State private var showDeleteConfirm = false

    private var segments: [RoutePace.Segment] { RoutePace.segments(run.route) }

    var body: some View {
        Group {
            if isNew {
                NavigationStack {
                    content
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Discard") { showDiscardConfirm = true }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { onDone?() ?? dismiss() }
                                    .fontWeight(.semibold)
                            }
                        }
                        .confirmationDialog("Discard this run?",
                                            isPresented: $showDiscardConfirm,
                                            titleVisibility: .visible) {
                            Button("Discard Run", role: .destructive) {
                                store.delete(run)
                                onDone?()
                            }
                        } message: {
                            Text("It won't be saved or used for coaching.")
                        }
                }
            } else {
                content
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Button("Delete Run", systemImage: "trash",
                                       role: .destructive) {
                                    showDeleteConfirm = true
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                        }
                    }
                    .confirmationDialog("Delete this run?",
                                        isPresented: $showDeleteConfirm,
                                        titleVisibility: .visible) {
                        Button("Delete Run", role: .destructive) {
                            store.delete(run)
                            dismiss()
                        }
                    } message: {
                        Text("This removes it from your history and coaching.")
                    }
            }
        }
        .task { await loadCoach() }
        .trackScreen(isNew ? .runSummary : .runDetail)
    }

    private var content: some View {
        JoggaScreen {
            header
            mapCard
            statsCard
            if !run.efforts.isEmpty { effortBadges }
            coachCard
            if !run.splits.isEmpty { splitsCard }
            if CueLevel.logVisible { coachLogCard }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func loadCoach() async {
        if isNew {
            coach = await store.record(run)
        } else {
            struct Response: Decodable { var coach: CoachNote? }
            let response: Response? = try? await api.get("runs/\(run.id.uuidString.lowercased())")
            coach = response?.coach
        }
        withAnimation(.smooth) { coachLoading = false }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(run.startedAt.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute())
                .uppercased())
                .font(.footnote.weight(.semibold))
                .tracking(0.4)
                .foregroundStyle(Color.brand)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Fmt.runTitle(run.startedAt))
                    .font(Jogga.rounded(.largeTitle, weight: .bold))
                if run.source == StravaImporter.source { StravaBadge() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    // MARK: Map

    @ViewBuilder
    private var mapCard: some View {
        if run.route.count > 1 {
            Map(initialPosition: .rect(run.routeRect(padding: 0.2)), interactionModes: []) {
                PaceRoute(run: run, segments: segments)
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .frame(height: 240)
            .accessibilityLabel("Route map")
            .overlay { Color.clear.contentShape(Rectangle()).onTapGesture { showMap = true } }
            .overlay(alignment: .topTrailing) {
                Button {
                    showMap = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.footnote.weight(.bold))
                        .frame(width: 34, height: 34)
                        .background(.regularMaterial, in: Circle())
                }
                .tint(.primary)
                .padding(10)
                .accessibilityLabel("Open full map")
            }
            .clipShape(RoundedRectangle(cornerRadius: Jogga.cardRadius, style: .continuous))
            .fullScreenCover(isPresented: $showMap) { RouteMapView(run: run) }
        }
    }

    // MARK: Stats

    private var statsCard: some View {
        Card(spacing: 18) {
            StatCell(label: "Distance", value: Fmt.km(run.distanceM), unit: "km", size: 56)
            HStack(alignment: .top) {
                StatCell(label: "Time", value: RunMath.formatTime(run.movingS))
                    .frame(maxWidth: .infinity, alignment: .leading)
                StatCell(label: "Avg pace", value: Fmt.pace(run.averagePace), unit: "/km")
                    .frame(maxWidth: .infinity, alignment: .leading)
                StatCell(label: "Climb", value: "\(Int(run.gainM.rounded()))", unit: "m")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var effortBadges: some View {
        let keys = RunMath.standardDistances.map(\.key).filter { run.efforts[$0] != nil }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(keys, id: \.self) { key in
                    let seconds = run.efforts[key] ?? 0
                    let isBest = isBest(key: key, seconds: seconds)
                    HStack(spacing: 6) {
                        if isBest { Image(systemName: "star.fill").font(.caption) }
                        Text(Fmt.distanceName(key)).fontWeight(.bold)
                        Text(RunMath.formatTime(seconds)).monospacedDigit()
                        if isBest { Text("Best").fontWeight(.bold) }
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .foregroundStyle(isBest ? Color.white : Color.brand)
                    .background(isBest ? Color.brand : Color.brand.opacity(0.14),
                                in: Capsule())
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func isBest(key: String, seconds: Double) -> Bool {
        let others = store.runs.filter { $0.id != run.id }.compactMap { $0.efforts[key] }
        return others.allSatisfy { seconds <= $0 }
    }

    // MARK: Coach

    private var coachCard: some View {
        Card(spacing: 14) {
            HStack {
                Label("Coach", systemImage: "figure.run.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(Color.brand)
                Spacer()
                if let coach { Chip(text: coach.payload.pacingLabel) }
            }
            if coachLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Looking over your run…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } else if let coach {
                if let wentWell = coach.payload.wentWell, let workOn = coach.payload.workOn {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Went well").statLabel()
                            Text(wentWell)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Work on").statLabel()
                            Text(workOn)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let result = coach.payload.result {
                        Text(result)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(coach.payload.feedback)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Next time").statLabel()
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Metric(value: Fmt.kmShort(coach.payload.next.km), unit: "km", size: 30,
                               weight: .bold)
                        Metric(value: Fmt.pace(Double(coach.payload.next.pace)), unit: "/km",
                               size: 22)
                            .foregroundStyle(Color.brand)
                        Spacer()
                        Chip(text: coach.payload.next.kind.capitalized)
                    }
                    Text(coach.payload.next.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if coach.source == "llm" {
                    Divider()
                    CoachFeedbackRow(runID: run.id)
                }
            } else {
                Text(isNew ? "Your coach will reply once you're back online."
                    : run.isImported ? "Imported from Strava. Your coach uses it as training history."
                    : "No coach notes for this run.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Splits

    private var splitsCard: some View {
        let paces = run.splits.map { $0.movingS / max($0.distanceM / 1000, 0.001) }
        let fastest = paces.min() ?? 0
        let slowest = paces.max() ?? 0
        return Card(spacing: 14) {
            HStack {
                Text("Splits").statLabel()
                Spacer()
                Text("Pace").statLabel().frame(width: 58, alignment: .trailing)
                Text("Elev").statLabel().frame(width: 46, alignment: .trailing)
            }
            ForEach(Array(run.splits.enumerated()), id: \.offset) { index, split in
                let pace = paces[index]
                let fraction = slowest > fastest
                    ? 0.35 + 0.65 * (slowest - pace) / (slowest - fastest)
                    : 1
                HStack(spacing: 12) {
                    Text(split.distanceM >= 999 ? "\(index + 1)"
                        : String(format: "%.2f", split.distanceM / 1000))
                        .font(Jogga.numerals(15))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .leading)
                    Bar(fraction: fraction, height: 8,
                        tint: pace == fastest ? .brand : .brand.opacity(0.55))
                    Text(Fmt.pace(pace))
                        .font(Jogga.numerals(16))
                        .frame(width: 58, alignment: .trailing)
                    Text(elevationText(split))
                        .font(Jogga.numerals(13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Kilometre \(index + 1), \(Fmt.pace(pace)) per km, "
                    + "\(Int(split.gainM)) metres up")
            }
        }
    }

    // MARK: Coach log

    private var coachLogCard: some View {
        let log = CueLogStore.load(runID: run.id)
        return Card(spacing: 12) {
            HStack {
                Text("Coach log").statLabel()
                Spacer()
                if let log { Text(logModeLabel(log.context.mode)).statLabel() }
            }
            if let log, !log.entries.isEmpty {
                ForEach(Array(log.entries.enumerated()), id: \.offset) { _, entry in
                    CueRowView(entry: entry)
                }
            } else {
                Text("No cues recorded for this run.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Divider()
            NavigationLink {
                CoachReplayView(run: run)
            } label: {
                HStack {
                    Label("Replay coach", systemImage: "play.circle")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .tint(.primary)
        }
    }

    private func logModeLabel(_ mode: CoachMode) -> String {
        switch mode {
        case let .plan(kind, km, _):
            return "\(kind.capitalized) \(Fmt.kmShort(km)) km"
        case let .race(key):
            return "Race \(Fmt.distanceName(key))"
        case .free:
            return "Free run"
        }
    }

    private func elevationText(_ split: Run.Split) -> String {
        let net = Int((split.gainM - split.lossM).rounded())
        if net > 0 { return "↑\(net)" }
        if net < 0 { return "↓\(-net)" }
        return "–"
    }
}

private struct CoachFeedbackRow: View {
    let runID: UUID
    @State private var selection: Int?

    init(runID: UUID) {
        self.runID = runID
        let storedVote = UserDefaults.standard.object(forKey: Self.voteKey(runID)) as? Int
        _selection = State(initialValue: storedVote == 1 || storedVote == 2 ? storedVote : nil)
    }

    private var voteKey: String { Self.voteKey(runID) }
    private var shownKey: String { "coachFeedbackShown.\(runID.uuidString.lowercased())" }

    var body: some View {
        HStack(spacing: 8) {
            Text(selection == nil ? "Was this helpful?" : "Thanks for the feedback")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .animation(.smooth, value: selection)
            Spacer()
            Button {
                select(1)
            } label: {
                Image(systemName: selection == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .foregroundStyle(selection == 1 ? Color.brand : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(selection != nil)
            .accessibilityLabel("Helpful")

            Button {
                select(2)
            } label: {
                Image(systemName: selection == 2 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .foregroundStyle(.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(selection != nil)
            .accessibilityLabel("Not helpful")
        }
        .sensoryFeedback(.selection, trigger: selection)
        .onAppear(perform: recordShown)
    }

    private func select(_ vote: Int) {
        guard selection == nil else { return }
        UserDefaults.standard.set(vote, forKey: voteKey)
        withAnimation(.smooth) { selection = vote }
        Analytics.coachFeedback(runID: runID, helpful: vote == 1)
    }

    private func recordShown() {
        guard !UserDefaults.standard.bool(forKey: shownKey) else { return }
        UserDefaults.standard.set(true, forKey: shownKey)
        Analytics.coachFeedbackShown(runID: runID)
    }

    private static func voteKey(_ runID: UUID) -> String {
        "coachFeedback.\(runID.uuidString.lowercased())"
    }
}
