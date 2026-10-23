import Charts
import SwiftUI

/// Home activity: week streak, GitHub-style day grid, weekly km with average.
struct ActivityCard: View {
    var runs: [Run]
    private let gridWeeks = 17
    private let chartWeeks = 8

    var body: some View {
        let calendar = Activity.calendar()
        let now = Date.now
        let weeks = Activity.weeks(runs, count: gridWeeks, now: now, calendar: calendar)
        let streak = Activity.streakWeeks(runs, now: now, calendar: calendar)
        let average = Activity.averageWeeklyKm(runs, weeks: chartWeeks, now: now, calendar: calendar)
        let thisWeek = weeks.last

        Card(spacing: 16) {
            HStack {
                Text("Activity").statLabel()
                Spacer()
                StreakBadge(weeks: streak)
            }
            ActivityGrid(weeks: weeks, calendar: calendar)
            HStack(alignment: .top) {
                StatCell(label: "This week", value: String(format: "%.1f", thisWeek?.km ?? 0), unit: "km", size: 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                StatCell(label: "Avg / week", value: String(format: "%.1f", average), unit: "km", size: 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                StatCell(label: "Runs", value: "\(thisWeek?.runs ?? 0)", size: 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            WeeklyChart(weeks: Array(weeks.suffix(chartWeeks)), average: average)
        }
    }
}

struct StreakBadge: View {
    var weeks: Int

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "flame.fill")
                .foregroundStyle(weeks > 0
                    ? AnyShapeStyle(LinearGradient(colors: [PaceColor.color(0), .brand],
                                                   startPoint: .top, endPoint: .bottom))
                    : AnyShapeStyle(Color.secondary))
                .symbolEffect(.bounce, value: weeks)
            Text(weeks == 1 ? "1 week" : "\(weeks) weeks")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.brand.opacity(weeks > 0 ? 0.12 : 0.06), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(weeks) week streak")
    }
}

/// Weeks as columns (oldest left), Monday to Sunday top to bottom.
struct ActivityGrid: View {
    var weeks: [Activity.Week]
    var calendar: Calendar
    private let gap: CGFloat = 4

    var body: some View {
        HStack(alignment: .top, spacing: gap) {
            VStack(alignment: .leading, spacing: gap) {
                ForEach(0..<7, id: \.self) { row in
                    Text(["M", "", "W", "", "F", "", ""][row])
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 10)
            ForEach(weeks, id: \.start) { week in
                VStack(spacing: gap) {
                    ForEach(week.days, id: \.date) { day in
                        cell(day)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(weeks.reduce(0) { $0 + $1.runs }) runs in the last \(weeks.count) weeks")
    }

    private func cell(_ day: Activity.Day) -> some View {
        let isToday = calendar.isDateInToday(day.date)
        return RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .fill(fill(day))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.55), lineWidth: 1.5)
                }
            }
    }

    private func fill(_ day: Activity.Day) -> Color {
        if day.isFuture { return Color(.quaternarySystemFill).opacity(0.4) }
        guard day.runs > 0 else { return Color(.tertiarySystemFill) }
        switch day.km {
        case ..<4: return .brand.opacity(0.35)
        case ..<7: return .brand.opacity(0.6)
        case ..<11: return .brand.opacity(0.82)
        default: return .brand
        }
    }
}

struct WeeklyChart: View {
    var weeks: [Activity.Week]
    var average: Double

    var body: some View {
        Chart {
            ForEach(Array(weeks.enumerated()), id: \.element.start) { index, week in
                BarMark(
                    x: .value("Week", week.start.formatted(.dateTime.day().month(.defaultDigits))),
                    y: .value("km", week.km),
                    width: .ratio(0.55)
                )
                .foregroundStyle(index == weeks.count - 1 ? Color.brand : Color.brand.opacity(0.32))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            if average > 0 {
                RuleMark(y: .value("Average", average))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Color.secondary)
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("avg \(String(format: "%.1f", average)) km")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel()
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel()
                    .font(.caption2)
            }
        }
        .frame(height: 120)
        .accessibilityLabel("Kilometres per week for the last \(weeks.count) weeks")
    }
}
