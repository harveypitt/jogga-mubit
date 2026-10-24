import Charts
import CoreLocation
import MapKit
import SwiftUI

/// About-you questions after sign-in. Days, runs a week and dislikes are hard rules for the
/// weekly planner. Niggles only go to the server, never to analytics.
struct OnboardingView: View {
    var initial: RunnerProfile?
    var previewStep: Step?
    /// Set when onboarding runs before sign-in, from the demo screen.
    var onFinish: (() -> Void)?
    /// Opened from the demo screen, which already says what Jogga is.
    var fromDemo = false

    @Environment(RunStore.self) private var store
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = Step.welcome
    @State private var profile = RunnerProfile()
    @State private var hasRace = true
    @State private var saving = false
    @State private var reveal: CGFloat = 0
    @State private var location = LocationPermission()
    @State private var mapTick = 0
    @State private var built: Double = 0
    @State private var shownCards = 0
    @State private var previewPlan: WeekPlan?

    enum Step: Int, CaseIterable { case welcome, goal, race, experience, reassure, days, runs, dislikes, niggles, blocker, heardFrom, location, building, signIn, done }

    private var editing: Bool { initial?.onboarded == true }
    private var questionCount: Int { Step.allCases.count - 4 }

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
    private let blockers = [
        Option(id: "time", emoji: "⏰", title: "Finding the time", detail: "Shorter runs that fit a busy week"),
        Option(id: "motivation", emoji: "😮‍💨", title: "Staying motivated", detail: "Achievable runs, visible progress"),
        Option(id: "injury", emoji: "🩹", title: "Getting injured", detail: "Gentler build, rest between runs"),
        Option(id: "unsure", emoji: "🤷", title: "Not knowing what to do", detail: "Every run planned and explained"),
    ]
    private let sources = [
        Option(id: "friend", emoji: "👋", title: "A friend"),
        Option(id: "social", emoji: "📸", title: "Social media"),
        Option(id: "app_store", emoji: "📱", title: "App Store"),
        Option(id: "event", emoji: "🎟️", title: "An event"),
        Option(id: "search", emoji: "🔎", title: "Search"),
        Option(id: "other", emoji: "✨", title: "Somewhere else"),
    ]
    private let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        VStack(spacing: 20) {
            if ![.welcome, .building, .signIn, .done].contains(step) { header }
            Group {
                switch step {
                case .welcome: welcomeStep
                case .goal: goalStep
                case .race: raceStep
                case .experience: experienceStep
                case .reassure: reassureStep
                case .days: daysStep
                case .runs: runsStep
                case .dislikes: dislikesStep
                case .niggles: nigglesStep
                case .blocker: blockerStep
                case .heardFrom: heardFromStep
                case .location: locationStep
                case .building: buildingStep
                case .signIn: signInStep
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
            if onFinish != nil || fromDemo { step = .goal }
            if let previewStep {
                profile.goal = "half"
                profile.experience = "regular"
                profile.usualWeekKm = 15
                profile.days = [0, 2, 5]
                profile.runsPerWeek = 3
                profile.blocker = "time"
                #if DEBUG
                let args = ProcessInfo.processInfo.arguments
                if let i = args.firstIndex(of: "-previewPlanFile"), i + 1 < args.count,
                   let data = FileManager.default.contents(atPath: args[i + 1]) {
                    previewPlan = try? JSONDecoder().decode(WeekPlan.self, from: data)
                }
                #endif
                step = previewStep
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
            Button(editing ? "Cancel" : "Skip") {
                if editing { dismiss() } else if auth.signedIn { finish(skipped: true) } else { go(.signIn) }
            }
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
                Text("A few quick questions so your coach plans around your life, not the other way round.")
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
            title("What are you training for?", "We'll build your week around it.")
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
                Label(countdown, systemImage: "flag.checkered")
                    .font(Jogga.rounded(.headline, weight: .semibold))
                    .foregroundStyle(Color.brand)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: countdown)
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
                go(.reassure)
            }
        }
    }

    private var countdown: String {
        let date = profile.raceDate ?? Calendar.current.date(byAdding: .weekOfYear, value: 10, to: .now)!
        let days = max(0, Calendar.current.dateComponents([.day], from: .now, to: date).day ?? 0)
        if days < 14 { return days == 1 ? "1 day to go" : "\(days) days to go" }
        return "\(days / 7) weeks to go"
    }

    private static let soloShape = [1.0, 1.7, 2.1, 0.5, 0, 0, 0.9, 1.7]
    private static let buildRules = [
        ("chart.line.uptrend.xyaxis", "Grows faster when runs feel easy"),
        ("arrow.uturn.backward", "Never makes you catch up missed km"),
        ("timer", "Every run worth at least 20 minutes"),
    ]

    private var reassureStep: some View {
        let start = max(profile.usualWeekKm ?? 0, profile.experience == "new" ? 6 : 8)
        let jogga = (0..<8).map { start * pow(1.12, Double($0)) }
        let solo = Self.soloShape.map { $0 * start }
        return VStack(spacing: 22) {
            title("Steady beats sudden",
                  "Big jumps in weekly distance are linked to running injuries. Your plan builds a little every week instead.")
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    legend("With Jogga", Color.brand)
                    legend("On your own", Color(.systemGray3))
                    Spacer()
                    Text("km a week")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Chart {
                    ForEach(solo.indices, id: \.self) { w in
                        LineMark(x: .value("Week", w + 1), y: .value("km", solo[w]),
                                 series: .value("Who", "Alone"))
                            .foregroundStyle(Color(.systemGray3))
                            .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.monotone)
                    }
                    ForEach(jogga.indices, id: \.self) { w in
                        AreaMark(x: .value("Week", w + 1), y: .value("km", jogga[w]))
                            .foregroundStyle(LinearGradient(colors: [Color.brand.opacity(0.22), Color.brand.opacity(0)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Week", w + 1), y: .value("km", jogga[w]),
                                 series: .value("Who", "Jogga"))
                            .foregroundStyle(Color.brand)
                            .lineStyle(StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.monotone)
                    }
                    PointMark(x: .value("Week", 8), y: .value("km", jogga[7]))
                        .foregroundStyle(Color.brand)
                        .symbolSize(90)
                        .annotation(position: .top, alignment: .trailing, spacing: 6,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            Text("\(Int(jogga[7].rounded())) km")
                                .font(Jogga.rounded(.subheadline, weight: .bold))
                                .foregroundStyle(Color.brand)
                        }
                }
                .chartXScale(domain: 1...8, range: .plotDimension(startPadding: 4, endPadding: 8))
                .chartXAxis {
                    AxisMarks(values: [1, 4, 8]) { value in
                        let w = value.as(Int.self) ?? 0
                        AxisValueLabel(anchor: w == 1 ? .topLeading : w == 8 ? .topTrailing : .top) {
                            Text(w == 1 ? "Now" : "Week \(w)")
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        AxisValueLabel()
                    }
                }
                .chartPlotStyle { plot in
                    plot.mask(alignment: .leading) {
                        GeometryReader { g in Rectangle().frame(width: g.size.width * reveal) }
                    }
                }
                .frame(height: 190)
                .accessibilityElement()
                .accessibilityLabel("Weekly distance over 8 weeks. With Jogga it rises steadily from \(Int(start)) to \(Int(jogga[7].rounded())) kilometres. On your own it spikes, then drops to zero.")
                Label("Based on evidence from sports science", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Self.buildRules.indices, id: \.self) { i in
                    let rule = Self.buildRules[i]
                    HStack(spacing: 12) {
                        Image(systemName: rule.0)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.brand)
                            .frame(width: 34, height: 34)
                            .background(Color.brand.opacity(0.12), in: Circle())
                        Text(rule.1)
                            .font(.subheadline.weight(.medium))
                    }
                    .opacity(reveal > 0.5 ? 1 : 0)
                    .offset(y: reveal > 0.5 ? 0 : 8)
                    .animation(.spring(duration: 0.5).delay(0.9 + Double(i) * 0.15), value: reveal > 0.5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            Spacer()
            primary("Continue") { go(.days) }
        }
        .onAppear {
            reveal = 0
            if reduceMotion { reveal = 1 } else {
                withAnimation(.easeInOut(duration: 1.6).delay(0.3)) { reveal = 1 }
            }
        }
    }

    private func legend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 14, height: 4)
            Text(label).font(.caption.weight(.semibold))
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
            primary(profile.niggles?.isEmpty == false ? "Continue" : "No niggles") { go(.blocker) }
        }
    }

    private var blockerStep: some View {
        VStack(spacing: 22) {
            title("What usually stops you?", "Pick the big one. Your coach plans around it.")
            VStack(spacing: 12) {
                ForEach(blockers) { option in
                    row(option, selected: profile.blocker == option.id, fillHeight: true) {
                        profile.blocker = option.id
                        if !editing { advance(to: .heardFrom) }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if editing {
                primary(saving ? "Saving…" : "Save", disabled: saving) { finish(skipped: false) }
            }
        }
    }

    private var heardFromStep: some View {
        VStack(spacing: 22) {
            title("Where did you hear about Jogga?", "Helps us find more runners like you.")
            LazyVGrid(columns: grid, spacing: 12) {
                ForEach(sources) { option in
                    tile(option, selected: profile.heardFrom == option.id) {
                        profile.heardFrom = option.id
                    }
                }
            }
            Spacer()
            primary("Continue", disabled: profile.heardFrom == nil) { go(.location) }
        }
    }

    private static let locationPoints = [
        ("ruler", "Accurate distance and splits"),
        ("waveform", "Your coach calls out every kilometre"),
        ("lock.fill", "Routes never leave your iPhone"),
    ]

    private var locationStep: some View {
        let demo = DemoRun.sample
        return VStack(spacing: 22) {
            title("Map every run", "Jogga uses GPS to measure your distance and pace as you go.")
            MapReader { proxy in
                Map(initialPosition: .rect(demo.rect), interactionModes: []) {}
                    .mapStyle(.standard(pointsOfInterest: .excludingAll))
                    .overlay { RouteTrace(demo: demo, proxy: proxy, progress: 1).id(mapTick) }
                    .onMapCameraChange(frequency: .continuous) { mapTick += 1 }
                    .task {
                        // The map can settle before reporting a camera change; redraw once it has.
                        try? await Task.sleep(for: .seconds(0.6))
                        mapTick += 1
                    }
            }
            .allowsHitTesting(false)
            .frame(height: 220)
            .overlay(alignment: .topLeading) {
                Label("Stays on this iPhone", systemImage: "lock.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Self.locationPoints.indices, id: \.self) { i in
                    let point = Self.locationPoints[i]
                    HStack(spacing: 12) {
                        Image(systemName: point.0)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.brand)
                            .frame(width: 34, height: 34)
                            .background(Color.brand.opacity(0.12), in: Circle())
                        Text(point.1).font(.subheadline.weight(.medium))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            Spacer()
            VStack(spacing: 14) {
                primary(saving ? "Saving…" : "Allow location", disabled: saving) {
                    location.request { go(.building) }
                }
                Button("Not now") { go(.building) }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .disabled(saving)
            }
        }
    }

    /// `fillHeight` stretches the card to its stack's height; pair with `.fixedSize` on the stack
    /// so every card matches the tallest.
    private func row(
        _ option: Option, selected: Bool, fillHeight: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(option.emoji)
                    .font(.system(size: 28))
                    .frame(width: 52, height: 52)
                    .background(Color(.tertiarySystemFill).opacity(selected ? 0 : 1), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.title)
                        .font(Jogga.rounded(.headline, weight: .semibold))
                    if let detail = option.detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.brand : Color(.tertiaryLabel))
                    .contentTransition(.symbolEffect(.replace))
            }
            .foregroundStyle(.primary)
            .padding(14)
            .frame(maxHeight: fillHeight ? .infinity : nil)
            .background(
                selected ? Color.brand.opacity(0.14) : Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(selected ? Color.brand : .clear, lineWidth: 2)
            )
            .scaleEffect(selected ? 1.02 : 1)
            .animation(.spring(duration: 0.3, bounce: 0.4), value: selected)
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var buildSteps: [String] {
        let goal = goals.first { $0.id == profile.goal }?.title ?? "Your goal"
        let names = profile.days.map { weekdays[$0] }
        let days = names.count > 1
            ? names.dropLast().joined(separator: ", ") + " and " + names.last!
            : names.first ?? "the days you picked"
        let start = Int(max(profile.usualWeekKm ?? 0, profile.experience == "new" ? 6 : 8))
        return [
            profile.goal == "fitness" || !hasRace ? goal : "\(goal), \(countdown)",
            "Runs on \(days)",
            "Building from \(start) km a week",
            blockers.first { $0.id == profile.blocker }?.detail ?? "Rest days between runs",
            "Safety checks on every run",
        ]
    }

    private var buildingStep: some View {
        let items = buildSteps
        let ticked = items.indices.filter { built >= Double($0 + 1) / Double(items.count) }.count
        return VStack(spacing: 28) {
            Spacer(minLength: 24)
            ZStack {
                Circle().stroke(Color(.tertiarySystemFill), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: built)
                    .stroke(Color.brand, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int((built * 100).rounded()))%")
                    .font(Jogga.rounded(.largeTitle, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .frame(width: 176, height: 176)
            .accessibilityElement()
            .accessibilityLabel("Building your plan, \(Int(built * 100)) percent")
            VStack(spacing: 6) {
                Text(built < 1 ? "Building your plan" : "Your plan is ready")
                    .font(Jogga.rounded(.title, weight: .bold))
                    .contentTransition(.opacity)
                Text(built < 1 ? "Your coach is fitting your week around your answers."
                               : "Sign in to save it and see your week.")
                    .contentTransition(.opacity)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 16) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(spacing: 12) {
                        Group {
                            if i < ticked {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.brand)
                            } else if i == ticked {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "circle").foregroundStyle(Color(.tertiaryLabel))
                            }
                        }
                        .font(.title3)
                        .frame(width: 26, height: 26)
                        Text(items[i])
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(i <= ticked ? Color.primary : Color(.tertiaryLabel))
                        Spacer(minLength: 0)
                    }
                    .animation(.smooth, value: ticked)
                }
            }
            .padding(18)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            Spacer()
        }
        .sensoryFeedback(.impact(weight: .light), trigger: ticked)
        .task { await runBuild() }
    }

    private func runBuild() async {
        built = 0
        let start = Date.now
        while built < 1, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(40))
            let t = min(1, Date.now.timeIntervalSince(start) / 5)
            withAnimation(.linear(duration: 0.04)) { built = 1 - pow(1 - t, 1.6) }
        }
        try? await Task.sleep(for: .seconds(0.8))
        guard previewStep == nil, !Task.isCancelled else { return }
        if auth.signedIn { finish(skipped: false) } else { go(.signIn) }
    }

    private var signInStep: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 12)
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.brand)
                    .symbolEffect(.bounce, value: step)
                Text("Your plan is ready")
                    .font(Jogga.rounded(.largeTitle, weight: .bold))
                Text("Sign in to save it. It adapts after every run.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            planTeaser
            Spacer()
            VStack(spacing: 14) {
                AppleSignInButton()
                #if DEBUG
                Button("Continue without Apple") {
                    Analytics.capture(.signInStarted, ["method": .string("dev")])
                    Task { await auth.devSignIn() }
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                #endif
                Text("Free. No ads. Your routes stay on your phone.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .disabled(auth.signingIn || saving)
        .overlay { if auth.signingIn || saving { ProgressView().controlSize(.large) } }
        .onChange(of: auth.signedIn) { _, signedIn in
            if signedIn { finish(skipped: false) }
        }
    }

    /// The week's shape from their answers; session details stay hidden until sign-in.
    private var planTeaser: some View {
        let days = profile.days.isEmpty ? [0, 2, 5] : profile.days
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Your first week").font(Jogga.rounded(.headline, weight: .semibold))
                Spacer()
                Label("Sign in to see", systemImage: "lock.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ForEach(days, id: \.self) { day in
                HStack(spacing: 12) {
                    Text(weekdays[day])
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.brand)
                        .frame(width: 46, height: 46)
                        .background(Color.brand.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Easy run 5.0 km").font(.subheadline.weight(.semibold))
                        Text("6:15 /km, conversational pace").font(.caption)
                    }
                    .redacted(reason: .placeholder)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your first week: \(days.count) runs. Sign in to see them.")
    }

    private var doneStep: some View {
        let plan = previewPlan ?? store.weekPlan
        let sessions = plan?.sessions.filter { $0.status == "planned" } ?? []
        return ZStack {
            Burst()
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(sessions.count == 1 ? "Your first run" : "Your first runs")
                        .font(Jogga.rounded(.largeTitle, weight: .bold))
                    Text(plan?.note ?? "Planned around your answers. It adapts after every run.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 16)
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { i, session in
                            revealCard(session)
                                .opacity(i < shownCards ? 1 : 0)
                                .offset(y: i < shownCards || reduceMotion ? 0 : 24)
                        }
                        weekAheadCard
                            .opacity(shownCards > sessions.count ? 1 : 0)
                            .offset(y: shownCards > sessions.count || reduceMotion ? 0 : 24)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .scrollBounceBehavior(.basedOnSize)
                primary("Let's go") { if let onFinish { onFinish() } else { dismiss() } }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: shownCards)
        .task {
            for i in 1...(sessions.count + 1) {
                try? await Task.sleep(for: .seconds(i == 1 ? 0.35 : 0.25))
                withAnimation(.spring(duration: 0.5, bounce: 0.3)) { shownCards = i }
            }
        }
    }

    private func revealCard(_ session: WeekPlan.Session) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(session.weekday)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(session.isToday ? Color.white : Color.brand)
                .frame(width: 46, height: 46)
                .background(session.isToday ? Color.brand : Color.brand.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(session.kind.capitalized) \(Fmt.kmShort(session.km)) km")
                        .font(Jogga.rounded(.headline, weight: .semibold))
                    Spacer(minLength: 8)
                    Text(session.isToday ? "Today" : "\(Fmt.pace(Double(session.pace))) /km")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(session.isToday ? Color.brand : Color.secondary)
                        .monospacedDigit()
                }
                Text(session.why)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// Next week's shape from their answers; the server plans it on Monday.
    private var weekAheadCard: some View {
        let n = profile.runsPerWeek ?? max(profile.days.count, 3)
        let names = profile.days.map { weekdays[$0] }
        let days = names.count > 1
            ? names.dropLast().joined(separator: ", ") + " and " + names.last!
            : names.first ?? "your days"
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: "calendar")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.brand)
                .frame(width: 46, height: 46)
                .background(Color.brand.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("Then every week")
                    .font(Jogga.rounded(.headline, weight: .semibold))
                Text("\(n) run\(n == 1 ? "" : "s") on \(days), growing as runs feel easy.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
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
        answers.onboardingVersion = RunnerProfile.currentOnboarding
        answers.niggles = answers.niggles?.trimmingCharacters(in: .whitespacesAndNewlines)
        Analytics.capture(skipped ? .onboardingSkipped : .onboardingCompleted, [
            "goal": .string(answers.goal ?? "none"),
            "experience": .string(answers.experience ?? "none"),
            "runs_per_week": .int(answers.runsPerWeek ?? 0),
            "days_count": .int(answers.days.count),
            "dislikes_count": .int(answers.dislikes.count),
            "has_race": .bool(answers.raceDate != nil),
            "blocker": .string(answers.blocker ?? "none"),
            "heard_from": .string(answers.heardFrom ?? "none"),
            "editing": .bool(editing),
            "at_step": .int(step.rawValue),
        ])
        Task {
            await store.saveProfile(answers)
            await store.refreshProfile()
            saving = false
            if skipped { dismiss() } else { go(.done) }
        }
    }
}

/// Asks for when-in-use location from onboarding, after the screen that explains why.
@Observable
final class LocationPermission: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var then: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    func request(then: @escaping () -> Void) {
        guard manager.authorizationStatus == .notDetermined else { return then() }
        self.then = then
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined, let then else { return }
        self.then = nil
        Analytics.capture(.locationPermission, [
            "granted": .bool([.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus)),
            "from": .string("onboarding"),
        ])
        then()
    }
}
