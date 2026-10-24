import SwiftUI

// MARK: Model

/// Weekly report card from the server. Grades are server-computed; the
/// summary is only present once a week has closed.
struct ReportCard: Codable, Hashable, Identifiable {
    var weekStart: String
    var weekEnd: String
    var tz: String
    var status: String
    var kind: String
    var runs: Int
    var km: Double
    var recommended: Int?
    var sessions: [String: Int]
    var rows: [Row]
    var focus: String?
    var summary: Summary?
    var source: String?

    var id: String { weekStart }
    var isLive: Bool { status == "live" }
    var isRest: Bool { kind == "rest" }

    enum CodingKeys: String, CodingKey {
        case weekStart = "week_start"
        case weekEnd = "week_end"
        case tz, status, kind, runs, km, recommended, sessions, rows, focus, summary, source
    }

    struct Row: Codable, Hashable, Identifiable {
        var category: String
        var label: String
        var grade: String?
        var trend: String?
        /// Last week's grade, when ``trend`` is set.
        var was: String?
        var metric: String
        var how: String
        var details: [[String]]

        var id: String { category }
    }

    struct Summary: Codable, Hashable {
        var headline: String
        var summary: String
        var focus: Focus

        struct Focus: Codable, Hashable {
            var category: String
            var action: String
        }
    }

    func row(_ category: String) -> Row? { rows.first { $0.category == category } }

    /// UserDefaults key for the last closed week whose report has been seen.
    static let seenWeekKey = "reportSeenWeek"

    /// Calm scale: accent for good weeks, warm for "work on", never alarm red.
    /// Grey is kept for "—" (not graded).
    static func tint(_ grade: String?) -> Color {
        switch grade {
        case "A": .brand
        case "B": .teal
        case "C": .orange
        case "D": Color(red: 0.78, green: 0.35, blue: 0.27)
        default: .gray
        }
    }

    /// "19–25 Oct", or "28 Sep – 4 Oct" across months.
    var weekRange: String {
        guard let start = Self.day.date(from: weekStart), let end = Self.day.date(from: weekEnd)
        else { return weekStart }
        let sameMonth = weekStart.prefix(7) == weekEnd.prefix(7)
        return sameMonth
            ? "\(Self.dayOnly.string(from: start))–\(Self.dayMonth.string(from: end))"
            : "\(Self.dayMonth.string(from: start)) – \(Self.dayMonth.string(from: end))"
    }

    var shortWeek: String {
        guard let start = Self.day.date(from: weekStart) else { return weekStart }
        return Self.dayMonth.string(from: start)
    }

    var sessionMix: String {
        ["easy", "steady", "hard"]
            .compactMap { key in sessions[key].flatMap { $0 > 0 ? "\($0) \(key)" : nil } }
            .joined(separator: " · ")
    }

    /// Week dates are calendar days, so parse and print them in UTC.
    private static func formatter(_ format: String, template: Bool = false) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        if template {
            f.setLocalizedDateFormatFromTemplate(format)
        } else {
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
        }
        return f
    }

    private static let day = formatter("yyyy-MM-dd")
    private static let dayOnly = formatter("d", template: true)
    private static let dayMonth = formatter("d MMM", template: true)
}

enum ReportCardTab: String, CaseIterable {
    case thisWeek = "This week"
    case lastWeek = "Last week"
    case trend = "12 weeks"
}

// MARK: Tab

/// The Week tab: this week (live), last week (closed report) or the 12-week grid.
struct ReportTabView: View {
    @Environment(RunStore.self) private var store

    private var isEmpty: Bool {
        store.weekPlan == nil && store.reportThisWeek == nil && store.reportLastWeek == nil
            && store.reportHistory.isEmpty
    }

    var body: some View {
        NavigationStack {
            JoggaScreen {
                if isEmpty {
                    Card(spacing: 6) {
                        Text("No report card yet").font(Jogga.rounded(.headline))
                        Text("Go for a run and your weekly grades will show up here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    if let plan = store.weekPlan {
                        WeekPlanCard(plan: plan)
                            .padding(.bottom, 6)
                    }
                    ReportCardSection()
                }
            }
            .navigationTitle("Week")
            .refreshable { await store.refreshReportCards() }
        }
        .trackScreen(.report)
    }
}

// MARK: Week plan

/// This week's runs, top of the Week tab: what's done, what's next, what moved.
struct WeekPlanCard: View {
    var plan: WeekPlan

    var body: some View {
        Card(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("This week's plan").statLabel()
                Spacer()
                Text("\(plan.doneCount) of \(plan.sessions.count) done")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if let change = plan.change {
                Label(change, systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                ForEach(Array(plan.sessions.enumerated()), id: \.element.id) { index, session in
                    if index > 0 { Divider() }
                    PlanSessionRow(session: session)
                }
            }
            if let note = plan.note {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PlanSessionRow: View {
    var session: WeekPlan.Session

    private var missed: Bool { session.status == "missed" }

    var body: some View {
        HStack(spacing: 12) {
            Text(session.weekday)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(session.isToday ? Color.brand : Color.secondary)
                .frame(width: 36, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(session.kind.capitalized) \(Fmt.kmShort(session.km)) km")
                    .font(.body.weight(.medium))
                    .strikethrough(missed)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            status
        }
        .padding(.vertical, 10)
        .opacity(missed ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts = ["\(Fmt.pace(Double(session.pace))) /km"]
        if let from = session.movedFrom, let day = Self.weekday(from) {
            parts.append("moved from \(day)")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var status: some View {
        switch session.status {
        case "done":
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.brand)
                .accessibilityLabel("Done")
        case "missed":
            Text("Missed")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        default:
            if session.isToday {
                Chip(text: "Today", prominent: true)
            } else if session.isNext {
                Chip(text: "Next")
            }
        }
    }

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func weekday(_ iso: String) -> String? {
        guard let date = isoDay.date(from: iso) else { return nil }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }
}

// MARK: Section

struct ReportCardSection: View {
    @Environment(RunStore.self) private var store
    @State private var tab: ReportCardTab = .thisWeek
    @State private var openRow: OpenRow?

    private struct OpenRow: Identifiable {
        var card: ReportCard
        var row: ReportCard.Row
        var id: String { card.weekStart + row.category }
    }

    private var hasLastWeek: Bool { store.reportLastWeek != nil }

    var body: some View {
        if store.reportThisWeek != nil || hasLastWeek || !store.reportHistory.isEmpty {
            VStack(spacing: 10) {
                Picker("Report", selection: $tab) {
                    ForEach(ReportCardTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                Group {
                    switch tab {
                    case .thisWeek: weekCard(store.reportThisWeek, empty: "No runs yet this week")
                    case .lastWeek: weekCard(store.reportLastWeek, empty: "No report for last week")
                    case .trend: ReportTrendCard(weeks: store.reportHistory, onCell: open)
                    }
                }
                .transition(.opacity)
            }
            .onAppear {
                // Early in the week, lead with last week's report.
                if (store.reportThisWeek?.runs ?? 0) == 0, store.reportLastWeek?.summary != nil {
                    tab = .lastWeek
                }
            }
            .onChange(of: tab, initial: true) { _, tab in track(tab) }
            .sensoryFeedback(.selection, trigger: tab)
            .animation(.smooth, value: tab)
            .sheet(item: $openRow) { open in
                ReportRowSheet(card: open.card, row: open.row)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    @ViewBuilder
    private func weekCard(_ card: ReportCard?, empty: String) -> some View {
        if let card {
            ReportWeekCard(card: card) { row in open(card, row) }
        } else {
            Card(spacing: 6) {
                Text(empty).font(Jogga.rounded(.headline))
                Text("Your report card fills in as you run.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func open(_ card: ReportCard, _ row: ReportCard.Row) {
        openRow = OpenRow(card: card, row: row)
        Analytics.capture(.reportCardRowOpened, [
            "week": .string(card.weekStart),
            "status": .string(card.status),
            "category": .string(row.category),
            "grade": .string(row.grade ?? "none"),
        ])
    }

    private func track(_ tab: ReportCardTab) {
        let card: ReportCard? = switch tab {
        case .thisWeek: store.reportThisWeek
        case .lastWeek: store.reportLastWeek
        case .trend: nil
        }
        var props: [String: AnalyticsValue] = ["tab": .string(tab.rawValue)]
        if let card {
            props["week"] = .string(card.weekStart)
            props["status"] = .string(card.status)
            props["kind"] = .string(card.kind)
            for row in card.rows { props["\(row.category)_grade"] = .string(row.grade ?? "none") }
            if tab == .lastWeek, card.summary != nil {
                UserDefaults.standard.set(card.weekStart, forKey: ReportCard.seenWeekKey)
            }
        }
        Analytics.capture(.reportCardViewed, props)
    }
}

// MARK: Week card

struct ReportWeekCard: View {
    var card: ReportCard
    var onRow: (ReportCard.Row) -> Void

    var body: some View {
        Card(spacing: 16) {
            header
            if card.isRest {
                rest
            } else {
                if let summary = card.summary {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(summary.headline)
                            .font(Jogga.rounded(.title3, weight: .bold))
                        Text(summary.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                stats
                VStack(spacing: 0) {
                    ForEach(Array(card.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().padding(.leading, 2) }
                        Button { onRow(row) } label: { ReportRowView(row: row) }
                            .buttonStyle(PressableStyle(scale: 0.98))
                    }
                }
                if let focus = card.summary?.focus { focusView(focus) }
                if card.kind == "imported" {
                    Label("Graded from imported history", systemImage: "square.and.arrow.down")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(card.isLive ? "This week" : "Week of \(card.shortWeek)").statLabel()
            Spacer()
            Text(card.weekRange)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            if card.isLive { Chip(text: "Live") }
        }
    }

    private var stats: some View {
        HStack(alignment: .top, spacing: 0) {
            StatCell(
                label: "Runs",
                value: "\(card.runs)",
                unit: card.recommended.map { "/\($0)" },
                size: 26
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            StatCell(label: "Distance", value: Fmt.kmShort(card.km), unit: "km", size: 26)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text("Mix").statLabel()
                Text(card.sessionMix.isEmpty ? "—" : card.sessionMix)
                    .font(Jogga.rounded(.subheadline))
                    .foregroundStyle(card.sessionMix.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var rest: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "leaf")
                .font(.title2)
                .foregroundStyle(.brand)
                .frame(width: 36, height: 36)
                .background(Color.brand.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text("Rest week").font(Jogga.rounded(.headline))
                Text("No runs, so nothing to grade. Rest is part of training.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func focusView(_ focus: ReportCard.Summary.Focus) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "scope")
                .font(.body.weight(.semibold))
                .foregroundStyle(.brand)
            VStack(alignment: .leading, spacing: 3) {
                Text("Next week · \(card.row(focus.category)?.label ?? focus.category.capitalized)")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(.brand)
                Text(focus.action)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            Color.brand.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }
}

struct ReportRowView: View {
    var row: ReportCard.Row

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label).font(Jogga.rounded(.subheadline))
                Text(row.metric)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            TrendArrow(trend: row.trend, was: row.was)
            GradePill(grade: row.grade)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Shows what went into this")
    }

    private var accessibilityText: String {
        var parts = ["\(row.label), \(row.grade ?? "not graded yet")."]
        if let was = row.was, row.trend == "up" || row.trend == "down" {
            parts.append("\(row.trend == "up" ? "Up" : "Down") from \(was) last week.")
        }
        parts.append(row.metric)
        return parts.joined(separator: " ")
    }
}

struct GradePill: View {
    var grade: String?
    var size: CGFloat = 34

    var body: some View {
        Text(grade ?? "—")
            .font(Jogga.numerals(size * 0.47, weight: .bold))
            .foregroundStyle(grade == nil ? Color.secondary : tint)
            .frame(width: size, height: size * 0.82)
            .background(
                grade == nil ? Color(.tertiarySystemFill) : tint.opacity(0.14),
                in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            )
    }

    private var tint: Color { ReportCard.tint(grade) }
}

/// Grade change since last week, e.g. "↑ from C". Sits by the pill so it
/// reads as the grade moving, not the metric.
struct TrendArrow: View {
    var trend: String?
    var was: String?

    var body: some View {
        if trend == "up" || trend == "down" {
            HStack(spacing: 2) {
                Image(systemName: trend == "up" ? "arrow.up" : "arrow.down")
                    .font(.caption2.weight(.bold))
                if let was { Text("from \(was)").font(.caption2.weight(.semibold)) }
            }
            .foregroundStyle(trend == "up" ? Color.brand : Color.secondary)
            .accessibilityLabel("\(trend == "up" ? "Up" : "Down") from \(was ?? "last week")")
        }
    }
}

// MARK: Row detail

struct ReportRowSheet: View {
    var card: ReportCard
    var row: ReportCard.Row
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        GradePill(grade: row.grade, size: 48)
                        Text(row.metric)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
                if !row.details.isEmpty {
                    Section(card.isLive ? "This week so far" : card.weekRange) {
                        ForEach(Array(row.details.enumerated()), id: \.offset) { _, line in
                            LabeledContent(line.first ?? "", value: line.dropFirst().first ?? "")
                                .monospacedDigit()
                        }
                    }
                }
                Section {
                    Text(row.how)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("How it's worked out")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(row.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: Trend

/// One row per category, one cell per week (oldest left). Rest weeks are blank.
/// Tapping a graded cell opens that week's row detail.
struct ReportTrendCard: View {
    var weeks: [ReportCard]
    var onCell: (ReportCard, ReportCard.Row) -> Void = { _, _ in }

    private var ordered: [ReportCard] { weeks.reversed() }
    private let categories = ["consistency", "pacing", "balance", "load", "progress"]

    var body: some View {
        Card(spacing: 14) {
            HStack {
                Text("Last \(weeks.count) weeks").statLabel()
                Spacer()
                if let first = ordered.first {
                    Text("Since \(first.shortWeek)")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            if weeks.isEmpty {
                Text("Your weekly grades will build up here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
                    ForEach(categories, id: \.self) { category in
                        GridRow {
                            Text(label(category))
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                            HStack(spacing: 4) {
                                ForEach(ordered) { week in
                                    weekCell(week, category)
                                }
                            }
                        }
                    }
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        HStack {
                            if let first = ordered.first { Text(first.shortWeek) }
                            Spacer()
                            if let last = ordered.last {
                                Text(last.isLive ? "This week" : last.shortWeek)
                            }
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .padding(.top, -6)
                    }
                }
                HStack(spacing: 14) {
                    ForEach(["A", "B", "C", "D"], id: \.self) { g in
                        HStack(spacing: 5) {
                            cell(g, rest: false).frame(width: 12)
                            Text(g)
                        }
                    }
                    Spacer()
                    Text("Blank = rest or not graded")
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            }
        }
    }

    private func label(_ category: String) -> String {
        weeks.first?.row(category)?.label ?? category.capitalized
    }

    @ViewBuilder
    private func weekCell(_ week: ReportCard, _ category: String) -> some View {
        if !week.isRest, let row = week.row(category), row.grade != nil {
            Button { onCell(week, row) } label: {
                cell(row.grade, rest: false)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .padding(.vertical, -4)
            .accessibilityLabel("\(row.label), week of \(week.shortWeek), \(row.grade ?? "")")
        } else {
            cell(nil, rest: week.isRest)
        }
    }

    private func cell(_ grade: String?, rest: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(fill(grade))
            .frame(maxWidth: .infinity)
            .frame(height: 14)
            .accessibilityLabel(grade ?? (rest ? "Rest" : "Not graded"))
    }

    private func fill(_ grade: String?) -> Color {
        switch grade {
        case "A": .brand
        case "B": .teal.opacity(0.75)
        case "C": .orange.opacity(0.7)
        case "D": ReportCard.tint("D").opacity(0.85)
        default: Color(.tertiarySystemFill)
        }
    }
}
