import XCTest
@testable import Jogga

final class StravaImportTests: XCTestCase {
    private var fixture: URL {
        Bundle(for: Self.self).url(forResource: "strava_fixture", withExtension: "zip")!
    }

    func testZipReadsDeflatedAndStoredEntries() throws {
        let zip = try ZipReader(url: fixture)
        XCTAssertEqual(Set(zip.paths), [
            "activities.csv", "activities/101.gpx", "activities/102.gpx", "activities/105.gpx.gz",
        ])
        let csv = try XCTUnwrap(zip.read("activities.csv"))
        XCTAssertTrue(String(decoding: csv, as: UTF8.self).hasPrefix("Activity ID,Activity Date"))
        let gz = try XCTUnwrap(zip.read("activities/105.gpx.gz"))
        let gpx = try XCTUnwrap(StravaImporter.gunzip(gz))
        XCTAssertTrue(String(decoding: gpx, as: UTF8.self).contains("<trkpt"))
        XCTAssertNil(try zip.read("missing.csv"))
    }

    func testNotAZip() {
        XCTAssertThrowsError(try ZipReader(data: Data("hello".utf8)))
    }

    func testImportsOnlyRuns() throws {
        let result = try StravaImporter.load(ZipReader(url: fixture))
        XCTAssertEqual(result.runs.map(\.externalID), ["101", "103", "105"])
        XCTAssertEqual(result.otherActivities, 2) // the ride and the walk
        XCTAssertEqual(result.withRoute, 2)
        XCTAssertEqual(result.unreadable, 0)
        XCTAssertTrue(result.runs.allSatisfy { $0.source == "strava" })
    }

    func testRouteRunUsesRecordedMaths() throws {
        let result = try StravaImporter.load(ZipReader(url: fixture))
        let run = try XCTUnwrap(result.runs.first { $0.externalID == "101" })
        XCTAssertEqual(run.startedAt, ISO8601DateFormatter().date(from: "2024-01-07T14:39:53Z"))
        XCTAssertEqual(run.route.count, 400)
        XCTAssertEqual(run.distanceM, 1197, accuracy: 3)
        XCTAssertEqual(run.movingS, 399, accuracy: 0.1)
        XCTAssertEqual(run.elapsedS, 420)
        XCTAssertEqual(run.splits.count, 2)
        XCTAssertEqual(run.gainM, 9, accuracy: 1.5)
        XCTAssertNotNil(run.route.first?.alt)
        let samples = CueSimulator.samples(for: run)
        XCTAssertEqual(samples.last?.altitude ?? 0, run.route.last?.alt ?? -1)
        XCTAssertGreaterThan(samples[0].verticalAccuracy, 0)
    }

    func testManualRunIsSummaryOnly() throws {
        let result = try StravaImporter.load(ZipReader(url: fixture))
        let run = try XCTUnwrap(result.runs.first { $0.externalID == "103" })
        XCTAssertTrue(run.route.isEmpty)
        XCTAssertEqual(run.distanceM, 4000)
        XCTAssertEqual(run.movingS, 1440)
        XCTAssertEqual(run.elapsedS, 1500)
        XCTAssertEqual(run.gainM, 12)
        XCTAssertEqual(run.startedAt, ISO8601DateFormatter().date(from: "2025-05-01T09:37:17Z"))
    }

    func testCSVQuotesAndDuplicateHeaders() {
        let csv = "Activity ID,Activity Date,Activity Type,Activity Description,Distance,Distance\n"
            + "1,\"Oct 1, 2026, 7:46:35 AM\",Run,\"Said \"\"hi\"\",\nthen left\",5.73,5737.1\r\n"
            + "2,\"Oct 2, 2026, 7:46:35\u{202F}AM\",Ride,,10.0,10000.0"
        let rows = StravaImporter.parseCSV(csv)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1][3], "Said \"hi\",\nthen left")
        let activities = StravaImporter.activities(csv: csv)
        XCTAssertEqual(activities.map(\.id), ["1", "2"])
        XCTAssertEqual(activities[0].distanceM, 5737.1)
        XCTAssertEqual(activities[1].type, "Ride")
        XCTAssertFalse(activities[1].isRun)
        XCTAssertNotNil(activities[1].date)
    }

    func testLegacyRunDecodesWithoutSourceOrAltitude() throws {
        let json = """
        {"id":"\(UUID().uuidString)","started_at":"2026-01-01T08:00:00Z","distance_m":5000,
         "moving_s":1500,"elapsed_s":1500,"gain_m":0,"loss_m":0,"splits":[],"efforts":{},
         "route":[{"lat":51.0,"lon":0.0,"t":0}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let run = try decoder.decode(Run.self, from: Data(json.utf8))
        XCTAssertNil(run.source)
        XCTAssertFalse(run.isImported)
        XCTAssertNil(run.route[0].alt)
        XCTAssertNil(run.uploadBody["external_id"])
    }

    func testSameRunTolerance() {
        let a = Run(id: UUID(), startedAt: Date(timeIntervalSince1970: 0), distanceM: 5000,
                    movingS: 1500, elapsedS: 1500, gainM: 0, lossM: 0, splits: [], efforts: [:],
                    route: [])
        var b = a
        b.startedAt = a.startedAt.addingTimeInterval(120)
        b.distanceM = 5200
        XCTAssertTrue(RunStore.sameRun(a, b))
        b.startedAt = a.startedAt.addingTimeInterval(240)
        XCTAssertFalse(RunStore.sameRun(a, b))
    }

    /// Optional: TEST_RUNNER_STRAVA_EXPORT=/path/to/export.zip xcodebuild test …
    func testRealExportIfProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["STRAVA_EXPORT"] else {
            throw XCTSkip("STRAVA_EXPORT not set")
        }
        let result = try StravaImporter.load(ZipReader(url: URL(fileURLWithPath: path)))
        print("strava export: runs=\(result.runs.count) routes=\(result.withRoute)"
            + " other=\(result.otherActivities) unreadable=\(result.unreadable)")
        XCTAssertGreaterThan(result.runs.count, 0)
    }
}
