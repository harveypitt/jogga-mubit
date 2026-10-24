import SwiftUI

/// Post-run check-in answers. Injury details and notes only go to the server,
/// never to analytics.
struct RunSurvey: Codable, Hashable {
    var difficulty: String?
    var coaching: String?
    var injury = false
    var injuryArea: String?
    var injurySeverity: String?
    var notes: String?

    var body: [String: Any] {
        var out: [String: Any] = ["injury": injury]
        if let difficulty { out["difficulty"] = difficulty }
        if let coaching { out["coaching"] = coaching }
        if injury, let injuryArea { out["injury_area"] = injuryArea }
        if injury, let injurySeverity { out["injury_severity"] = injurySeverity }
        if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out["notes"] = String(notes.prefix(500))
        }
        return out
    }

    private static func doneKey(_ runID: UUID) -> String {
        "jogga.surveyDone.\(runID.uuidString.lowercased())"
    }

    static func isDone(_ runID: UUID) -> Bool { UserDefaults.standard.bool(forKey: doneKey(runID)) }
    static func markDone(_ runID: UUID) { UserDefaults.standard.set(true, forKey: doneKey(runID)) }
}

/// Quick tap-through check-in shown over the new run summary while the coach writes.
struct RunSurveyView: View {
    let run: Run
    var coachReady: Bool

    @Environment(RunStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = Step.feel
    @State private var survey = RunSurvey()
    @State private var hurt: Bool?
    @FocusState private var notesFocused: Bool

    enum Step: Int, CaseIterable { case feel, coaching, pain, notes, done }

    private struct Option: Identifiable {
        var id: String
        var emoji: String
        var title: String
        var detail: String?
    }

    private let feelOptions = [
        Option(id: "easy", emoji: "😌", title: "Easy", detail: "Could chat the whole way"),
        Option(id: "moderate", emoji: "🙂", title: "Comfortable", detail: "Working, but in control"),
        Option(id: "hard", emoji: "😤", title: "Hard", detail: "Short sentences only"),
        Option(id: "max", emoji: "🥵", title: "Flat out", detail: "Nothing left"),
    ]
    private let coachingOptions = [
        Option(id: "spot_on", emoji: "🎯", title: "Spot on"),
        Option(id: "too_much", emoji: "🗣️", title: "Too chatty"),
        Option(id: "too_little", emoji: "🤫", title: "Too quiet"),
        Option(id: "off", emoji: "🔇", title: "Didn't use it"),
    ]
    private let areas = [
        Option(id: "foot", emoji: "🦶", title: "Foot or ankle"),
        Option(id: "calf", emoji: "🦵", title: "Calf or shin"),
        Option(id: "knee", emoji: "🦿", title: "Knee"),
        Option(id: "hip", emoji: "🍑", title: "Hip or thigh"),
        Option(id: "back", emoji: "🔙", title: "Back"),
        Option(id: "other", emoji: "📍", title: "Somewhere else"),
    ]
    private let severities = [
        Option(id: "niggle", emoji: "🤏", title: "Niggle", detail: "Noticed it"),
        Option(id: "sore", emoji: "😣", title: "Sore", detail: "It hurt"),
        Option(id: "stopped", emoji: "🛑", title: "Had to stop", detail: "Cut it short"),
    ]

    var body: some View {
        VStack(spacing: 20) {
            if step != .done { header }
            Group {
                switch step {
                case .feel: feelStep
                case .coaching: coachingStep
                case .pain: painStep
                case .notes: notesStep
                case .done: doneStep
                }
            }
            .id(step)
            .transition(reduceMotion ? .opacity : .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .background(Color(.systemGroupedBackground))
        .sensoryFeedback(.selection, trigger: step)
        .sensoryFeedback(.success, trigger: step == .done)
        .interactiveDismissDisabled(step != .done)
        .trackScreen(.runSurvey)
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(i <= step.rawValue ? Color.brand : Color(.tertiarySystemFill))
                        .frame(height: 6)
                }
            }
            .animation(.smooth, value: step)
            .accessibilityElement()
            .accessibilityLabel("Question \(step.rawValue + 1) of 4")
            Button("Skip") { skip() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func title(_ text: String, _ detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(Jogga.rounded(.largeTitle, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tile(_ option: Option, selected: Bool, compact: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: compact ? 4 : 8) {
                Text(option.emoji).font(.system(size: compact ? 28 : 42))
                Text(option.title)
                    .font(Jogga.rounded(compact ? .subheadline : .headline, weight: .semibold))
                    .multilineTextAlignment(.center)
                if let detail = option.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: compact ? 84 : 132)
            .padding(10)
            .background(
                selected ? Color.brand.opacity(0.14) : Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(selected ? Color.brand : .clear, lineWidth: 2)
            )
            .scaleEffect(selected ? 1.03 : 1)
            .animation(.spring(duration: 0.3, bounce: 0.4), value: selected)
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private let grid = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    // MARK: Steps

    private var feelStep: some View {
        VStack(spacing: 22) {
            title("How did that feel?", "\(Fmt.kmShort(run.distanceM / 1000)) km in the bag.")
            LazyVGrid(columns: grid, spacing: 12) {
                ForEach(feelOptions) { option in
                    tile(option, selected: survey.difficulty == option.id) {
                        survey.difficulty = option.id
                        advance()
                    }
                }
            }
        }
    }

    private var coachingStep: some View {
        VStack(spacing: 22) {
            title("How was the live coaching?")
            LazyVGrid(columns: grid, spacing: 12) {
                ForEach(coachingOptions) { option in
                    tile(option, selected: survey.coaching == option.id) {
                        survey.coaching = option.id
                        advance()
                    }
                }
            }
        }
    }

    private var painStep: some View {
        ScrollView {
            VStack(spacing: 22) {
                title("Any pain or niggles?", "Your plan eases off if something hurts.")
                HStack(spacing: 12) {
                    tile(Option(id: "no", emoji: "💪", title: "All good"), selected: hurt == false) {
                        hurt = false
                        survey.injury = false
                        advance()
                    }
                    tile(Option(id: "yes", emoji: "🩹", title: "Something hurts"),
                         selected: hurt == true) {
                        withAnimation(.smooth) { hurt = true }
                        survey.injury = true
                    }
                }
                if hurt == true {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Where?").statLabel()
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()),
                                            GridItem(.flexible())], spacing: 10) {
                            ForEach(areas) { option in
                                tile(option, selected: survey.injuryArea == option.id,
                                     compact: true) { survey.injuryArea = option.id }
                            }
                        }
                        Text("How bad?").statLabel().padding(.top, 6)
                        HStack(spacing: 10) {
                            ForEach(severities) { option in
                                tile(option, selected: survey.injurySeverity == option.id,
                                     compact: true) { survey.injurySeverity = option.id }
                            }
                        }
                        primaryButton("Next") { advance(after: 0) }
                            .disabled(survey.injuryArea == nil || survey.injurySeverity == nil)
                            .padding(.top, 8)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var notesStep: some View {
        VStack(spacing: 22) {
            title("Anything else?", "Sleep, weather, shoes, how your legs felt. Only your coach sees it.")
            TextField("Optional notes", text: Binding(
                get: { survey.notes ?? "" }, set: { survey.notes = $0 }
            ), axis: .vertical)
                .lineLimit(4...8)
                .focused($notesFocused)
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            primaryButton((survey.notes ?? "").isEmpty ? "Finish" : "Save and finish") { finish() }
        }
    }

    private var doneStep: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 40)
            ZStack {
                if !reduceMotion { Burst() }
                Circle()
                    .fill(Color.brand.gradient)
                    .frame(width: 124, height: 124)
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: 54, weight: .heavy))
                            .foregroundStyle(.white)
                            .symbolEffect(.bounce, value: step)
                    }
                    .shadow(color: Color.brand.opacity(0.35), radius: 24, y: 10)
                    .transition(.scale.combined(with: .opacity))
            }
            .frame(height: 220)
            Text("Nice work").font(Jogga.rounded(.largeTitle, weight: .bold))
            Text(doneLine)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            primaryButton(coachReady ? "See your coach's review" : "Your coach is writing…") {
                dismiss()
            }
        }
    }

    private var doneLine: String {
        let calendar = Calendar.current
        let thisWeek = store.runs.filter {
            calendar.isDate($0.startedAt, equalTo: .now, toGranularity: .weekOfYear)
        }.count
        let count = max(thisWeek, 1)
        let ordinal = count.formatted(.number)
        if survey.injury {
            return "Run \(ordinal) this week. Thanks for telling us, your plan will go easy on it."
        }
        return "That's run \(ordinal) this week. Thanks for checking in."
    }

    private func primaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 54)
                .foregroundStyle(.white)
                .background(Color.brand, in: Capsule())
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: Flow

    private func advance(after delay: Double = 0.28) {
        Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            notesFocused = false
            withAnimation(.smooth(duration: 0.35)) {
                step = Step(rawValue: step.rawValue + 1) ?? .done
            }
        }
    }

    private func finish() {
        notesFocused = false
        RunSurvey.markDone(run.id)
        Analytics.capture(.runSurveySubmitted, [
            "difficulty": .string(survey.difficulty ?? "none"),
            "coaching": .string(survey.coaching ?? "none"),
            "injury_reported": .bool(survey.injury),
            "has_notes": .bool(!(survey.notes ?? "").isEmpty),
        ])
        let answers = survey
        let runID = run.id
        Task { await store.submitSurvey(answers, for: runID) }
        withAnimation(.spring(duration: 0.5, bounce: 0.35)) { step = .done }
    }

    private func skip() {
        RunSurvey.markDone(run.id)
        Analytics.capture(.runSurveySkipped, ["at_step": .int(step.rawValue + 1)])
        if survey.difficulty != nil || survey.coaching != nil || survey.injury {
            let answers = survey
            let runID = run.id
            Task { await store.submitSurvey(answers, for: runID) }
        }
        dismiss()
    }
}

/// A little emoji burst behind the finish check.
private struct Burst: View {
    @State private var go = false
    private let emojis = ["🎉", "⭐️", "🔥", "💪", "✨", "🏃", "🎉", "⭐️", "✨", "💥", "🔥", "🏅"]

    var body: some View {
        ZStack {
            ForEach(emojis.indices, id: \.self) { i in
                let angle = Double(i) / Double(emojis.count) * 2 * .pi
                Text(emojis[i])
                    .font(.title)
                    .offset(x: go ? cos(angle) * 140 : 0, y: go ? sin(angle) * 140 : 0)
                    .scaleEffect(go ? 1.1 : 0.2)
                    .opacity(go ? 0 : 1)
            }
        }
        .onAppear { withAnimation(.easeOut(duration: 1.3)) { go = true } }
        .accessibilityHidden(true)
    }
}
