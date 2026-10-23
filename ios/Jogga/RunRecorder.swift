import CoreLocation
import Foundation
import SwiftUI

/// Records a run from CLLocationManager. States: idle / countdown / running /
/// paused / finished. Distance, moving time, elevation and splits accumulate
/// incrementally per accepted sample — no full-history recomputation.
@Observable
final class RunRecorder: NSObject, CLLocationManagerDelegate {
    enum State {
        case idle, countdown, running, paused, finished
    }

    private(set) var state: State = .idle
    private(set) var countdown = 3
    private(set) var elapsed: TimeInterval = 0
    private(set) var movingS: TimeInterval = 0
    private(set) var distanceM: Double = 0
    private(set) var pace: Double = 0 // rolling last 30 s, s/km
    private(set) var gainM: Double = 0
    private(set) var lossM: Double = 0
    private(set) var route: [Run.RoutePoint] = []
    private(set) var splits: [Run.Split] = []
    /// Live metrics for the audio coach; re-created on every start/reset.
    private(set) var cueTrack = CueTrack()
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    var tick: Int = 0 // incremented each 0.1 s to drive the UI clock

    var kmTick: Int = 0 // incremented at each completed km -> haptic trigger

    private var samples: [RunMath.Sample] = [] // kept for finish()/tests
    private var previousRaw: RunMath.Sample?
    private var previousAccepted: RunMath.Sample?
    private var elevationAcc = RunMath.ElevationAccumulator()
    private var splitAcc = RunMath.SplitAccumulator()
    private var recentWindow: [RunMath.Sample] = [] // last ~30 s for rolling pace

    private var manager: CLLocationManager?
    private var timer: Timer?
    private var countdownTimer: Timer?
    private var countdownEnds: Date?
    private var locationUpdatesRunning = false
    private var startDate: Date = .now
    private var pausedAt: Date?
    private let liveActivity = RunLiveActivity()
    private var liveActivityTitle = "Run"
    #if DEBUG
    private var simulated: SimulatedLocationSource?
    #endif

    // MARK: Control

    func requestAuthorization() {
        ensureManager().requestWhenInUseAuthorization()
    }

    func beginCountdown(title: String = "Run") {
        guard state == .idle else { return }
        liveActivityTitle = title
        state = .countdown
        countdown = 3
        countdownEnds = Date.now.addingTimeInterval(3)
        // Background location keeps the app alive through a lock during the
        // countdown and warms GPS; samples are dropped until state == .running.
        startLocationUpdates()
        // Deadline-based so a suspended app still starts on the next tick.
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let ends = self.countdownEnds else { return }
            let remaining = ends.timeIntervalSinceNow
            self.countdown = max(0, Int(ceil(remaining)))
            if remaining <= 0 {
                self.countdownTimer?.invalidate()
                self.start()
            }
        }
    }

    private func start() {
        startDate = .now
        elapsed = 0
        movingS = 0
        distanceM = 0
        pace = 0
        gainM = 0
        lossM = 0
        route = []
        splits = []
        samples = []
        previousRaw = nil
        previousAccepted = nil
        elevationAcc = RunMath.ElevationAccumulator()
        splitAcc = RunMath.SplitAccumulator()
        recentWindow = []
        cueTrack = CueTrack()
        state = .running
        liveActivity.start(title: liveActivityTitle, state: liveActivityState)
        #if DEBUG
        simulated?.reset() // countdown samples were dropped; restart t at 0
        #endif
        startLocationUpdates()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.state == .running else { return }
            self.elapsed = Date.now.timeIntervalSince(self.startDate)
            self.tick += 1
        }
    }

    func pause() {
        guard state == .running else { return }
        state = .paused
        let now = Date.now
        pausedAt = now
        elapsed = now.timeIntervalSince(startDate)
        liveActivity.update(liveActivityState, force: true)
        stopLocationUpdates()
    }

    func resume() {
        guard state == .paused, let pausedAt else { return }
        // Shift the start date so paused time is excluded from elapsed, and
        // drop the previous sample so the first leg after resume adds nothing.
        startDate = startDate.addingTimeInterval(Date.now.timeIntervalSince(pausedAt))
        self.pausedAt = nil
        previousRaw = nil
        previousAccepted = nil
        recentWindow = []
        cueTrack.breakLeg()
        state = .running
        liveActivity.update(liveActivityState, force: true)
        startLocationUpdates()
    }

    /// finish() computes the authoritative figures in batch from the accepted
    /// samples; the incremental live values are checked against them in tests.
    func finish() -> Run {
        state = .finished
        liveActivity.end()
        stopLocationUpdates()
        timer?.invalidate()
        let (gain, loss) = RunMath.elevation(samples)
        return Run(
            id: UUID(),
            startedAt: startDate,
            distanceM: RunMath.distance(samples),
            movingS: RunMath.movingTime(samples),
            elapsedS: elapsed,
            gainM: gain,
            lossM: loss,
            splits: RunMath.splits(samples).map {
                Run.Split(distanceM: $0.distanceM, movingS: $0.movingS, gainM: $0.gainM, lossM: $0.lossM)
            },
            efforts: RunMath.efforts(samples),
            route: route
        )
    }

    func reset() {
        state = .idle
        liveActivity.end()
        stopLocationUpdates()
        #if DEBUG
        simulated = nil
        #endif
        timer?.invalidate()
        countdownTimer?.invalidate()
        countdownEnds = nil
        countdown = 3
        samples = []
        route = []
        splits = []
        elapsed = 0
        movingS = 0
        distanceM = 0
        pace = 0
        gainM = 0
        lossM = 0
        kmTick = 0
        pausedAt = nil
        elevationAcc = RunMath.ElevationAccumulator()
        splitAcc = RunMath.SplitAccumulator()
        recentWindow = []
        previousRaw = nil
        previousAccepted = nil
        cueTrack = CueTrack()
    }

    // MARK: Location

    private func ensureManager() -> CLLocationManager {
        if let manager { return manager }
        let m = CLLocationManager()
        m.delegate = self
        m.activityType = .fitness
        m.desiredAccuracy = kCLLocationAccuracyBest
        m.distanceFilter = 3
        if #available(iOS 17, *) {
            m.allowsBackgroundLocationUpdates = true
            m.showsBackgroundLocationIndicator = true
        }
        m.pausesLocationUpdatesAutomatically = false
        manager = m
        return m
    }

    private func startLocationUpdates() {
        guard !locationUpdatesRunning else { return }
        locationUpdatesRunning = true
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-demoRun") {
            if simulated == nil {
                let sim = SimulatedLocationSource { [weak self] sample in
                    self?.ingest(sample)
                }
                simulated = sim
            }
            simulated?.start()
            return
        }
        #endif
        ensureManager().startUpdatingLocation()
    }

    private func stopLocationUpdates() {
        locationUpdatesRunning = false
        manager?.stopUpdatingLocation()
        #if DEBUG
        simulated?.stop()
        #endif
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations {
            ingest(RunMath.Sample(
                t: location.timestamp.timeIntervalSince(startDate),
                coordinate: location.coordinate,
                horizontalAccuracy: location.horizontalAccuracy,
                altitude: location.altitude,
                verticalAccuracy: location.verticalAccuracy
            ))
        }
    }

    /// Feed one raw sample. Staleness is judged at receipt (Date.now), not
    /// against the newest sample — history is never re-filtered.
    func ingest(_ sample: RunMath.Sample) {
        guard state == .running, sample.t >= 0 else { return }
        let receivedAt = Date.now.timeIntervalSince(startDate)
        defer { previousRaw = sample }
        guard RunMath.accept(sample, previousRaw: previousRaw, receivedAt: receivedAt) else {
            return
        }

        var legDistance = 0.0
        var legTime = 0.0
        if let previousAccepted {
            legDistance = RunMath.haversine(previousAccepted.coordinate, sample.coordinate)
            legTime = max(min(sample.t - previousAccepted.t, 10), 0) // paused gaps don't count
        }
        let previousKm = Int(distanceM / 1000)
        distanceM += legDistance
        movingS += legTime
        self.previousAccepted = sample
        samples.append(sample)
        elevationAcc.ingest(sample)
        gainM = elevationAcc.gain
        lossM = elevationAcc.loss
        splitAcc.ingest(sample, legDistance: legDistance, legTime: legTime)
        if Int(distanceM / 1000) > previousKm {
            kmTick += 1
            splits = splitAcc.splits.map {
                Run.Split(distanceM: $0.distanceM, movingS: $0.movingS, gainM: $0.gainM, lossM: $0.lossM)
            }
        }
        route.append(Run.RoutePoint(
            lat: sample.coordinate.latitude,
            lon: sample.coordinate.longitude,
            t: sample.t
        ))
        updateRollingPace(sample)
        cueTrack.ingest(sample)
        liveActivity.update(liveActivityState)
    }

    private var liveActivityState: RunActivityAttributes.ContentState {
        RunActivityAttributes.ContentState(
            timerStart: startDate,
            pausedElapsed: state == .paused ? elapsed : nil,
            distanceM: distanceM,
            paceSPerKm: pace,
            splitKm: splits.count + 1,
            splitPaceSPerKm: RunLiveActivity.splitPace(
                currentDistance: splitAcc.currentDistance,
                currentTime: splitAcc.currentTime,
                lastSplit: splits.last
            )
        )
    }

    /// Rolling pace over the last 30 s of movement.
    private func updateRollingPace(_ latest: RunMath.Sample) {
        recentWindow.append(latest)
        recentWindow.removeAll { latest.t - $0.t > 30 }
        let d = RunMath.distance(recentWindow)
        let t = RunMath.movingTime(recentWindow)
        pace = d > 5 && t > 2 ? t / (d / 1000) : 0
    }

    // MARK: Test hooks (DEBUG only)

    #if DEBUG
    /// Running state without CLLocationManager or timers, for unit tests
    /// driving `ingest` directly.
    func beginForTesting() {
        startDate = .now
        elapsed = 0
        movingS = 0
        distanceM = 0
        pace = 0
        gainM = 0
        lossM = 0
        route = []
        splits = []
        samples = []
        previousRaw = nil
        previousAccepted = nil
        elevationAcc = RunMath.ElevationAccumulator()
        splitAcc = RunMath.SplitAccumulator()
        recentWindow = []
        cueTrack = CueTrack()
        state = .running
    }
    #endif
}

#if DEBUG
/// Feeds a synthetic ~5:20/km loop around a fixed centre for -demoRun.
final class SimulatedLocationSource {
    private var timer: Timer?
    private let onSample: (RunMath.Sample) -> Void
    private var step = 0

    init(onSample: @escaping (RunMath.Sample) -> Void) {
        self.onSample = onSample
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.emit()
        }
    }

    func stop() {
        timer?.invalidate()
    }

    /// Restart sample times from zero (the real run's t origin is start()).
    func reset() {
        step = 0
    }

    private func emit() {
        step += 1
        let t = Double(step) * 0.5
        // ~3.2 m/s (5:12/km) on a 400 m loop around San Francisco.
        let angle = t * 3.2 / (400 / (2 * .pi))
        let radius = 63.66 // metres
        let dLat = radius * cos(angle) / 111_320
        let dLon = radius * sin(angle) / (111_320 * cos(37.78 * .pi / 180))
        onSample(RunMath.Sample(
            t: t,
            coordinate: CLLocationCoordinate2D(
                latitude: 37.78 + dLat,
                longitude: -122.42 + dLon
            ),
            horizontalAccuracy: 5,
            altitude: 12 + sin(angle) * 2,
            verticalAccuracy: 4
        ))
    }
}
#endif
