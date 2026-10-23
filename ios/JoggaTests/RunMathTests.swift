import CoreLocation
import XCTest
@testable import Jogga

final class RunMathTests: XCTestCase {
    private func sample(
        t: TimeInterval, lat: Double, lon: Double,
        hAcc: Double = 5, alt: Double = 10, vAcc: Double = 4
    ) -> RunMath.Sample {
        RunMath.Sample(
            t: t,
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            horizontalAccuracy: hAcc,
            altitude: alt,
            verticalAccuracy: vAcc
        )
    }

    /// ~1.11 m per 1e-5 degrees latitude.
    private func lineSamples(
        count: Int, stepT: TimeInterval = 2, metresPerStep: Double = 11.13,
        alt: (Int) -> Double = { _ in 10 }
    ) -> [RunMath.Sample] {
        (0..<count).map {
            sample(t: Double($0) * stepT, lat: 37 + Double($0) * metresPerStep / 111_320,
                   lon: -122, alt: alt($0))
        }
    }

    // MARK: Filtering

    func testFilterDropsBadAccuracy() {
        let samples = [
            sample(t: 0, lat: 37, lon: -122),
            sample(t: 2, lat: 37.0001, lon: -122, hAcc: 50),
            sample(t: 4, lat: 37.0002, lon: -122),
        ]
        XCTAssertEqual(RunMath.filter(samples, now: 4).count, 2)
    }

    func testFilterDropsOldSamples() {
        let samples = [sample(t: 0, lat: 37, lon: -122)]
        XCTAssertTrue(RunMath.filter(samples, now: 20).isEmpty)
    }

    func testFilterDropsTeleport() {
        let samples = [
            sample(t: 0, lat: 37, lon: -122),
            sample(t: 1, lat: 37.5, lon: -122), // ~55 km in 1 s
            sample(t: 3, lat: 37.5001, lon: -122),
        ]
        let kept = RunMath.filter(samples, now: 3)
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(kept.last?.coordinate.latitude, 37.5001)
    }

    // MARK: Splits

    func testSplitsFullKmPlusPartial() {
        // 2500 m at 5 m/s -> 2 full km + 0.5 km partial in 500 s.
        let samples = lineSamples(count: 226, stepT: 2, metresPerStep: 11.13)
        let splits = RunMath.splits(samples)
        XCTAssertEqual(splits.count, 3)
        XCTAssertEqual(splits[0].distanceM, 1000, accuracy: 1)
        XCTAssertEqual(splits[2].distanceM, 500, accuracy: 2)
        XCTAssertEqual(splits[0].movingS, 1000 / (11.13 / 2), accuracy: 8)
    }

    func testSplitsDropsTinyPartial() {
        // 1030 m -> 1 km split only.
        let samples = lineSamples(count: 94, stepT: 2, metresPerStep: 11.13)
        let splits = RunMath.splits(samples)
        XCTAssertEqual(splits.count, 1)
    }

    // MARK: Elevation

    func testElevationHysteresis() {
        // Altitude wanders ±2 m -> no gain; then steps up to 14 -> counts once.
        var samples = lineSamples(count: 20)
        for i in samples.indices {
            samples[i].altitude = i < 10 ? 10 + Double(i % 3) : 14
        }
        let (gain, loss) = RunMath.elevation(samples)
        XCTAssertEqual(gain, 4, accuracy: 0.01)
        XCTAssertEqual(loss, 0)
    }

    func testElevationIgnoresBadVerticalAccuracy() {
        var samples = lineSamples(count: 10)
        for i in samples.indices {
            samples[i].altitude = Double(i) * 10
            samples[i].verticalAccuracy = 50
        }
        let (gain, _) = RunMath.elevation(samples)
        XCTAssertEqual(gain, 0)
    }

    // MARK: Efforts

    func testEffortsInterpolation() {
        // 6000 m at ~5.57 m/s: 5K crosses at ~899 s.
        let samples = lineSamples(count: 541, stepT: 2, metresPerStep: 11.13)
        let efforts = RunMath.efforts(samples)
        XCTAssertNotNil(efforts["5k"])
        XCTAssertEqual(efforts["5k"]!, 899.5, accuracy: 15)
        XCTAssertNil(efforts["10k"])
    }

    func testPrimaryDistance() {
        XCTAssertEqual(RunMath.primaryDistance(5000), "5k")
        XCTAssertEqual(RunMath.primaryDistance(11_000), "10k")
        XCTAssertEqual(RunMath.primaryDistance(22_000), "half")
        XCTAssertEqual(RunMath.primaryDistance(43_000), "marathon")
        XCTAssertNil(RunMath.primaryDistance(3000))
    }

    // MARK: Riegel & required pace

    func testRiegel() {
        let result = RunMath.riegel(target: "10k", efforts: ["5k": 1500])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.from, "5k")
        // 1500 * 2^1.06 ≈ 3127
        XCTAssertEqual(result!.seconds, 3127, accuracy: 10)
    }

    func testRiegelPicksNearestDistance() {
        let result = RunMath.riegel(target: "5k", efforts: ["marathon": 14_400, "10k": 3200])
        XCTAssertEqual(result?.from, "10k")
    }

    func testRequiredPace() {
        // 25:00 for 5K -> 300 s/km.
        XCTAssertEqual(RunMath.requiredPace(distanceKey: "5k", targetS: 1500), 300, accuracy: 0.01)
    }

    // MARK: Formatters

    func testFormatTime() {
        XCTAssertEqual(RunMath.formatTime(1600), "26:40")
        XCTAssertEqual(RunMath.formatTime(6727), "1:52:07")
    }

    func testFormatPace() {
        XCTAssertEqual(RunMath.formatPace(319), "5:19 /km")
    }

    func testFormatDistance() {
        XCTAssertEqual(RunMath.formatDistance(5020), "5.02 km")
    }

    // MARK: Incremental accept + accumulators

    func testLongRunAllSamplesAccepted() {
        // Regression: history must not be re-filtered against newest sample.
        // 20 min of 1 Hz samples at 5 m/s -> all accepted, ~6000 m.
        let samples = lineSamples(count: 1200, stepT: 1, metresPerStep: 5.56)
        var accepted = 0
        var previous: RunMath.Sample?
        for s in samples {
            if RunMath.accept(s, previousRaw: previous, receivedAt: s.t) {
                accepted += 1
            }
            previous = s
        }
        XCTAssertEqual(accepted, 1200)
        XCTAssertEqual(RunMath.distance(samples), 6650, accuracy: 30)
    }

    func testIncrementalMatchesBatch() {
        // A synthetic 2.5 km run with a hill: incremental accumulators must
        // agree with the batch functions used by finish().
        var samples = lineSamples(count: 226, stepT: 2, metresPerStep: 11.13)
        for i in 30..<120 { samples[i].altitude = 10 + Double(i - 30) * 0.2 } // ~18 m hill
        let recorder = RunRecorder()
        recorder.beginForTesting()
        for s in samples { recorder.ingest(s) }
        XCTAssertEqual(recorder.distanceM, RunMath.distance(samples), accuracy: 0.01)
        XCTAssertEqual(recorder.movingS, RunMath.movingTime(samples), accuracy: 0.01)
        let (batchGain, batchLoss) = RunMath.elevation(samples)
        XCTAssertEqual(recorder.gainM, batchGain, accuracy: 0.01)
        XCTAssertEqual(recorder.lossM, batchLoss, accuracy: 0.01)
    }

    func testPauseResumeAddsNoDistance() {
        let recorder = RunRecorder()
        recorder.beginForTesting()
        for s in lineSamples(count: 10, stepT: 1, metresPerStep: 5) {
            recorder.ingest(s)
        }
        let before = recorder.distanceM
        recorder.pause()
        recorder.resume()
        // First sample after resume: a different spot, must not add a leg.
        recorder.ingest(sample(t: 100, lat: 37.1, lon: -122))
        XCTAssertEqual(recorder.distanceM, before, accuracy: 0.001)
    }

    func testMovingTimeExcludesGaps() {
        // 10 samples 2 s apart, then a 60 s gap (pause), then 10 more.
        var samples = lineSamples(count: 10)
        samples += (10..<20).map {
            sample(t: 18 + 60 + Double($0 - 10) * 2,
                   lat: 37 + Double($0) * 11.13 / 111_320, lon: -122)
        }
        XCTAssertEqual(RunMath.movingTime(samples), 36, accuracy: 0.001)
    }
}
