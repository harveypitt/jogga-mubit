import CoreLocation
import MapKit
import SwiftUI

/// First screen before sign-in: a real run replays on the map with the live coach's cues,
/// then the week plan ticks it off. Shows what Jogga does before asking for anything.
struct DemoIntroView: View {
    var onStart: () -> Void
    var onSignIn: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date.now
    @State private var appeared = false

    private let demo = DemoRun.sample
    private static let runSeconds = 9.0
    private static let planSeconds = 4.5
    private static var loop: Double { runSeconds + planSeconds }

    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.animation(paused: reduceMotion)) { context in
                let t = reduceMotion ? Self.runSeconds : context.date.timeIntervalSince(startedAt)
                    .truncatingRemainder(dividingBy: Self.loop)
                stage(t: t)
            }
            .frame(maxHeight: .infinity)
            .padding(.top, 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "A \(Int(demo.km)) kilometre run around \(demo.place) replays on a map while the coach "
                    + "calls out splits, then the week's plan ticks it off."
            )

            VStack(spacing: 10) {
                Text("A coach that plans\naround your week.")
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .tracking(-0.5)
                    .multilineTextAlignment(.center)
                Text("It talks you through every run, then plans the next ones.")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 26)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 10)

            VStack(spacing: 14) {
                Button(action: onStart) {
                    Text("Get started")
                        .font(.system(.headline, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Color.brand, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(PressableStyle(scale: 0.97))
                Button("I already have an account", action: onSignIn)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 28)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .background(Color(.systemGroupedBackground))
        .onAppear {
            startedAt = .now
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.8).delay(0.2)) { appeared = true }
        }
    }

    @ViewBuilder
    private func stage(t: Double) -> some View {
        let runDone = t >= Self.runSeconds
        let progress = min(t / Self.runSeconds, 1)
        ZStack {
            mapCard(progress: progress)
                .opacity(runDone ? 0 : 1)
                .scaleEffect(runDone ? 0.94 : 1)
            planCard(t: t - Self.runSeconds)
                .opacity(runDone ? 1 : 0)
                .scaleEffect(runDone ? 1 : 1.04)
        }
        .animation(.smooth(duration: 0.45), value: runDone)
    }

    // MARK: Run replay

    private func mapCard(progress: Double) -> some View {
        let km = progress * demo.km
        let split = min(Int(km), demo.splits.count - 1)
        return VStack(spacing: 0) {
            MapReader { proxy in
                Map(initialPosition: .rect(demo.rect), interactionModes: []) {}
                    .mapStyle(.standard(pointsOfInterest: .excludingAll))
                    .overlay { RouteTrace(demo: demo, proxy: proxy, progress: progress) }
            }
            .allowsHitTesting(false)
            .overlay(alignment: .top) {
                if let cue = demo.cue(at: km) {
                    CoachCue(text: cue)
                        .padding(12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .id(cue)
                }
            }
            .animation(.snappy(duration: 0.35), value: demo.cue(at: km))

            VStack(alignment: .leading, spacing: 8) {
                Label(demo.place, systemImage: "location.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline) {
                    stat(String(format: "%.2f", km), unit: "km")
                    Spacer()
                    stat(Fmt.pace(demo.splits[split]), unit: "/km")
                    Spacer()
                    stat(Self.clock(demo.seconds(atKm: km)), unit: nil)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color(.secondarySystemGroupedBackground))
        }
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 10)
    }

    private func stat(_ value: String, unit: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            if let unit {
                Text(unit)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Plan

    private func planCard(t: Double) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("This week's plan").statLabel()
                Spacer()
                Text("\(t > 0.9 ? 1 : 0) of \(DemoRun.week.filter { $0.km > 0 }.count) done")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            VStack(spacing: 0) {
                ForEach(Array(DemoRun.week.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider() }
                    let shown = t > 0.15 + Double(index) * 0.18
                    let done = row.done || (row.today && t > 0.9)
                    HStack(spacing: 12) {
                        Text(row.day)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(row.today ? Color.brand : Color.secondary)
                            .frame(width: 36, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).font(.body.weight(.medium))
                            Text(row.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if row.km > 0 {
                            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(done ? Color.brand : Color.secondary.opacity(0.4))
                                .symbolEffect(.bounce, value: done)
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .padding(.vertical, 10)
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 8)
                    .animation(.snappy(duration: 0.35), value: shown)
                    .animation(.snappy(duration: 0.35), value: done)
                }
            }
            Spacer(minLength: 0)
            WeekBars(t: t)
            Text("Rest tomorrow, then three easy runs to finish the week.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
                .opacity(t > 1.4 ? 1 : 0)
                .animation(.smooth(duration: 0.4), value: t > 1.4)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 20, y: 10)
    }
}

/// The route drawn up to `progress`, one stroke per km coloured by that km's pace.
struct RouteTrace: View {
    let demo: DemoRun
    let proxy: MapProxy
    let progress: Double

    var body: some View {
        let points = demo.route.compactMap { proxy.convert($0, to: .local) }
        if points.count == demo.route.count {
            ZStack {
                ForEach(demo.kmRanges.indices, id: \.self) { k in
                    let range = demo.kmRanges[k]
                    let local = (progress - range.lo) / (range.hi - range.lo)
                    if local > 0 {
                        Path { path in path.addLines(Array(points[range.indices])) }
                            .trim(from: 0, to: min(local, 1))
                            .stroke(
                                PaceColor.color(demo.score(k)),
                                style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                            )
                    }
                }
                if let tip = demo.index(at: progress), progress < 1 {
                    RunnerDot().position(points[tip])
                } else if let last = points.last {
                    RunnerDot().position(last)
                }
            }
        }
    }
}

/// Mon–Sun distance bars: planned runs faint, today's run fills in once it's ticked off.
private struct WeekBars: View {
    var t: Double
    private let days = ["M", "T", "W", "T", "F", "S", "S"]
    private let planned: [Double] = {
        var km = Array(repeating: 0.0, count: 7)
        for row in DemoRun.week { km[row.weekday] = row.km }
        return km
    }()
    private var done: Bool { t > 0.9 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(done ? String(format: "%.1f", planned[0]) : "0")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text("/\(Int(planned.reduce(0, +).rounded())) km this week")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .animation(.snappy, value: done)
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(days.indices, id: \.self) { i in
                    let shown = t > 0.2
                    VStack(spacing: 6) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(planned[i] > 0 ? Color.brand.opacity(0.18) : Color.secondary.opacity(0.15))
                                .frame(height: shown ? 8 + planned[i] * 5 : 8)
                            if i == 0 {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.brand)
                                    .frame(height: done ? 8 + planned[i] * 5 : 0)
                            }
                        }
                        Text(days[i]).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 76, alignment: .bottom)
            .animation(.spring(duration: 0.6, bounce: 0.3), value: t > 0.2)
            .animation(.spring(duration: 0.6, bounce: 0.3), value: done)
        }
    }
}

private struct RunnerDot: View {
    var body: some View {
        Circle()
            .fill(Color.brand)
            .frame(width: 16, height: 16)
            .overlay(Circle().strokeBorder(.white, lineWidth: 3))
            .shadow(color: Color.brand.opacity(0.5), radius: 6)
    }
}

private struct CoachCue: View {
    var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.brand, in: Circle())
                .symbolEffect(.variableColor.iterative, options: .repeating)
            Text(text)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// One of Harvey's real runs, from `demo-route.json` (built from his GPX with the first and
/// last 300 m cut so the start and finish aren't shown).
struct DemoRun: Decodable {
    struct Day {
        let day: String
        let weekday: Int
        let title: String
        let detail: String
        var km = 0.0
        var done = false
        var today = false
    }

    struct Cue: Decodable {
        let km: Double
        let text: String
    }

    let place: String
    let cues: [Cue]

    let route: [CLLocationCoordinate2D]
    /// Cumulative fraction of the route's length at each point.
    let fractions: [Double]
    let km: Double
    /// Seconds per km, one per split.
    let splits: [Double]
    let rect: MKMapRect

    /// The week that run sat in (31 Aug), as the planner would show it straight after.
    static let week: [Day] = [
        Day(day: "Mon", weekday: 0, title: "Long run 11.2 km", detail: "6:10 /km", km: 11.2, today: true),
        Day(day: "Wed", weekday: 2, title: "Easy 5 km", detail: "6:15 /km", km: 5),
        Day(day: "Fri", weekday: 4, title: "Easy 8 km", detail: "6:15 /km", km: 8),
        Day(day: "Sun", weekday: 6, title: "Easy 5 km", detail: "6:15 /km", km: 5.4),
    ]

    static let sample: DemoRun = {
        guard let url = Bundle.main.url(forResource: "demo-route", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let run = try? JSONDecoder().decode(DemoRun.self, from: data)
        else { fatalError("demo-route.json missing or invalid") }
        return run
    }()

    private enum CodingKeys: String, CodingKey { case place, km, splits, cues, route }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        place = try c.decode(String.self, forKey: .place)
        km = try c.decode(Double.self, forKey: .km)
        splits = try c.decode([Double].self, forKey: .splits)
        cues = try c.decode([Cue].self, forKey: .cues)
        route = try c.decode([[Double]].self, forKey: .route)
            .map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
        var total = 0.0
        var cumulative = [0.0]
        for i in route.indices.dropFirst() {
            total += CLLocation(latitude: route[i - 1].latitude, longitude: route[i - 1].longitude)
                .distance(from: CLLocation(latitude: route[i].latitude, longitude: route[i].longitude))
            cumulative.append(total)
        }
        fractions = cumulative.map { total > 0 ? $0 / total : 0 }
        let line = MKPolyline(coordinates: route, count: route.count).boundingMapRect
        rect = line.insetBy(dx: -line.width * 0.15, dy: -line.height * 0.15)
    }

    func index(at progress: Double) -> Int? {
        guard progress > 0 else { return nil }
        return fractions.lastIndex(where: { $0 <= progress })
    }

    /// Route point ranges for each km (sharing end points so strokes join up).
    var kmRanges: [(lo: Double, hi: Double, indices: ClosedRange<Int>)] {
        splits.indices.compactMap { k in
            let lo = Double(k) / km, hi = min(Double(k + 1) / km, 1)
            guard let first = fractions.lastIndex(where: { $0 <= lo }),
                  let last = fractions.firstIndex(where: { $0 >= hi }) ?? fractions.indices.last,
                  last > first else { return nil }
            return (lo, hi, first...last)
        }
    }

    func score(_ k: Int) -> Double {
        let fastest = splits.min() ?? 0, slowest = splits.max() ?? 1
        return (slowest - splits[k]) / (slowest - fastest)
    }

    func seconds(atKm distance: Double) -> Double {
        var s = 0.0
        for k in splits.indices {
            let part = min(max(distance - Double(k), 0), 1)
            s += part * splits[k]
        }
        return s
    }

    func cue(at distance: Double) -> String? {
        cues.last { distance >= $0.km && distance < $0.km + 1.6 }?.text
    }
}
