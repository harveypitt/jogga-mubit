import SwiftUI

/// About-you questions after sign-in. Days, runs a week and dislikes are hard rules for the
/// weekly planner. Niggles only go to the server, never to analytics.
struct OnboardingView: View {
    var initial: RunnerProfile?

    @Environment(RunStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = Step.welcome
    @State private var profile = RunnerProfile()
    @State private var hasRace = true
    @State private var saving = false

    enum Step: Int, CaseIterable { case welcome, goal, race, experience, days, runs, dislikes, niggles, done }

    private var editing: Bool { initial?.onboarded == true }
    private var questionCount: Int { Step.allCases.count - 2 }

    private struct Option: Identifiable {
        var id: String
        var emoji: String
        var title: String
        var detail: String?
    }

    private let goals = [
        Option(id: "5k", emoji: "🏃", title: "5K"),
        Option(id: "10k", emoji: "🔟", title: "10K"),
        Option(id: "half", emoji: "🌗", title: "Half marathon"),
        Option(id: "marathon", emoji: "🏅", title: "Marathon"),
        Option(id: "fitness", emoji: "💚", title: "Just get fitter"),
    ]
    private let levels = [
        Option(id: "new", emoji: "🌱", title: "New to running", detail: "Under a few months"),
        Option(id: "returning", emoji: "🔁", title: "Coming back", detail: "Used to run, had a break"),
        Option(id: "regular", emoji: "💪", title: "Run regularly", detail: "Most weeks this year"),
    ]
    private let dislikeOptions = [
        Option(id: "track", emoji: "🏟️", title: "Track"),
        Option(id: "intervals", emoji: "⏱️", title: "Intervals"),
        Option(id: "tempo", emoji: "🔥", title: "Tempo runs"),
        Option(id: "hills", emoji: "⛰️", title: "Hills"),
        Option(id: "long_runs", emoji: "🛣️", title: "Long runs"),
    ]
    private let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        VStack(spacing: 20) {
            if step != .welcome && step != .done { header }
            Group {
                switch step {
                case .welcome: welcomeStep
                case .goal: goalStep
                case .race: raceStep
                case .experience: experienceStep
                case .days: daysStep
                case .runs: runsStep
                case .dislikes: dislikesStep
                case .niggles: nigglesStep
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
        .interactiveDismissDisabled(!editing)
        .trackScreen(.onboarding)
        .onAppear {
            if let initial {
                profile = initial
                hasRace = initial.raceDate != nil || initial.goal == nil
                if editing { step = .goal }
            }
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 14) {
            Button {
                back()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .frame(width: 32, height: 32)
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel("Back")
            HStack(spacing: 6) {
                ForEach(0..<questionCount, id: \.self) { i in
                    Capsule()
                        .fill(i < step.rawValue ? Color.brand : Color(.tertiarySystemFill))
                        .frame(height: 6)
                }
            }
            .animation(.smooth, value: step)
            .accessibilityElement()
            .accessibilityLabel("Question \(step.rawValue) of \(questionCount)")
            Button(editing ? "Cancel" : "Skip") { editing ? dismiss() : finish(skipped: true) }
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
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tile(_ option: Option, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(option.emoji).font(.system(size: 34)).accessibilityHidden(true)
                Text(option.title)
                    .font(Jogga.rounded(.headline, weight: .semibold))
                    .multilineTextAlignment(.center)
                if let detail = option.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 104)
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

    private func primary(_ label: String, disabled: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Jogga.rounded(.headline, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(disabled ? Color(.tertiarySystemFill) : Color.brand,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .foregroundStyle(disabled ? Color.secondary : Color.white)
        }
        .buttonStyle(PressableStyle(scale: 0.97))
        .disabled(disabled)
    }

    private let grid = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    // MARK: Steps

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 40)
            Text("👟").font(.system(size: 76))
            VStack(spacing: 10) {
                Text("Let's build your week")
                    .font(Jogga.rounded(.largeTitle, weight: .bold))
                    .multilineTextAlignment(.center)
                Text("Seven quick questions so your coach plans around your life, not the other way round.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Label("Your routes stay on your phone. Your answers only shape your plan.",
                  systemImage: "lock.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            primary("Get started") {
                profile.consent = true
                go(.goal)
            }
        }
    }

    private var goalStep: some View {
        VStack(spacing: 22) {
            title("What are you training for?")
            LazyVGrid(columns: grid, spacing: 12) {
                ForEach(goals) { option in
                    tile(option, selected: profile.goal == option.id) {
                        profile.goal = option.id
                        if option.id == "fitness" {
                            profile.raceDate = nil
                            advance(to: .experience)
                        } else {
                            advance(to: .race)
                        }
                    }
                }
            }
        }
    }

    private var raceStep: some View {
        VStack(spacing: 22) {
            title("Got a race booked?", "Your plan builds toward it and eases off the week before.")
            Picker("Race", selection: $hasRace) {
                Text("Yes, on a date").tag(true)
                Text("Not yet").tag(false)
            }
            .pickerStyle(.segmented)
            if hasRace {
                DatePicker("Race day",
                           selection: Binding(
                               get: { profile.raceDate ?? Calendar.current.date(byAdding: .weekOfYear, value: 10, to: .now)! },
                               set: { profile.raceDate = $0 }),
                           in: Date.now...,
                           displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .tint(.brand)
                    .padding(8)
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            Spacer()
            primary("Continue") {
                if !hasRace { profile.raceDate = nil }
                else if profile.raceDate == nil {
                    profile.raceDate = Calendar.current.date(byAdding: .weekOfYear, value: 10, to: .now)
                }
                go(.experience)
            }
        }
    }

    private var experienceStep: some View {
        VStack(spacing: 22) {
            title("How long have you been running?")
            VStack(spacing: 12) {
                ForEach(levels) { option in
                    tile(option, selected: profile.experience == option.id) {
                        profile.experience = option.id
                        if option.id == "new" { profile.usualWeekKm = profile.usualWeekKm ?? 0 }
                    }
                }
            }
            if let level = profile.experience, level != "new" {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("A usual week")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(Int(profile.usualWeekKm ?? 10))")
                            .font(Jogga.rounded(.title2, weight: .bold))
                            .monospacedDigit()
                        + Text(" km").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(get: { profile.usualWeekKm ?? 10 },
                                          set: { profile.usualWeekKm = $0.rounded() }),
                           in: 0...80, step: 1)
                        .tint(.brand)
                        .accessibilityLabel("Usual week in kilometres")
                        .accessibilityValue("\(Int(profile.usualWeekKm ?? 10)) km")
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            Spacer()
            primary("Continue", disabled: profile.experience == nil) {
                if profile.experience != "new", profile.usualWeekKm == nil { profile.usualWeekKm = 10 }
                go(.days)
            }
        }
    }

    private var daysStep: some View {
        VStack(spacing: 22) {
            title("Which days can you run?", "Pick every day that could work. We'll only plan on these.")
            HStack(spacing: 8) {
                ForEach(0..<7, id: \.self) { day in
                    let on = profile.days.contains(day)
                    Button {
                        if on { profile.days.removeAll { $0 == day } } else { profile.days.append(day) }
                        profile.days.sort()
                    } label: {
                        Text(weekdays[day])
                            .font(Jogga.rounded(.subheadline, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(on ? Color.brand : Color(.secondarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .foregroundStyle(on ? Color.white : Color.primary)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel(Calendar.current.weekdaySymbols[(day + 1) % 7])
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .sensoryFeedback(.selection, trigger: profile.days)
            Spacer()
            primary("Continue", disabled: profile.days.isEmpty) {
                let most = min(profile.days.count, 5)
                if profile.runsPerWeek == nil || profile.runsPerWeek! > most {
                    profile.runsPerWeek = min(3, most)
                }
                go(.runs)
            }
        }
    }

    private static let runEmoji = ["🌱", "🙂", "💪", "🔥", "🚀"]
    private static let runDetail = ["Keep it simple", "A steady habit", "Room to build", "Serious training", "Race ready"]

    private var runsStep: some View {
        let most = max(1, min(profile.days.count, 5))
        return VStack(spacing: 22) {
            title("How many runs a week?", "The most you're happy with. Your plan never asks for more.")
            LazyVGrid(columns: grid, spacing: 12) {
                ForEach(1...most, id: \.self) { n in
                    tile(Option(id: "\(n)", emoji: Self.runEmoji[n - 1],
                                title: n == 1 ? "1 run" : "\(n) runs",
                                detail: Self.runDetail[n - 1]),
                         selected: profile.runsPerWeek == n) {
                        profile.runsPerWeek = n
                        advance(to: .dislikes)
                    }
                }
            }
        }
    }

    private var dislikesStep: some View {
        VStack(spacing: 22) {
            title("Anything you'd rather skip?", "Pick any. Your coach won't plan them.")
            LazyVGrid(columns: grid, spacing: 12) {
                ForEach(dislikeOptions) { option in
                    tile(option, selected: profile.dislikes.contains(option.id)) {
                        if profile.dislikes.contains(option.id) {
                            profile.dislikes.removeAll { $0 == option.id }
                        } else {
                            profile.dislikes.append(option.id)
                        }
                    }
                }
            }
            Spacer()
            primary(profile.dislikes.isEmpty ? "I'm up for anything" : "Continue") { go(.niggles) }
        }
    }

    private var nigglesStep: some View {
        VStack(spacing: 22) {
            title("Any old injuries or niggles?", "Optional. Only your coach sees this.")
            TextField("e.g. Left knee gets sore after 8 km",
                      text: Binding(get: { profile.niggles ?? "" }, set: { profile.niggles = $0 }),
                      axis: .vertical)
                .lineLimit(3...6)
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .onChange(of: profile.niggles ?? "") { _, new in
                    if new.count > 300 { profile.niggles = String(new.prefix(300)) }
                }
            Spacer()
            primary(saving ? "Saving…" : (editing ? "Save" : "Build my plan"), disabled: saving) {
                finish(skipped: false)
            }
        }
    }

    private var doneStep: some View {
        ZStack {
            Burst()
            VStack(spacing: 18) {
                Spacer()
                Text("🗓️").font(.system(size: 76))
                Text("You're all set")
                    .font(Jogga.rounded(.largeTitle, weight: .bold))
                Text(summary)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
                primary("Let's go") { dismiss() }
            }
        }
    }

    private var summary: String {
        let n = profile.runsPerWeek ?? 3
        let days = profile.days.map { weekdays[$0] }.joined(separator: ", ")
        return "Up to \(n) run\(n == 1 ? "" : "s") a week on \(days). Your plan is on the Week tab and adapts after every run."
    }

    // MARK: Flow

    private func go(_ next: Step) {
        withAnimation(.smooth(duration: 0.35)) { step = next }
    }

    private func advance(to next: Step) {
        Task {
            try? await Task.sleep(for: .seconds(0.28))
            go(next)
        }
    }

    private func back() {
        var prev = Step(rawValue: step.rawValue - 1) ?? .goal
        if prev == .race && profile.goal == "fitness" { prev = .goal }
        if prev == .welcome { if editing { dismiss() }; return }
        go(prev)
    }

    private func finish(skipped: Bool) {
        saving = true
        var answers = profile
        answers.consent = true
        answers.niggles = answers.niggles?.trimmingCharacters(in: .whitespacesAndNewlines)
        Analytics.capture(skipped ? .onboardingSkipped : .onboardingCompleted, [
            "goal": .string(answers.goal ?? "none"),
            "experience": .string(answers.experience ?? "none"),
            "runs_per_week": .int(answers.runsPerWeek ?? 0),
            "days_count": .int(answers.days.count),
            "dislikes_count": .int(answers.dislikes.count),
            "has_race": .bool(answers.raceDate != nil),
            "editing": .bool(editing),
            "at_step": .int(step.rawValue),
        ])
        Task {
            await store.saveProfile(answers)
            saving = false
            if skipped { dismiss() } else { go(.done) }
        }
    }
}
