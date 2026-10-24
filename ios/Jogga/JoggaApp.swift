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
                    recorder.requestAuthorization()
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-demoRun") {
                        if let next = store.latestCoach?.payload.next {
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

    var body: some View {
        Group {
            if auth.signedIn {
                MainTabView()
            } else {
                SignInView()
            }
        }
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
