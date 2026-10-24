import Foundation
import PostHog
import SwiftUI

enum AnalyticsEvent: String {
    case runStarted = "run_started"
    case runCompleted = "run_completed"
    case runAbandoned = "run_abandoned"
    case cuePlayed = "cue_played"
    case coachMuted = "coach_muted"
    case shareCardCreated = "share_card_created"
    case inviteSent = "invite_sent"
    case paywallViewed = "paywall_viewed"
    case trialStarted = "trial_started"
    case subscriptionStarted = "subscription_started"
    case stravaImported = "strava_imported"
    case signInStarted = "sign_in_started"
    case signInFailed = "sign_in_failed"
    case signInCompleted = "sign_in_completed"
    case screenTime = "screen_time"
    /// Grades and categories only: never km, paces or cadence.
    case reportCardViewed = "report_card_viewed"
    case reportCardRowOpened = "report_card_row_opened"
    case reportFocusFollowed = "report_focus_followed"
    /// Multiple-choice answers and yes/no flags only: never injury details or notes.
    case runSurveySubmitted = "run_survey_submitted"
    case runSurveySkipped = "run_survey_skipped"
}

enum Screen: String {
    case signIn = "sign_in", run, report, progress, history
    /// Post-run sheet (RunSummaryView isNew == true).
    case runSummary = "run_summary"
    /// RunSummaryView from History/Run tab (isNew == false).
    case runDetail = "run_detail"
    case routeMap = "route_map", activeRun = "active_run", settings
    case stravaImport = "strava_import", target, license
    case runSurvey = "run_survey"
}

enum AnalyticsValue {
    case string(String)
    case int(Int)
    case bool(Bool)

    fileprivate var postHogValue: Any {
        switch self {
        case .string(let value): return value
        case .int(let value): return value
        case .bool(let value): return value
        }
    }
}

/// Never send GPS/route, heart rate or HealthKit data; bands, not raw numbers.
enum Analytics {
    private static let coachFeedbackSurveyID = "01a0fd36-3c64-0000-9718-57e1e0ff40ee"
    private static let coachFeedbackQuestionID = "9a722453-5544-46d0-8f45-67ee0fa43096"

    static func setup() {
        let config = PostHogConfig(
            projectToken: "phc_ryKhzb8WEQ5sgjAa2kQbRLfCWxQLxApSwR4mpaGhnQUs",
            host: "https://eu.i.posthog.com"
        )
        config.captureApplicationLifecycleEvents = true
        config.captureScreenViews = false
        config.captureElementInteractions = false
        config.captureSwiftUIElementInteractions = false
        config.sessionReplay = false
        config.surveys = false
        config.personProfiles = .identifiedOnly
        #if DEBUG
        config.optOut = !ProcessInfo.processInfo.arguments.contains("-analytics")
        #endif
        PostHogSDK.shared.setup(config)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-analytics") {
            PostHogSDK.shared.optIn()
        } else {
            PostHogSDK.shared.optOut()
        }
        #endif
    }

    static func identify(userID: UUID) {
        PostHogSDK.shared.identify(userID.uuidString)
    }

    static func reset() {
        PostHogSDK.shared.reset()
    }

    static func capture(
        _ event: AnalyticsEvent,
        _ properties: [String: AnalyticsValue] = [:]
    ) {
        PostHogSDK.shared.capture(
            event.rawValue,
            properties: properties.mapValues(\.postHogValue)
        )
    }

    static func coachFeedbackShown(runID: UUID) {
        PostHogSDK.shared.capture(
            "survey shown",
            properties: [
                "$survey_id": coachFeedbackSurveyID,
                "$ai_trace_id": runID.uuidString.lowercased(),
            ]
        )
    }

    static func coachFeedback(runID: UUID, helpful: Bool) {
        PostHogSDK.shared.capture(
            "survey sent",
            properties: [
                "$survey_id": coachFeedbackSurveyID,
                "$survey_response_\(coachFeedbackQuestionID)": helpful ? 1 : 2,
                "$ai_trace_id": runID.uuidString.lowercased(),
                "$survey_submission_id": UUID().uuidString.lowercased(),
                "$survey_completed": true,
            ]
        )
    }

    static func distanceBand(metres: Double) -> String {
        if metres < 1_000 { return "<1k" }
        if metres < 3_000 { return "1-3k" }
        if metres < 5_000 { return "3-5k" }
        if metres < 8_000 { return "5-8k" }
        if metres < 10_000 { return "8-10k" }
        if metres < 15_000 { return "10-15k" }
        if metres < 21_000 { return "15-21k" }
        if metres < 30_000 { return "21-30k" }
        if metres < 42_000 { return "30-42k" }
        return "42k+"
    }

    static func durationBand(seconds: Double) -> String {
        guard seconds.isFinite else { return seconds > 0 ? "180m+" : "0-5m" }
        let seconds = max(0, seconds)
        if seconds >= 180 * 60 { return "180m+" }
        if seconds < 60 * 60 {
            let lower = Int(seconds / (5 * 60)) * 5
            return "\(lower)-\(lower + 5)m"
        }
        let lower = 60 + Int((seconds - 60 * 60) / (15 * 60)) * 15
        return "\(lower)-\(lower + 15)m"
    }

    static func countBand(_ count: Int) -> String {
        if count == 0 { return "0" }
        if count <= 10 { return "1-10" }
        if count <= 50 { return "11-50" }
        if count <= 200 { return "51-200" }
        if count <= 1_000 { return "201-1000" }
        return "1000+"
    }

    static func standardDistance(metres: Double) -> String? {
        RunMath.standardDistances.last(where: { metres >= $0.metres })?.key
    }
}

enum ScreenTrackerOutput: Equatable {
    case screen(Screen)
    case time(Screen, seconds: Int)
}

/// Tracks which screen is visible and for how long. A stack, so sheets push
/// over the screen underneath and tabs can appear/disappear in either order.
/// Emits $screen for PostHog Paths and `screen_time` on each closed segment.
@MainActor
final class ScreenTracker {
    static let shared = ScreenTracker()

    private struct Entry {
        let screen: Screen
        let token: UUID
    }

    private var stack: [Entry] = []
    /// The screen currently being timed; nil while backgrounded or empty.
    private var segment: (screen: Screen, start: Date)?
    private var active = true
    private let now: () -> Date
    private let sink: (ScreenTrackerOutput) -> Void

    init(
        now: @escaping () -> Date = { .now },
        sink: @escaping (ScreenTrackerOutput) -> Void = { output in
            switch output {
            case .screen(let screen):
                PostHogSDK.shared.screen(screen.rawValue)
            case .time(let screen, let seconds):
                Analytics.capture(.screenTime, [
                    "screen": .string(screen.rawValue),
                    "duration_s": .int(seconds),
                ])
            }
        }
    ) {
        self.now = now
        self.sink = sink
    }

    /// Push a screen. Returns the token to pass to `leave`.
    @discardableResult
    func enter(_ screen: Screen) -> UUID {
        let previousTop = stack.last?.screen
        let token = UUID()
        stack.append(Entry(screen: screen, token: token))
        if active, previousTop != screen {
            closeSegment()
            sink(.screen(screen))
            segment = (screen, now())
        }
        return token
    }

    /// Remove the screen that entered with `token`, wherever it sits.
    func leave(_ token: UUID) {
        guard let index = stack.firstIndex(where: { $0.token == token }) else { return }
        let wasTop = index == stack.count - 1
        stack.remove(at: index)
        guard wasTop, active else { return }
        closeSegment()
        if let top = stack.last {
            sink(.screen(top.screen))
            segment = (top.screen, now())
        }
    }

    func appBackgrounded() {
        guard active else { return }
        active = false
        closeSegment()
    }

    func appForegrounded() {
        guard !active else { return }
        active = true
        if let top = stack.last {
            sink(.screen(top.screen))
            segment = (top.screen, now())
        }
    }

    private func closeSegment() {
        guard let segment else { return }
        let seconds = Int(now().timeIntervalSince(segment.start).rounded())
        if seconds >= 1 {
            sink(.time(segment.screen, seconds: seconds))
        }
        self.segment = nil
    }
}

private struct ScreenTrackingModifier: ViewModifier {
    let screen: Screen
    @State private var token: UUID?

    func body(content: Content) -> some View {
        content
            .onAppear { token = ScreenTracker.shared.enter(screen) }
            .onDisappear {
                if let token {
                    ScreenTracker.shared.leave(token)
                    self.token = nil
                }
            }
    }
}

extension View {
    func trackScreen(_ screen: Screen) -> some View {
        modifier(ScreenTrackingModifier(screen: screen))
    }
}

extension CoachMode {
    var analyticsWorkout: String {
        switch self {
        case .free: return "free"
        case .plan(let kind, _, _): return kind
        case .race: return "race"
        }
    }
}
