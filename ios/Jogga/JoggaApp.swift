import SwiftUI

@main
struct JoggaApp: App {
    @State private var api = APIClient()
    @State private var auth: AuthStore
    @State private var store: RunStore
    @State private var recorder: RunRecorder
    @State private var coach: AudioCoach
    @Environment(\.scenePhase) private var scenePhase

    init() {
        RunLiveActivity.endAll()
        Analytics.setup()
        let api = APIClient()
        _api = State(initialValue: api)
        let auth = AuthStore(api: api)
        _auth = State(initialValue: auth)
        let store = RunStore(api: api)
        _store = State(initialValue: store)
        let recorder = RunRecorder()
        _recorder = State(initialValue: recorder)
        _coach = State(initialValue: AudioCoach(recorder: recorder))
        Jogga.configureAppearance()
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-seedRunsFile"),
           args.indices.contains(index + 1) {
            store.seedRunsFile(at: URL(fileURLWithPath: args[index + 1]))
        }
        if args.contains("-resetDemo") {
            DemoSeed.reset(store: store, api: api)
        }
        if args.contains("-seedDemo") {
            DemoSeed.seed(into: store)
        }
        if args.contains("-demoRun") || args.contains("-devSignIn"), api.token == nil {
            // Skip the sign-in screen; -demoRun also needs a session for upload.
            Task { await auth.devSignIn() }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(api)
                .environment(auth)
                .environment(store)
                .environment(recorder)
                .environment(coach)
                .task {
                    await store.refresh()
                }
                .onChange(of: auth.signedIn) { _, signedIn in
                    if signedIn {
                        Task { await store.refresh() }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        ScreenTracker.shared.appForegrounded()
                        Task { await store.refresh() }
                    } else if phase == .background {
                        ScreenTracker.shared.appBackgrounded()
                    }
                }
                .onAppear {
                    // New runners are asked on onboarding's location screen instead.
                    if auth.signedIn { recorder.requestAuthorization() }
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-demoRun") {
                        if let next = store.nextSession {
                            coach.begin(mode: .plan(kind: next.kind, km: next.km,
                                                    paceSPerKm: Double(next.pace)),
                                        store: store)
                        } else {
                            coach.begin(mode: .free, store: store)
                        }
                        recorder.beginCountdown()
                    }
                    #endif
                }
        }
    }
}

/// Shows sign-in until authed, then the tabs.
struct RootView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(RunStore.self) private var store
    #if DEBUG
    @State private var showOnboarding = ProcessInfo.processInfo.arguments.contains("-onboardingPreview")
    #else
    @State private var showOnboarding = false
    #endif

    @State private var inOnboarding = false
    @State private var showSignIn = false

    #if DEBUG
    private static let demoIntroPreview = ProcessInfo.processInfo.arguments.contains("-demoIntroPreview")
    private static let onboardingStep: OnboardingView.Step? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-onboardingStep"), i + 1 < args.count,
              let n = Int(args[i + 1]) else { return nil }
        return OnboardingView.Step(rawValue: n)
    }()
    #else
    private static let demoIntroPreview = false
    private static let onboardingStep: OnboardingView.Step? = nil
    #endif

    var body: some View {
        Group {
            if Self.demoIntroPreview {
                DemoIntroView(onStart: {}, onSignIn: {})
            } else if let step = Self.onboardingStep {
                OnboardingView(previewStep: step)
            } else if inOnboarding {
                OnboardingView(onFinish: { inOnboarding = false })
            } else if auth.signedIn {
                MainTabView()
                    .fullScreenCover(isPresented: $showOnboarding) { OnboardingView() }
                    .onChange(of: store.needsOnboarding, initial: true) { _, needs in
                        if needs { showOnboarding = true }
                    }
                    .onChange(of: showOnboarding, initial: true) { _, shown in
                        store.onboardingVisible = shown
                    }
            } else if showSignIn {
                SignInView()
            } else {
                DemoIntroView(onStart: { inOnboarding = true }, onSignIn: { showSignIn = true })
            }
        }
        .animation(.smooth(duration: 0.4), value: inOnboarding)
    }
}

struct MainTabView: View {
    @Environment(RunStore.self) private var store
    @State private var selection = 0
    @AppStorage(ReportCard.seenWeekKey) private var seenReportWeek = ""

    init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-startTab"),
           arguments.indices.contains(index + 1),
           let tab = Int(arguments[index + 1]),
           (0...3).contains(tab) {
            _selection = State(initialValue: tab)
        }
        #endif
    }

    var body: some View {
        TabView(selection: $selection) {
            RunTabView()
                .tabItem { Label("Run", systemImage: "figure.run") }
                .tag(0)
            ReportTabView()
                .tabItem { Label("Week", systemImage: "list.bullet.clipboard") }
                .badge(newReport ? 1 : 0)
                .tag(3)
            ProgressTabView()
                .tabItem { Label("Progress", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(1)
            HistoryTabView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(2)
        }
        .tint(.brand)
    }

    /// Last week's summary is in and hasn't been opened yet.
    private var newReport: Bool {
        guard let last = store.reportLastWeek, last.summary != nil else { return false }
        return last.weekStart != seenReportWeek
    }
}
