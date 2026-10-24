import SwiftUI

/// Settings sheet: name, sign out, DEBUG server URL.
struct SettingsView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(RunStore.self) private var store
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss
    @AppStorage("jogga.coachLevel") private var coachLevel = CueLevel.everyKm.rawValue
    @AppStorage("jogga.coachLog") private var coachLog = true
    @AppStorage("jogga.coachVoice") private var coachVoice = CoachVoiceChoice.current.rawValue
    @State private var previewVoice: CoachVoice?
    @State private var showLicense = false
    @State private var speedTesting = false
    @State private var speedResults: [String] = []
    @State private var showStravaImport = false
    @State private var confirmRemoveStrava = false
    @State private var removingStrava = false

    static let previewText =
        "Last kilometre split, five minutes thirty-six seconds. "
        + "Distance so far, three kilometres in seventeen "
        + "minutes twenty-six seconds. That's good progress "
        + "compared to your PB."
    @Environment(RunStore.self) private var profileStore
    @State private var showProfile = false
    #if DEBUG
    @State private var serverURL = UserDefaults.standard.string(forKey: "jogga.apiURL") ?? ""
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Name", value: auth.displayName ?? "Runner")
                }
                Section {
                    Button {
                        showProfile = true
                    } label: {
                        LabeledContent("Training preferences") {
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                    .sheet(isPresented: $showProfile) {
                        OnboardingView(initial: profileStore.profile)
                    }
                } footer: {
                    Text("Your goal, the days you can run and anything you'd rather skip.")
                }
                #if DEBUG
                Section("Server") {
                    TextField("http://localhost:8000", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .onChange(of: serverURL) { _, new in
                            UserDefaults.standard.set(new, forKey: "jogga.apiURL")
                        }
                    Text(api.baseURL.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                #endif
                Section {
                    Picker("Voice cues", selection: $coachLevel) {
                        ForEach(CueLevel.allCases, id: \.rawValue) { level in
                            Text(level.label).tag(level.rawValue)
                        }
                    }
                    .onChange(of: coachLevel) { oldLevel, newLevel in
                        guard oldLevel != CueLevel.off.rawValue,
                              newLevel == CueLevel.off.rawValue else { return }
                        Analytics.capture(.coachMuted, [
                            "from": .string(oldLevel),
                        ])
                    }
                    Toggle("Show coach log", isOn: $coachLog)
                    Picker("Voice", selection: $coachVoice) {
                        ForEach(CoachVoiceChoice.allCases, id: \.rawValue) { choice in
                            Text(choice.label).tag(choice.rawValue)
                        }
                    }
                    Button {
                        let voice = previewVoice ?? CoachVoiceChoice.make()
                        previewVoice = voice
                        (voice as? NeuTTSVoice)?.prepare()
                        voice.speak(Self.previewText, emotion: .happy)
                    } label: {
                        Label("Preview voice", systemImage: "play.circle")
                    }
                    if NeuTTSVoice.modelsBundled {
                        Button {
                            speedTest()
                        } label: {
                            Label("Test voice speed", systemImage: "gauge")
                        }
                        .disabled(speedTesting)
                        if speedTesting { ProgressView() }
                        ForEach(speedResults, id: \.self) { line in
                            Text(line)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                        if !speedResults.isEmpty {
                            Button("Copy results") {
                                var machine = ""
                                var sys = utsname()
                                withUnsafeMutableBytes(of: &sys.machine) { buf in
                                    machine = String(cString: buf.baseAddress!
                                        .assumingMemoryBound(to: CChar.self))
                                }
                                UIPasteboard.general.string =
                                    ([machine] + speedResults)
                                    .joined(separator: "\n")
                            }
                        }
                    }
                    if NeuTTSVoice.licenseText != nil {
                        Button("Neuphonic voice licence") {
                            showLicense = true
                        }
                    }
                } header: {
                    Text("Audio coach")
                } footer: {
                    Text("\(CueLevel(rawValue: coachLevel)?.footer ?? CueLevel.everyKm.footer) The Neuphonic voice runs entirely on your iPhone, offline. Nothing leaves the device.")
                }
                Section {
                    Button {
                        showStravaImport = true
                    } label: {
                        Label("Import from Strava", systemImage: "square.and.arrow.down")
                    }
                    if stravaRuns > 0 {
                        Button(role: .destructive) {
                            confirmRemoveStrava = true
                        } label: {
                            HStack {
                                Label("Remove imported runs", systemImage: "trash")
                                Spacer()
                                if removingStrava { ProgressView() }
                            }
                        }
                        .disabled(removingStrava)
                    }
                } header: {
                    Text("History")
                } footer: {
                    Text(stravaRuns > 0
                        ? "\(stravaRuns) runs imported from Strava. Routes stay on your iPhone."
                        : "Bring over your past runs so your coach knows your history.")
                }
                Section {
                    Button("Sign out", role: .destructive) {
                        auth.signOut()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showStravaImport) {
                StravaImportView()
            }
            .confirmationDialog(
                "Remove \(stravaRuns) imported runs?", isPresented: $confirmRemoveStrava,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    removingStrava = true
                    Task {
                        try? await store.removeImported(source: StravaImporter.source)
                        removingStrava = false
                    }
                }
            } message: {
                Text("Runs recorded in Jogga are kept. You can import again at any time.")
            }
            .sheet(isPresented: $showLicense) {
                NavigationStack {
                    ScrollView {
                        Text(NeuTTSVoice.licenseText ?? "")
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .navigationTitle("NeuTTS Open Licence")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showLicense = false }
                        }
                    }
                }
                .trackScreen(.license)
            }
            .onDisappear { previewVoice?.stop() }
        }
        .trackScreen(.settings)
    }

    private var stravaRuns: Int {
        store.runs.filter { $0.source == StravaImporter.source }.count
    }

    /// Render the preview line at 2 then 4 threads, keep the faster count,
    /// report timings, and play the faster take. Off the main thread.
    private func speedTest() {
        speedTesting = true
        speedResults = []
        Task.detached { [self] in
            let voice = previewVoice as? NeuTTSVoice ?? NeuTTSVoice()
            await MainActor.run { previewVoice = voice }
            voice.prepare()
            let deadline = Date().addingTimeInterval(240)
            while !voice.isReady, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard voice.isReady else {
                await MainActor.run { speedTesting = false }
                return
            }
            var lines: [String] = []
            var faster: (pcm: [Float], threads: Int, synthS: Double)?
            for threads in [Int32(2), Int32(4)] {
                guard let r = voice.speedTestRender(
                    Self.previewText, threads: threads)
                else { continue }
                let tok = Double(r.stats.genTokens ?? 0)
                let genS = r.stats.genS ?? 0
                let tokps = genS > 0 ? tok / genS : 0
                let audioS = r.stats.audioS ?? 0
                let realtime = audioS > 0 ? (r.stats.synthS ?? 0) / audioS : 0
                lines.append(String(
                    format:
                      "%d threads: prefill %.1f s · %d tok in %.1f s "
                    + "(%.0f tok/s) · decode %.1f s · %.1f s audio "
                    + "· %.2f× real time",
                    threads, r.stats.prefillS ?? 0, Int(tok), genS,
                    tokps, r.stats.decodeS ?? 0, audioS, realtime))
                if faster == nil || (r.stats.synthS ?? 1e9)
                    < (faster?.synthS ?? 1e9) {
                    faster = (r.pcm, Int(threads), r.stats.synthS ?? 0)
                }
            }
            await MainActor.run {
                speedResults = lines
                speedTesting = false
                if let faster {
                    UserDefaults.standard.set(
                        faster.threads, forKey: "jogga.neuttsThreads")
                    voice.play(faster.pcm)
                }
            }
        }
    }
}
