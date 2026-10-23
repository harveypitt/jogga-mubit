import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Pools of short spoken lines used by the split composer. Defaults are
/// hand-written; when Apple Intelligence is available, extra lines are
/// generated on-device and merged in front of the defaults.
struct CoachLines {
    var settle: [String]
    var encourage: [String]
    var steady: [String]
    var finish: [String]
    /// "fm" when generated lines were merged in, "default" otherwise.
    var source: String

    func filtered(for mode: CoachMode) -> CoachLines {
        guard mode.isUnprescribed else { return self }
        func safe(_ lines: [String], fallback: [String]) -> [String] {
            let filtered = lines.filter { !Self.isPrescriptiveLine($0) }
            return filtered.isEmpty
                ? fallback.filter { !Self.isPrescriptiveLine($0) }
                : filtered
        }
        let defaults = Self.defaults
        return CoachLines(
            settle: safe(settle, fallback: defaults.settle),
            encourage: safe(encourage, fallback: defaults.encourage),
            steady: safe(steady, fallback: defaults.steady),
            finish: safe(finish, fallback: defaults.finish),
            source: source
        )
    }

    static let defaults = CoachLines(
        settle: [
            "Nice easy start.",
            "Settle into it.",
            "Good. Loosen up now.",
            "Off you go, nice and smooth.",
            "Steady away.",
        ],
        encourage: [
            "Keep it smooth.",
            "Looking strong.",
            "Stay tall and relaxed.",
            "Lovely rhythm.",
            "You're running well.",
            "Breathe easy, shoulders down.",
            "Nicely done.",
        ],
        steady: [
            "Hold this, nothing flashy.",
            "Keep the effort honest.",
            "Don't chase it, keep your own pace.",
            "Smooth it back out.",
            "Patience now, it pays later.",
        ],
        finish: [
            "That's the run. Well run.",
            "Home and done. Well run.",
            "Job done. Lovely work.",
            "That's it, walk it off when you're ready.",
            "Strong run, take it in.",
        ],
        source: "default"
    )

    /// Rejects digits, number words, distance/pace terms, long or empty
    /// lines — anything that would break the spoken phrasing.
    static func isValidLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return false }
        if trimmed.contains(where: \.isNumber) { return false }
        let banned: Set<String> = [
            "one", "two", "three", "four", "five", "six", "seven", "eight",
            "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
            "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
            "twenty", "thirty", "forty", "fifty", "sixty", "seventy",
            "eighty", "ninety", "hundred", "thousand", "half", "quarter",
            "kilometre", "kilometres", "kilometer", "kilometers", "km", "k",
            "metre", "metres", "mile", "miles", "minute", "minutes",
            "second", "seconds", "hour", "hours", "pace", "metres",
        ]
        let words = trimmed.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return !words.contains { banned.contains($0) }
    }

    private static func isPrescriptiveLine(_ line: String) -> Bool {
        let words = line.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let banned = ["ease", "easy", "slow", "patience", "rein", "settle"]
        return words.contains { word in
            banned.contains { word.hasPrefix($0) }
        } || line.lowercased().contains("back off")
            || line.lowercased().contains("hold back")
            || line.lowercased().contains("don't chase")
            || line.lowercased().contains("relax pace")
            || line.lowercased().contains("relax the pace")
            || line.lowercased().contains("relax your pace")
            || line.lowercased().contains("relax their pace")
            || line.lowercased().contains("relaxing pace")
            || line.lowercased().contains("relaxing the pace")
            || line.lowercased().contains("relaxing your pace")
    }
}

/// Generates extra coach lines with Foundation Models when available, in
/// the foreground from the Run tab. Cached per mode + calendar day.
@MainActor
enum CoachLineProvider {
    private static var cache: [String: CoachLines] = [:]

    /// Lines for today under this mode — cache hit, defaults otherwise.
    static func lines(for mode: CoachMode) -> CoachLines {
        (cache[key(mode)] ?? .defaults).filtered(for: mode)
    }

    /// Kick off generation; safe to call repeatedly.
    static func generate(mode: CoachMode, store: RunStore) {
        let k = key(mode)
        guard cache[k] == nil else { return }
        cache[k] = .defaults // reserve the slot so we don't stampede
        Task { await generateLines(mode: mode, store: store, key: k) }
    }

    private static func key(_ mode: CoachMode) -> String {
        let day = Calendar.current.startOfDay(for: .now)
            .timeIntervalSince1970
        return "\(mode)-\(Int(day))"
    }

    private static func generateLines(
        mode: CoachMode, store: RunStore, key: String
    ) async {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            if SystemLanguageModel.default.availability == .available,
               let lines = await fmLines(mode: mode, store: store) {
                cache[key] = lines
                return
            }
        }
        #endif
        cache[key] = .defaults
    }

    #if canImport(FoundationModels)
    @available(iOS 26, *)
    @Generable
    struct GeneratedLines {
        @Guide(description: "Short warm-up settling lines a coach would say at the start of a run", .count(6))
        var settle: [String]
        @Guide(description: "Short encouraging lines a coach would say mid-run", .count(6))
        var encourage: [String]
        @Guide(description: "Short keep-it-steady lines a coach would say mid-run", .count(6))
        var steady: [String]
        @Guide(description: "Short lines a coach would say as the runner completes the run", .count(6))
        var finish: [String]
    }

    @available(iOS 26, *)
    private static func fmLines(mode: CoachMode, store: RunStore) async -> CoachLines? {
        let style = switch mode {
        case let .plan(kind, _, _): "\(kind) training run"
        case .race: "a race effort"
        case .free: "a free run at the runner's own effort"
        }
        let planned = switch mode {
        case .plan: "a set distance"
        case .race: "a set distance"
        case .free: "no fixed distance"
        }
        let yardstick = store.targets.isEmpty && store.stats.isEmpty
            ? "no personal best or target on file"
            : "a personal best or target to compare against"
        let lastRun: String
        if let last = store.runs.first, store.runs.count > 1 {
            let prev = store.runs[1]
            lastRun = last.averagePace < prev.averagePace * 0.97
                ? "went quicker than the one before"
                : last.averagePace > prev.averagePace * 1.03
                ? "went slower than the one before" : "went much as usual"
        } else { lastRun = "is unknown" }
        let modeRule = mode.isUnprescribed
            ? "Do not tell the runner to slow down, ease off, hold back or relax their pace."
            : ""
        let prompt = """
            Write short spoken coaching lines for a runner on \(style), \
            covering \(planned), with \(yardstick). Their last comparable run \
            \(lastRun). Rules: each line must be a warm, natural British-English \
            coaching remark of at most ten words. Lines must contain no \
            numbers, no spelled-out numbers, and no times, distances or paces. \
            Do not mention today's date. \(modeRule)
            """
        guard let response = try? await LanguageModelSession()
            .respond(to: prompt, generating: GeneratedLines.self)
        else { return nil }
        let reply = response.content
        func clean(_ lines: [String]) -> [String] {
            var seen = Set<String>()
            return lines.filter {
                CoachLines.isValidLine($0) && seen.insert($0).inserted
            }
        }
        let d = CoachLines.defaults
        return CoachLines(
            settle: clean(reply.settle) + d.settle,
            encourage: clean(reply.encourage) + d.encourage,
            steady: clean(reply.steady) + d.steady,
            finish: clean(reply.finish) + d.finish,
            source: "fm"
        )
    }
    #endif
}
