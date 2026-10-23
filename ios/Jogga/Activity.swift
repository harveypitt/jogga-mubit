import Foundation

/// Calendar maths for the home activity card. Weeks start on Monday.
enum Activity {
    struct Day: Hashable {
        var date: Date
        var km: Double
        var runs: Int
        var isFuture: Bool
    }

    struct Week: Hashable {
        var start: Date // Monday
        var days: [Day] // 7, Mon…Sun
        var km: Double
        var runs: Int
    }

    /// Gregorian, firstWeekday = 2, minimumDaysInFirstWeek = 4.
    static func calendar(timeZone: TimeZone = .current) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.firstWeekday = 2
        cal.minimumDaysInFirstWeek = 4
        return cal
    }

    /// Monday 00:00 of the week containing `date`.
    private static func weekStart(of date: Date, calendar: Calendar) -> Date {
        var start = Date()
        var interval: TimeInterval = 0
        calendar.dateInterval(of: .weekOfYear, start: &start, interval: &interval, for: date)
        return start
    }

    /// Last `count` weeks, oldest first; the last one is the week containing `now`.
    /// Runs after `now` are ignored.
    static func weeks(_ runs: [Run], count: Int, now: Date, calendar: Calendar) -> [Week] {
        let thisWeek = weekStart(of: now, calendar: calendar)
        let todayStart = calendar.startOfDay(for: now)
        let past = runs.filter { $0.startedAt <= now }
        return (0..<count).reversed().map { offset -> Week in
            let start = calendar.date(byAdding: .weekOfYear, value: -offset, to: thisWeek)!
            let days = (0..<7).map { d -> Day in
                let dayStart = calendar.date(byAdding: .day, value: d, to: start)!
                let dayRuns = past.filter { calendar.isDate($0.startedAt, inSameDayAs: dayStart) }
                return Day(
                    date: dayStart,
                    km: dayRuns.reduce(0) { $0 + $1.distanceM } / 1000,
                    runs: dayRuns.count,
                    isFuture: dayStart > todayStart
                )
            }
            return Week(
                start: start,
                days: days,
                km: days.reduce(0) { $0 + $1.km },
                runs: days.reduce(0) { $0 + $1.runs }
            )
        }
    }

    /// Consecutive weeks with ≥1 run, ending with the current week if it has a run,
    /// otherwise ending with last week (an in-progress week doesn't break a streak). 0 if neither.
    static func streakWeeks(_ runs: [Run], now: Date, calendar: Calendar) -> Int {
        let past = runs.filter { $0.startedAt <= now }
        var weeksWithRuns = Set<Date>()
        for run in past {
            weeksWithRuns.insert(weekStart(of: run.startedAt, calendar: calendar))
        }
        var week = weekStart(of: now, calendar: calendar)
        var streak = 0
        var checkedCurrent = false
        while true {
            if weeksWithRuns.contains(week) {
                streak += 1
            } else if checkedCurrent {
                break
            }
            // An in-progress empty current week doesn't break the streak.
            checkedCurrent = true
            week = calendar.date(byAdding: .weekOfYear, value: -1, to: week)!
        }
        return streak
    }

    /// Mean km/week over the last `weeks` weeks including the current one, with the
    /// divisor capped at the number of weeks since the first run's week (inclusive),
    /// so new users aren't diluted. 0 with no runs.
    static func averageWeeklyKm(
        _ runs: [Run], weeks: Int, now: Date, calendar: Calendar
    ) -> Double {
        let past = runs.filter { $0.startedAt <= now }
        guard let first = past.min(by: { $0.startedAt < $1.startedAt }) else { return 0 }
        let thisWeek = weekStart(of: now, calendar: calendar)
        let windowStart = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek)!
        let firstWeek = weekStart(of: first.startedAt, calendar: calendar)
        let window = past.filter { $0.startedAt >= windowStart }
        let totalKm = window.reduce(0) { $0 + $1.distanceM } / 1000
        let weeksSinceFirst = max(
            calendar.dateComponents([.weekOfYear], from: firstWeek, to: thisWeek).weekOfYear ?? 0,
            0
        ) + 1
        let divisor = min(weeks, weeksSinceFirst)
        return divisor > 0 ? totalKm / Double(divisor) : 0
    }

    /// Runs whose startedAt falls on the same calendar day as `now`.
    static func runsToday(_ runs: [Run], now: Date, calendar: Calendar) -> [Run] {
        runs.filter { $0.startedAt <= now && calendar.isDate($0.startedAt, inSameDayAs: now) }
    }
}
