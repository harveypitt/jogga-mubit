import Foundation

/// Numbers as an en-GB speaker would say them.
enum SpokenNumbers {
    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .spellOut
        f.locale = Locale(identifier: "en_GB")
        return f
    }()

    static func word(_ n: Int) -> String {
        (formatter.string(from: NSNumber(value: n)) ?? "\(n)").lowercased()
    }

    /// `5:12` pace → "five twelve", `5:05` → "five oh five", `5:00` →
    /// "five flat"; ≥ 1 h → "one hour four".
    static func pace(_ sPerKm: Double) -> String {
        let s = Int(sPerKm.rounded())
        if s >= 3600 {
            let h = s / 3600
            let m = Int((Double(s % 3600) / 60).rounded())
            let unit = h == 1 ? "hour" : "hours"
            return m == 0 ? "\(word(h)) \(unit)" : "\(word(h)) \(unit) \(word(m))"
        }
        return clockStyle(s)
    }

    /// PB/target total → "twenty-seven flat", "twenty-seven oh five";
    /// ≥ 1 h → "one hour, fifty-two".
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 {
            var h = s / 3600
            var m = Int((Double(s % 3600) / 60).rounded())
            if m == 60 { h += 1; m = 0 }
            let unit = h == 1 ? "hour" : "hours"
            return m == 0 ? "\(word(h)) \(unit)" : "\(word(h)) \(unit), \(word(m))"
        }
        return clockStyle(s)
    }

    /// Shared mm:ss phrasing: "twenty-seven oh five".
    private static func clockStyle(_ s: Int) -> String {
        let m = s / 60
        let r = s % 60
        if r == 0 { return "\(word(m)) flat" }
        if r < 10 { return "\(word(m)) oh \(word(r))" }
        return "\(word(m)) \(word(r))"
    }

    /// Compact split phrasing: 336 → "five thirty-six", 304 → "five oh four",
    /// 300 → "five minutes flat"; ≥ 1 h falls back to minutesSeconds.
    static func shortSplit(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return minutesSeconds(seconds) }
        let m = s / 60
        let r = s % 60
        if r == 0 { return "\(word(m)) minutes flat" }
        if r < 10 { return "\(word(m)) oh \(word(r))" }
        return "\(word(m)) \(word(r))"
    }

    /// Compact total-time phrasing like "seventeen twenty-six".
    static func shortClock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return minutesSeconds(seconds) }
        let m = s / 60
        let r = s % 60
        if r == 0 { return "\(word(m)) flat" }
        if r < 10 { return "\(word(m)) oh \(word(r))" }
        return "\(word(m)) \(word(r))"
    }

    /// 1 → "one second", 8 → "eight seconds", ≥ 60 → "over a minute".
    static func seconds(_ s: Int) -> String {
        if s >= 60 { return "over a minute" }
        if s == 1 { return "one second" }
        return "\(word(s)) seconds"
    }

    /// Split/total times: 336 → "five minutes thirty-six seconds",
    /// 300 → "five minutes", 61 → "one minute one second",
    /// ≥ 1 h → "one hour four minutes" (seconds dropped).
    static func minutesSeconds(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 {
            var h = s / 3600
            var m = Int((Double(s % 3600) / 60).rounded())
            if m == 60 { h += 1; m = 0 }
            let unit = h == 1 ? "hour" : "hours"
            return m == 0
                ? "\(word(h)) \(unit)"
                : "\(word(h)) \(unit) \(word(m)) minutes"
        }
        let m = s / 60
        let r = s % 60
        if r == 0 {
            return m == 1 ? "one minute" : "\(word(m)) minutes"
        }
        let minPart = m == 1 ? "one minute" : "\(word(m)) minutes"
        let secPart = r == 1 ? "one second" : "\(word(r)) seconds"
        return "\(minPart) \(secPart)"
    }

    /// 1 → "one kilometre", 3 → "three kilometres".
    static func kilometres(_ n: Int) -> String {
        n == 1 ? "one kilometre" : "\(word(n)) kilometres"
    }

    /// 800 → "eight hundred metres".
    static func metres(_ m: Int) -> String {
        "\(word(m)) metres"
    }

    /// 4.0 → "four", 4.5 → "four point five"; km index 3 → "three".
    static func km(_ km: Double) -> String {
        (formatter.string(from: NSNumber(value: km)) ?? "\(km)").lowercased()
    }
}
