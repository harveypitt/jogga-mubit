import MapKit
import SwiftUI

extension Run {
    /// Bounding map rect of the route, padded by `padding` of its size on each side.
    func routeRect(padding: Double = 0.2) -> MKMapRect {
        let coordinates = route.map(\.coordinate)
        let rect = MKPolyline(coordinates: coordinates, count: coordinates.count).boundingMapRect
        let minSide = MKMapPointsPerMeterAtLatitude(route.first?.lat ?? 0) * 300
        let width = max(rect.width, minSide)
        let height = max(rect.height, minSide)
        return MKMapRect(
            x: rect.midX - width * (0.5 + padding),
            y: rect.midY - height * (0.5 + padding),
            width: width * (1 + 2 * padding),
            height: height * (1 + 2 * padding)
        )
    }
}

/// Pace colour ramp: sky (slower) → brand blue → deep navy (faster).
enum PaceColor {
    private static let stops: [(Double, Double, Double)] = [
        (0.49, 0.76, 1.00),
        (0.055, 0.443, 0.996),
        (0.12, 0.24, 0.78),
    ]

    static func color(_ score: Double) -> Color {
        let (r, g, b) = rgb(score)
        return Color(red: r, green: g, blue: b)
    }

    static var gradient: LinearGradient {
        LinearGradient(colors: [color(0), color(0.5), color(1)], startPoint: .leading, endPoint: .trailing)
    }

    private static func rgb(_ score: Double) -> (Double, Double, Double) {
        let s = min(max(score, 0), 1) * Double(stops.count - 1)
        let i = min(Int(s), stops.count - 2)
        let f = s - Double(i)
        let a = stops[i], b = stops[i + 1]
        return (a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f, a.2 + (b.2 - a.2) * f)
    }
}

/// Route polyline coloured by pace, with start and finish markers.
struct PaceRoute: MapContent {
    let run: Run
    let segments: [RoutePace.Segment]
    var lineWidth: CGFloat = 5

    var body: some MapContent {
        ForEach(segments.indices, id: \.self) { index in
            MapPolyline(coordinates: segments[index].coordinates)
                .stroke(PaceColor.color(segments[index].score),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        if let first = run.route.first {
            Annotation("Start", coordinate: first.coordinate) { RouteDot(filled: false) }
                .annotationTitles(.hidden)
        }
        if let last = run.route.last {
            Annotation("Finish", coordinate: last.coordinate) { RouteDot(filled: true) }
                .annotationTitles(.hidden)
        }
    }
}

struct RouteDot: View {
    var filled: Bool

    var body: some View {
        Circle()
            .fill(filled ? Color.brand : Color.white)
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(filled ? Color.white : Color.brand, lineWidth: 3))
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
    }
}

/// Static, cached map image of a route for list cards.
struct RouteThumbnail: View {
    let run: Run
    var height: CGFloat = 150

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var image: UIImage?
    @State private var attempt = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle().fill(Color(.tertiarySystemFill))
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .task(id: "\(run.id)-\(colorScheme)-\(Int(geo.size.width))-\(attempt)") {
                let dark = colorScheme == .dark
                let snapshot = await RouteSnapshots.image(for: run, size: geo.size, dark: dark)
                guard !Task.isCancelled else { return }
                guard let snapshot else {
                    guard run.route.count > 1, geo.size.width > 0, geo.size.height > 0 else { return }
                    let delay: Duration
                    switch min(attempt, 3) {
                    case 1: delay = .seconds(2)
                    case 2: delay = .seconds(5)
                    case 3: delay = .seconds(15)
                    default: delay = .seconds(30)
                    }
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                    attempt += 1
                    return
                }
                withAnimation(.easeOut(duration: 0.25)) { image = snapshot }
            }
        }
        .frame(height: height)
        .clipped()
        .accessibilityHidden(true)
        .onAppear {
            if image == nil { attempt += 1 }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { attempt += 1 }
        }
    }
}

@MainActor
enum RouteSnapshots {
    private static let cache = NSCache<NSString, UIImage>()
    /// Cards all fire snapshots when the tab first appears; MapKit fails
    /// bursts, so cap in-flight starts.
    private static var inFlight = 0
    private static var waiters: [CheckedContinuation<Void, Never>] = []

    static func image(for run: Run, size: CGSize, dark: Bool) async -> UIImage? {
        guard run.route.count > 1, size.width > 0, size.height > 0 else { return nil }
        let scale = UITraitCollection.current.displayScale
        let key = "\(run.id)-\(Int(size.width))x\(Int(size.height))@\(Int(scale))-\(dark)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let file = directory?.appending(path: "\(key).png")
        if let file, let data = await Task.detached(operation: { try? Data(contentsOf: file) }).value,
           let stored = UIImage(data: data, scale: scale) {
            cache.setObject(stored, forKey: key)
            return stored
        }

        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        let options = MKMapSnapshotter.Options()
        options.mapRect = fitted(run.routeRect(padding: 0.18), to: size)
        options.size = size
        options.traitCollection = traits
        let configuration = MKStandardMapConfiguration(emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = configuration

        guard let snapshot = await startSnapshot(
            options: options, key: key as String
        ) else { return nil }
        let points = run.route.map { snapshot.point(for: $0.coordinate) }
        let accent = UIColor(named: "AccentColor")?.resolvedColor(with: traits) ?? .systemBlue

        let image = UIGraphicsImageRenderer(size: size).image { _ in
            snapshot.image.draw(at: .zero)
            let path = UIBezierPath()
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.lineWidth = 6
            UIColor.white.withAlphaComponent(dark ? 0.25 : 0.85).setStroke()
            path.stroke()
            path.lineWidth = 3.5
            accent.setStroke()
            path.stroke()
            drawDot(at: points[0], fill: .white, ring: accent)
            drawDot(at: points[points.count - 1], fill: accent, ring: .white)
        }
        cache.setObject(image, forKey: key)
        if let file {
            Task.detached(priority: .utility) { try? image.pngData()?.write(to: file, options: .atomic) }
        }
        return image
    }

    /// On-disk copy of the snapshots so cards render instantly on later launches.
    private static let directory: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let url = caches.appending(path: "RouteSnapshots", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Two concurrent snapshotter starts; retries on failure with backoff.
    /// Cancellation propagates; only successes are cached by the caller.
    private static func startSnapshot(
        options: MKMapSnapshotter.Options, key: String
    ) async -> MKMapSnapshotter.Snapshot? {
        if inFlight >= 2 {
            await withCheckedContinuation { waiters.append($0) }
        }
        inFlight += 1
        defer {
            inFlight -= 1
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        for (attempt, backoff) in [0.4, 0.8, 1.6].enumerated() {
            if Task.isCancelled { return nil }
            do {
                return try await MKMapSnapshotter(options: options).start()
            } catch {
                NSLog("RouteSnapshots: %@ failed (attempt %d): %@",
                      key, attempt + 1, error.localizedDescription)
                if attempt < 2 {
                    try? await Task.sleep(for: .seconds(backoff))
                }
            }
        }
        return nil
    }

    /// Expands the shorter side so the route is centred in an image of `size`.
    private static func fitted(_ rect: MKMapRect, to size: CGSize) -> MKMapRect {
        let target = size.width / size.height
        var width = rect.width, height = rect.height
        if width / height < target { width = height * target } else { height = width / target }
        return MKMapRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    private static func drawDot(at point: CGPoint, fill: UIColor, ring: UIColor) {
        let dot = UIBezierPath(ovalIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
        fill.setFill()
        dot.fill()
        dot.lineWidth = 2.5
        ring.setStroke()
        dot.stroke()
    }
}

/// Strava-style run card: title, date, key stats, then the route.
struct RunCard: View {
    let run: Run

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Jogga.cardRadius, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(Fmt.runTitle(run.startedAt))
                            .font(Jogga.rounded(.headline, weight: .bold))
                        if run.source == StravaImporter.source { StravaBadge() }
                    }
                    Text(run.startedAt.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let key = run.primaryDistance { Chip(text: Fmt.distanceName(key)) }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)

            HStack(alignment: .top) {
                StatCell(label: "Distance", value: Fmt.km(run.distanceM), unit: "km", size: 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                StatCell(label: "Pace", value: Fmt.pace(run.averagePace), unit: "/km", size: 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                StatCell(label: "Time", value: RunMath.formatTime(run.movingS), size: 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, run.route.count > 1 ? 14 : 18)

            if run.route.count > 1 {
                RouteThumbnail(run: run, height: 150)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: shape)
        .clipShape(shape)
        .contentShape(shape)
    }
}

/// Full-screen interactive route map, coloured by pace.
struct RouteMapView: View {
    let run: Run
    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition
    private let segments: [RoutePace.Segment]

    init(run: Run) {
        self.run = run
        segments = RoutePace.segments(run.route)
        _position = State(initialValue: .rect(run.routeRect(padding: 0.3)))
    }

    var body: some View {
        Map(position: $position) {
            PaceRoute(run: run, segments: segments, lineWidth: 6)
        }
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
        .mapControls {
            MapCompass()
            MapPitchToggle()
            MapScaleView()
        }
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
                    .background(.regularMaterial, in: Circle())
            }
            .tint(.primary)
            .padding(.leading, 16)
            .accessibilityLabel("Close map")
        }
        .overlay(alignment: .bottom) { panel }
        .persistentSystemOverlays(.hidden)
        .trackScreen(.routeMap)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                StatCell(label: "Distance", value: Fmt.km(run.distanceM), unit: "km", size: 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                StatCell(label: "Pace", value: Fmt.pace(run.averagePace), unit: "/km", size: 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                StatCell(label: "Climb", value: "\(Int(run.gainM.rounded()))", unit: "m", size: 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                Text("Slower").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Capsule().fill(PaceColor.gradient).frame(height: 6)
                Text("Faster").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Route coloured by pace, light blue slower, dark blue faster")
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Jogga.cardRadius, style: .continuous))
        .padding(.horizontal, Jogga.pagePadding)
        .padding(.bottom, 8)
    }
}
