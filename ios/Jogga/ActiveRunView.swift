import MapKit
import SwiftUI

/// Full-screen active run: map, bottom stats panel on material,
/// pause/resume, hold-to-finish ring, accent countdown.
struct ActiveRunView: View {
    @Environment(RunRecorder.self) private var recorder
    @Environment(AudioCoach.self) private var coach
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var holdProgress: Double = 0
    @State private var holding = false
    @State private var finishedRun: Run?
    @State private var showDiscardConfirm = false

    private var paused: Bool { recorder.state == .paused }

    var body: some View {
        ZStack {
            map
            if recorder.state == .countdown {
                countdownOverlay
                    .transition(.opacity)
            } else {
                VStack(spacing: 12) {
                    statusPill
                    Spacer()
                    panel
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .smooth, value: recorder.state)
        .sensoryFeedback(.impact(weight: .light), trigger: recorder.kmTick)
        .sensoryFeedback(.success, trigger: finishedRun != nil)
        .sheet(item: $finishedRun) { run in
            RunSummaryView(run: run, isNew: true) {
                finishedRun = nil
                recorder.reset()
                dismiss()
            }
            .interactiveDismissDisabled()
        }
        .onChange(of: recorder.state) { oldState, newState in
            guard oldState == .countdown, newState == .running else { return }
            Analytics.capture(.runStarted, [
                "workout": .string(coach.mode.analyticsWorkout),
                "coach_on": .bool(CueLevel.current != .off),
                "coach_level": .string(CueLevel.current.rawValue),
            ])
        }
        .onChange(of: recorder.route.count) { _, _ in
            guard let last = recorder.route.last else { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.8)) {
                position = .camera(MapCamera(centerCoordinate: last.coordinate, distance: 900))
            }
        }
        .trackScreen(.activeRun)
    }

    // MARK: Map

    private var map: some View {
        Map(position: $position, interactionModes: [.zoom, .pan]) {
            if recorder.route.count > 1 {
                MapPolyline(coordinates: recorder.route.map(\.coordinate))
                    .stroke(Color.brand, style: StrokeStyle(
                        lineWidth: 7, lineCap: .round, lineJoin: .round
                    ))
            }
            if let last = recorder.route.last {
                Annotation("", coordinate: last.coordinate) {
                    Circle()
                        .fill(Color.brand)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(.white, lineWidth: 3))
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                }
            } else {
                UserAnnotation()
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControlVisibility(.hidden)
        .saturation(paused ? 0 : 1)
        .ignoresSafeArea()
    }

    // MARK: Countdown

    private var countdownOverlay: some View {
        ZStack {
            Rectangle()
                .fill(Color.brand.gradient)
                .ignoresSafeArea()
            VStack(spacing: 8) {
                Text("Ready")
                    .font(Jogga.rounded(.title2, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                Text("\(max(recorder.countdown, 1))")
                    .font(Jogga.numerals(180, weight: .heavy))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(reduceMotion ? nil : .snappy, value: recorder.countdown)
            }
            VStack {
                HStack {
                    Spacer()
                    Button {
                        coach.cancel()
                        recorder.reset()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.white.opacity(0.2), in: Circle())
                    }
                    .accessibilityLabel("Cancel run")
                }
                Spacer()
            }
            .padding(20)
        }
        .sensoryFeedback(.impact(weight: .heavy), trigger: recorder.countdown)
    }

    // MARK: Status

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(paused ? Color.secondary : Color.brand)
                .frame(width: 8, height: 8)
            Text(paused ? "Paused" : "Running")
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, 8)
    }

    // MARK: Bottom panel

    private var panel: some View {
        VStack(spacing: 22) {
            VStack(spacing: 2) {
                Text(RunMath.formatTime(recorder.elapsed))
                    .font(Jogga.numerals(84, weight: .bold))
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .accessibilityLabel("Elapsed time \(RunMath.formatTime(recorder.elapsed))")
                Text("Time").statLabel()
            }
            .frame(maxWidth: .infinity)

            HStack(alignment: .top) {
                StatCell(label: "Distance", value: Fmt.km(recorder.distanceM), unit: "km",
                         size: 28, alignment: .center)
                    .frame(maxWidth: .infinity)
                StatCell(label: "Pace", value: Fmt.pace(recorder.pace), unit: "/km",
                         size: 28, alignment: .center)
                    .frame(maxWidth: .infinity)
                StatCell(label: "Climb", value: "\(Int(recorder.gainM))", unit: "m",
                         size: 28, alignment: .center)
                    .frame(maxWidth: .infinity)
            }

            HStack(spacing: 40) {
                Button {
                    if paused { recorder.resume() } else { recorder.pause() }
                } label: {
                    Image(systemName: paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(paused ? .white : .primary)
                        .frame(width: 76, height: 76)
                        .background(paused ? AnyShapeStyle(Color.brand)
                            : AnyShapeStyle(Color(.tertiarySystemFill)), in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(paused ? "Resume" : "Pause")
                .sensoryFeedback(.impact(weight: .medium), trigger: paused)

                holdToFinish
            }

            if paused {
                Button("Discard") { showDiscardConfirm = true }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .smooth, value: paused)
        .confirmationDialog("Discard this run?", isPresented: $showDiscardConfirm,
                            titleVisibility: .visible) {
            Button("Discard Run", role: .destructive) {
                if recorder.state == .running || recorder.state == .paused {
                    Analytics.capture(.runAbandoned, [
                        "distance_band": .string(
                            Analytics.distanceBand(metres: recorder.distanceM)
                        ),
                        "duration_band": .string(
                            Analytics.durationBand(seconds: recorder.elapsed)
                        ),
                        "workout": .string(coach.mode.analyticsWorkout),
                        "coach_on": .bool(CueLevel.current != .off),
                        "coach_level": .string(CueLevel.current.rawValue),
                        "reason": .string("discarded"),
                        "had_gps_fix": .bool(!recorder.route.isEmpty),
                        "cues_spoken": .int(coach.spokenCueCount),
                    ])
                }
                coach.cancel()
                recorder.reset()
                dismiss()
            }
        } message: {
            Text("Nothing will be saved.")
        }
        .padding(.top, 26)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 40, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }

    /// Ring that fills over 1 s while held.
    private var holdToFinish: some View {
        VStack(spacing: 6) {
            Image(systemName: "stop.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Color.brand)
                .frame(width: 76, height: 76)
                .background(Color.brand.opacity(0.15), in: Circle())
                .overlay {
                    Circle()
                        .trim(from: 0, to: holdProgress)
                        .stroke(Color.brand, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(2.5)
                }
                .scaleEffect(holding ? 0.94 : 1)
                .animation(.snappy, value: holding)
        }
        .overlay(alignment: .bottom) {
            Text("Hold to finish")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
                .offset(y: 18)
                .opacity(holding ? 0 : 1)
        }
        .accessibilityLabel("Hold to finish")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { finishRun() }
        .sensoryFeedback(.impact(weight: .light), trigger: holding)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !holding else { return }
                    holding = true
                    withAnimation(.linear(duration: 1)) { holdProgress = 1 }
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        if holding, finishedRun == nil, recorder.state != .finished {
                            finishRun()
                        }
                    }
                }
                .onEnded { _ in
                    holding = false
                    withAnimation(.snappy) { holdProgress = 0 }
                }
        )
    }

    private func finishRun() {
        var run = recorder.finish()
        switch coach.mode {
        case .plan: run.mode = "plan"
        case .race: run.mode = "race"
        case .free: run.mode = "free"
        }
        let spokenCueCount = coach.spokenCueCount
        coach.finish(runID: run.id)
        var properties: [String: AnalyticsValue] = [
            "distance_band": .string(Analytics.distanceBand(metres: run.distanceM)),
            "duration_band": .string(Analytics.durationBand(seconds: run.movingS)),
            "workout": .string(coach.mode.analyticsWorkout),
            "coach_on": .bool(CueLevel.current != .off),
            "coach_level": .string(CueLevel.current.rawValue),
            "cues_spoken": .int(spokenCueCount),
        ]
        if let standardDistance = Analytics.standardDistance(metres: run.distanceM) {
            properties["standard_distance"] = .string(standardDistance)
        }
        Analytics.capture(.runCompleted, properties)
        finishedRun = run
    }
}
