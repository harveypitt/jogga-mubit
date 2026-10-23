import XCTest
@testable import Jogga

final class AnalyticsTests: XCTestCase {
    func testDistanceBands() {
        let cases: [(Double, String)] = [
            (0, "<1k"),
            (999.99, "<1k"),
            (1_000, "1-3k"),
            (3_000, "3-5k"),
            (4_990, "3-5k"),
            (5_000, "5-8k"),
            (8_000, "8-10k"),
            (10_000, "10-15k"),
            (15_000, "15-21k"),
            (21_097.5, "21-30k"),
            (30_000, "30-42k"),
            (41_999.99, "30-42k"),
            (42_000, "42k+"),
            (42_195, "42k+"),
        ]
        for (metres, expected) in cases {
            XCTAssertEqual(Analytics.distanceBand(metres: metres), expected)
        }
    }

    func testDurationBands() {
        let cases: [(Double, String)] = [
            (0, "0-5m"),
            (5 * 60, "5-10m"),
            (10 * 60, "10-15m"),
            (15 * 60, "15-20m"),
            (20 * 60, "20-25m"),
            (25 * 60, "25-30m"),
            (30 * 60, "30-35m"),
            (35 * 60, "35-40m"),
            (40 * 60, "40-45m"),
            (45 * 60, "45-50m"),
            (50 * 60, "50-55m"),
            (55 * 60, "55-60m"),
            (60 * 60, "60-75m"),
            (75 * 60, "75-90m"),
            (90 * 60, "90-105m"),
            (105 * 60, "105-120m"),
            (120 * 60, "120-135m"),
            (135 * 60, "135-150m"),
            (150 * 60, "150-165m"),
            (165 * 60, "165-180m"),
            (180 * 60, "180m+"),
        ]
        for (seconds, expected) in cases {
            XCTAssertEqual(Analytics.durationBand(seconds: seconds), expected)
        }
    }

    func testStandardDistanceEdges() {
        XCTAssertNil(Analytics.standardDistance(metres: 4_999.99))
        XCTAssertEqual(Analytics.standardDistance(metres: 5_000), "5k")
        XCTAssertEqual(Analytics.standardDistance(metres: 10_000), "10k")
        XCTAssertEqual(Analytics.standardDistance(metres: 21_097.5), "half")
        XCTAssertEqual(Analytics.standardDistance(metres: 42_195), "marathon")
    }
}
