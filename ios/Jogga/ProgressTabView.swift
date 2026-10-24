import Charts
import SwiftUI

enum ProgressRange: String, CaseIterable {
    case week = "7D"
    case month = "30D"
    case year = "1Y"
    case all = "All"

    func start(now: Date, earliest: Date) -> Date {
        switch self {
        case .week: now.addingTimeInterval(-7 * 86_400)
        case .month: now.addingTimeInterval(-30 * 86_400)
        case .year: now.addingTimeInterval(-365 * 86_400)
        case .all: earliest
        }
    }

    func emptyMessage(for distance: String) -> String {
        switch self {
        case .week: "No \(distance) in the past 7 days"
        case .month: "No \(distance) in the past 30 days"
        case .year: "No \(distance) in the past year"
        case .all: "No \(distance) yet"
        }
    }
}

enum ProgressChartMath {
    static func timeAxis(values: [Double]) -> (domain: ClosedRange<Double>, ticks: [Double]) {
        let finiteValues = values.filter(\.isFinite)
        guard let lo = finiteValues.min(), let hi = finiteValues.max() else {
            return (-10...10, [-10, -5, 0, 5, 10])
        }

        let pad = max(10, 0.06 * (hi - lo))
        let lower = lo - pad
        let upper = hi + pad
        var steps: [Double] = [
            5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600,
            7200, 14_400, 28_800, 86_400,
        ]
        while (steps.last ?? 0) < upper - lower {
            steps.append((steps.last ?? 1) * 2)
        }

        for step in steps {
            let first = ceil(lower / step) * step
            let last = floor(upper / step) * step
            guard first <= last else { continue }
            let ticks = Array(stride(from: first, through: last, by: step))
            if (2...5).contains(ticks.count) {
                return (lower...upper, ticks)
            }
        }

        let step = steps.last ?? upper - lower
        let first = ceil(lower / step) * step
        let last = floor(upper / step) * step
        return (lower...upper, first < last ? [first, last] : [lower, upper])
    }

    static func bestSoFar(
        _ points: [(date: Date, seconds: Double)]
    ) -> [(date: Date, seconds: Double)] {
        var best = Double.infinity
        return points.filter { $0.seconds.isFinite }
            .sorted { $0.date < $1.date }
            .compactMap { point in
                guard point.seconds < best else { return nil }
                best = point.seconds
                return point
            }
    }

    static func trend(
        _ points: [(date: Date, seconds: Double)]
    ) -> (slopePerDay: Double, intercept: Double)? {
        guard points.count >= 3,
              let first = points.first,
              points.contains(where: { $0.date != first.date }),
              points.allSatisfy({ $0.seconds.isFinite })
        else { return nil }

        let xs = points.map { $0.date.timeIntervalSince(first.date) / 86_400 }
        let ys = points.map(\.seconds)
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = ys.reduce(0, +) / Double(ys.count)
        let numerator = zip(xs, ys).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let denominator = xs.reduce(0) { $0 + pow($1 - meanX, 2) }
        guard denominator > 0 else { return nil }

        let slope = numerator / denominator
        let intercept = meanY - slope * meanX
        guard slope.isFinite, intercept.isFinite else { return nil }
        return (slope, intercept)
    }
}

/// Progress tab: weekly report card, distance picker, hero best, target gap, effort chart,
/// stats row, Riegel prediction, frequency advice, edit target.
struct ProgressTabView: View {
    @Environment(RunStore.self) private var store
    @AppStorage("jogga.progressRange") private var range: ProgressRange = .all
    @State private var distance = "5k"
    @State private var showTarget = false

    private struct Effort: Identifiable {
        var id: UUID
        var date: Date
        var seconds: Double
    }

    private var efforts: [Effort] {
        store.runs
            .compactMap { run in run.efforts[distance].map { Effort(id: run.id, date: run.startedAt, seconds: $0) } }
            .sorted { $0.date < $1.date }
    }

    private var best: Double? { store.stats[distance]?.bestS ?? efforts.map(\.seconds).min() }
    private var last: Double? { store.stats[distance]?.lastS ?? efforts.last?.seconds }
    private var count: Int { store.stats[distance]?.count ?? efforts.count }
    private var count4w: Int {
        store.stats[distance]?.count4w
            ?? efforts.filter { $0.date > .now.addingTimeInterval(-28 * 86400) }.count
    }
    private var target: Int? { store.targets[distance] }
    private var chartNow: Date { .now }
    private var rangeStart: Date {
        range.start(now: chartNow, earliest: efforts.first?.date ?? chartNow)
    }
    private var visibleEfforts: [Effort] {
        efforts.filter { $0.date >= rangeStart && $0.date <= chartNow }
    }
    private var visibleBest: Double? { visibleEfforts.map(\.seconds).min() }
    private var xDomain: ClosedRange<Date> {
        let span = max(chartNow.timeIntervalSince(rangeStart), 1)
        let end = chartNow.addingTimeInterval(span * 0.04)
        switch range {
        case .week, .month:
            return rangeStart...end
        case .year, .all:
            let first = visibleEfforts.first?.date ?? rangeStart
            return first.addingTimeInterval(-span * 0.04)...end
        }
    }
    private var bestSoFar: [(date: Date, seconds: Double)] {
        ProgressChartMath.bestSoFar(
            efforts.map { (date: $0.date, seconds: $0.seconds) }
        )
    }
    private var chartBestLine: [(date: Date, seconds: Double)] {
        let previous = bestSoFar.last { $0.date < rangeStart }
        var points = bestSoFar.filter {
            $0.date >= rangeStart && $0.date <= chartNow
        }
        if let previous {
            points.insert(
                (date: xDomain.lowerBound, seconds: previous.seconds), at: 0
            )
        }
        guard let last = points.last else { return points }
        points.append((date: xDomain.upperBound, seconds: last.seconds))
        return points
    }
    private var trendProjection: (firstDate: Date, startSeconds: Double, endSeconds: Double)? {
        guard let trend = ProgressChartMath.trend(
            visibleEfforts.map { (date: $0.date, seconds: $0.seconds) }
        ),
              let first = visibleEfforts.first
        else { return nil }
        let daysToNow = chartNow.timeIntervalSince(first.date) / 86_400
        return (
            first.date,
            trend.intercept,
            trend.intercept + trend.slopePerDay * daysToNow
        )
    }
    private var chartTimeAxis: (domain: ClosedRange<Double>, ticks: [Double]) {
        var values = visibleEfforts.map(\.seconds)
        values += chartBestLine.map(\.seconds)
        if let target { values.append(Double(target)) }
        if let trendProjection {
            values.append(trendProjection.startSeconds)
            values.append(trendProjection.endSeconds)
        }
        return ProgressChartMath.timeAxis(values: values)
    }
    private var xAxisFormat: Date.FormatStyle {
        switch range {
        case .week:
            .dateTime.weekday(.abbreviated)
        case .month:
            .dateTime.day().month(.abbreviated)
        case .year:
            .dateTime.month(.abbreviated)
        case .all:
            if chartNow.timeIntervalSince(rangeStart) < 2 * 365 * 86_400 {
                .dateTime.month(.abbreviated).year(.twoDigits)
            } else {
                .dateTime.year()
            }
        }
    }
    private var chartCaption: String {
        guard trendProjection != nil,
              let trend = ProgressChartMath.trend(
                visibleEfforts.map { (date: $0.date, seconds: $0.seconds) }
              )
        else { return "Faster is higher." }

        let monthlyChange = trend.slopePerDay * 30
        if abs(monthlyChange) < 3 { return "Holding steady · faster is higher" }
        let change = RunMath.formatTime(abs(monthlyChange))
        return monthlyChange < 0
            ? "Trending \(change) faster a month"
            : "Trending \(change) slower a month"
    }

    var body: some View {
        NavigationStack {
            JoggaScreen {
                ReportCardSection()
                    .padding(.bottom, 6)

                Picker("Distance", selection: $distance) {
                    ForEach(RunMath.standardDistances, id: \.key) { d in
                        Text(Fmt.distanceName(d.key)).tag(d.key)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.bottom, 4)

                heroCard
                if efforts.count > 1 { chartCard }
                statsCard
                if let prediction = RunMath.riegel(target: distance, efforts: bestEfforts),
                   efforts.isEmpty || prediction.from != distance {
                    predictionCard(from: prediction.from, seconds: prediction.seconds)
                }
                if let note = store.latestCoach { frequencyCard(note) }
            }
            .navigationTitle("Progress")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(target == nil ? "Set target" : "Edit target") { showTarget = true }
                }
            }
            .sheet(isPresented: $showTarget) {
                TargetSheet(distance: distance)
            }
            .sensoryFeedback(.selection, trigger: distance)
            .sensoryFeedback(.selection, trigger: range)
            .animation(.smooth, value: distance)
            .animation(.smooth, value: range)
        }
        .trackScreen(.progress)
    }

    // MARK: Hero

    private var heroCard: some View {
        Card(spacing: 8) {
            Text("Best \(Fmt.distanceName(distance))").statLabel()
            if let best {
                Metric(value: RunMath.formatTime(best), size: 68, weight: .bold)
            } else {
                Text("No \(Fmt.distanceName(distance)) yet")
                    .font(Jogga.rounded(.title, weight: .bold))
                Text("Run \(distanceKm) km and it will show up here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let target {
                HStack(spacing: 8) {
                    Image(systemName: "scope")
                    Text("Target \(RunMath.formatTime(Double(target)))")
                        .monospacedDigit()
                    Spacer()
                    if let best {
                        let gap = best - Double(target)
                        Chip(text: gap > 0 ? "\(RunMath.formatTime(gap)) to go" : "Beaten",
                             prominent: gap <= 0)
                    }
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                Text("That's \(RunMath.formatPace(RunMath.requiredPace(distanceKey: distance, targetS: Double(target)))) the whole way.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var distanceKm: String {
        let metres = RunMath.standardDistances.first { $0.key == distance }?.metres ?? 5000
        return Fmt.kmShort((metres / 1000 * 10).rounded() / 10)
    }

    // MARK: Chart

    private var chartCard: some View {
        Card(spacing: 14) {
            HStack {
                Text("Every \(Fmt.distanceName(distance))").statLabel()
                Spacer()
                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        Capsule().fill(Color.brand).frame(width: 14, height: 2.5)
                        Text("Best")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    if target != nil {
                        HStack(spacing: 4) {
                            Capsule()
                                .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                                .frame(width: 14, height: 2)
                                .foregroundStyle(Color.brand.opacity(0.7))
                            Text("Target")
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    }
                    if trendProjection != nil {
                        HStack(spacing: 4) {
                            Capsule()
                                .stroke(style: StrokeStyle(lineWidth: 2, dash: [2, 3]))
                                .frame(width: 14, height: 3)
                                .foregroundStyle(Color.brand.opacity(0.45))
                            Text("Trend")
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    }
                }
            }
            Picker("Range", selection: $range) {
                ForEach(ProgressRange.allCases, id: \.self) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if visibleEfforts.isEmpty {
                Text(range.emptyMessage(for: Fmt.distanceName(distance)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                Chart {
                    ForEach(Array(chartBestLine.enumerated()), id: \.offset) { _, point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Time", point.seconds),
                            series: .value("Series", "Best")
                        )
                        .interpolationMethod(.stepEnd)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .foregroundStyle(Color.brand)
                    }
                    ForEach(visibleEfforts) { e in
                        PointMark(x: .value("Date", e.date), y: .value("Time", e.seconds))
                            .symbolSize(e.seconds == visibleBest ? 48 : 18)
                            .foregroundStyle(e.seconds == visibleBest
                                ? Color.brand : Color.brand.opacity(0.35))
                    }
                    if let trendProjection {
                        LineMark(
                            x: .value("Date", trendProjection.firstDate),
                            y: .value("Time", trendProjection.startSeconds),
                            series: .value("Series", "Trend")
                        )
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 5]))
                        .foregroundStyle(Color.brand.opacity(0.45))
                        LineMark(
                            x: .value("Date", chartNow),
                            y: .value("Time", trendProjection.endSeconds),
                            series: .value("Series", "Trend")
                        )
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 5]))
                        .foregroundStyle(Color.brand.opacity(0.45))
                    }
                    if let target {
                        RuleMark(y: .value("Target", Double(target)))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                            .foregroundStyle(Color.brand.opacity(0.7))
                    }
                }
                .chartXScale(domain: xDomain)
                .chartYScale(domain: [chartTimeAxis.domain.upperBound, chartTimeAxis.domain.lowerBound])
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisValueLabel(format: xAxisFormat)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: chartTimeAxis.ticks) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        AxisValueLabel {
                            if let seconds = value.as(Double.self) {
                                Text(RunMath.formatTime(seconds))
                            }
                        }
                    }
                }
                .frame(height: 200)
            }
            Text(chartCaption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Stats

    private var statsCard: some View {
        Card {
            HStack(alignment: .top) {
                StatCell(label: "Runs", value: "\(count)")
                    .frame(maxWidth: .infinity, alignment: .leading)
                StatCell(label: "Last 4 wks", value: "\(count4w)")
                    .frame(maxWidth: .infinity, alignment: .leading)
                StatCell(label: "Last time", value: last.map(RunMath.formatTime) ?? "–")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func predictionCard(from: String, seconds: Double) -> some View {
        Card(spacing: 6) {
            Text("Predicted").statLabel()
            HStack(alignment: .firstTextBaseline) {
                Metric(value: RunMath.formatTime(seconds), size: 30)
                Spacer()
                Text("from your \(Fmt.distanceName(from))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func frequencyCard(_ note: CoachNote) -> some View {
        Card(spacing: 8) {
            Text("How often").statLabel()
            Metric(value: "\(note.payload.frequency.runsPerWeek)", unit: "runs a week", size: 30)
            Text(note.payload.frequency.note)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Best effort per distance across all runs.
    private var bestEfforts: [String: Double] {
        var out: [String: Double] = [:]
        for run in store.runs {
            for (key, seconds) in run.efforts {
                out[key] = min(out[key] ?? .infinity, seconds)
            }
        }
        return out
    }
}
