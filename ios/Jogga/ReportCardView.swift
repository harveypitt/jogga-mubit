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

// MARK: Section

/// Top of Progress: this week (live), last week (closed report) or the
/// 12-week grade history.
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
                    case .trend: ReportTrendCard(weeks: store.reportHistory)
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
            ReportWeekCard(card: card) { row in
                openRow = OpenRow(card: card, row: row)
                Analytics.capture(.reportCardRowOpened, [
                    "week": .string(card.weekStart),
                    "status": .string(card.status),
                    "category": .string(row.category),
                    "grade": .string(row.grade ?? "none"),
                ])
            }
        } else {
            Card(spacing: 6) {
                Text(empty).font(Jogga.rounded(.headline))
                Text("Your report card fills in as you run.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
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
            TrendArrow(trend: row.trend)
            GradePill(grade: row.grade)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.label), \(row.grade ?? "not graded yet"). \(row.metric)")
        .accessibilityHint("Shows what went into this")
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

    /// Calm scale: accent for good weeks, warm for "work on", never alarm red.
    private var tint: Color {
        switch grade {
        case "A": .brand
        case "B": .teal
        case "C": .orange
        default: .gray
        }
    }
}

struct TrendArrow: View {
    var trend: String?

    var body: some View {
        switch trend {
        case "up":
            Image(systemName: "arrow.up.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.brand)
                .accessibilityLabel("Up from last week")
        case "down":
            Image(systemName: "arrow.down.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Down from last week")
        default:
            EmptyView()
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
struct ReportTrendCard: View {
    var weeks: [ReportCard]

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
                                    cell(week.isRest ? nil : week.row(category)?.grade, rest: week.isRest)
                                }
                            }
                        }
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
                    Text("Blank = rest or not enough data")
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            }
        }
    }

    private func label(_ category: String) -> String {
        weeks.first?.row(category)?.label ?? category.capitalized
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
        case "D": .gray.opacity(0.55)
        default: Color(.tertiarySystemFill)
        }
    }
}
