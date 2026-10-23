import CoreLocation
import Foundation

/// Turns a Strava bulk export (`activities.csv` + `activities/*.gpx`) into
/// Jogga runs, on device. Only running activities are imported; routes keep
/// their altitude so maps, splits and coach replay work as for recorded runs.
enum StravaImporter {
    static let source = "strava"
    /// `Activity Type` values that count as runs. Rides, walks, swims etc. are skipped.
    static let runTypes: Set<String> = ["Run", "Trail Run", "Virtual Run"]

    struct Activity: Equatable {
        var id: String
        var date: Date
        var type: String
        var filename: String
        var elapsedS: Double?
        var movingS: Double?
        var distanceM: Double?
        var gainM: Double?
        var lossM: Double?

        var isRun: Bool { StravaImporter.runTypes.contains(type) }
    }

    struct Result {
        var runs: [Run] = []
        var withRoute = 0
        /// Rides and other non-run activities.
        var otherActivities = 0
        /// Runs with neither a readable route nor summary figures.
        var unreadable = 0
    }

    enum ImportError: LocalizedError {
        case noActivities

        var errorDescription: String? {
            "This doesn't look like a Strava export — activities.csv is missing."
        }
    }

    // MARK: Export

    static func load(
        _ files: ExportFiles, progress: (Double) -> Void = { _ in }
    ) throws -> Result {
        // Re-zipped exports can nest everything under one folder.
        guard let csvPath = files.paths
            .filter({ $0 == "activities.csv" || $0.hasSuffix("/activities.csv") })
            .filter({ !$0.contains("__MACOSX") })
            .min(by: { $0.count < $1.count }),
            let csvData = try files.read(csvPath)
        else { throw ImportError.noActivities }
        let root = String(csvPath.dropLast("activities.csv".count))

        let all = activities(csv: String(decoding: csvData, as: UTF8.self))
        var result = Result()
        result.otherActivities = all.filter { !$0.isRun }.count
        let runs = all.filter(\.isRun)
        for (index, activity) in runs.enumerated() {
            var gpx: Data?
            if activity.filename.hasSuffix(".gpx") {
                gpx = try? files.read(root + activity.filename)
            } else if activity.filename.hasSuffix(".gpx.gz") {
                gpx = (try? files.read(root + activity.filename)).flatMap(gunzip)
            }
            if let run = run(activity, gpx: gpx) {
                result.runs.append(run)
                if !run.route.isEmpty { result.withRoute += 1 }
            } else {
                result.unreadable += 1
            }
            progress(Double(index + 1) / Double(runs.count))
        }
        return result
    }

    // MARK: Runs

    /// A route-backed run when the GPX has timed points, else a summary from the CSV.
    static func run(_ activity: Activity, gpx: Data?) -> Run? {
        if let gpx, let run = routeRun(activity, points: GPXParser.points(gpx)) {
            return run
        }
        guard let distance = activity.distanceM, distance > 0,
              let moving = activity.movingS ?? activity.elapsedS, moving > 0 else { return nil }
        return Run(
            id: UUID(),
            startedAt: activity.date,
            distanceM: distance,
            movingS: moving,
            elapsedS: activity.elapsedS ?? moving,
            gainM: activity.gainM ?? 0,
            lossM: activity.lossM ?? 0,
            splits: [],
            efforts: [:],
            route: [],
            source: source,
            externalID: activity.id
        )
    }

    /// Same filtering and maths as a run recorded in Jogga.
    static func routeRun(_ activity: Activity, points: [GPXParser.Point]) -> Run? {
        guard let start = points.first(where: { $0.time != nil })?.time else { return nil }
        var samples: [RunMath.Sample] = []
        var previous: RunMath.Sample?
        for point in points {
            guard let time = point.time else { continue }
            let sample = RunMath.Sample(
                t: time.timeIntervalSince(start),
                coordinate: CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon),
                horizontalAccuracy: 5,
                altitude: point.ele ?? 0,
                verticalAccuracy: point.ele == nil ? -1 : 5
            )
            guard sample.t >= (samples.last?.t ?? 0) else { continue }
            if RunMath.accept(sample, previousRaw: previous, receivedAt: sample.t) {
                samples.append(sample)
            }
            previous = sample
        }
        guard samples.count > 1 else { return nil }
        let distance = RunMath.distance(samples)
        let moving = RunMath.movingTime(samples)
        guard distance > 0, moving > 0 else { return nil }
        let (gain, loss) = RunMath.elevation(samples)
        return Run(
            id: UUID(),
            startedAt: start,
            distanceM: distance,
            movingS: moving,
            elapsedS: max(activity.elapsedS ?? 0, samples.last!.t),
            gainM: gain,
            lossM: loss,
            splits: RunMath.splits(samples).map {
                Run.Split(distanceM: $0.distanceM, movingS: $0.movingS, gainM: $0.gainM,
                          lossM: $0.lossM)
            },
            efforts: RunMath.efforts(samples),
            route: samples.map {
                Run.RoutePoint(
                    lat: $0.coordinate.latitude, lon: $0.coordinate.longitude, t: $0.t,
                    alt: $0.verticalAccuracy > 0 ? $0.altitude : nil
                )
            },
            source: source,
            externalID: activity.id
        )
    }

    // MARK: activities.csv

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MMM d, yyyy, h:mm:ss a"
        return f
    }()

    /// Strava dates are UTC, e.g. "Oct 1, 2026, 7:46:35 AM".
    static func date(_ string: String) -> Date? {
        let normalized = string
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        return dateFormatter.date(from: normalized)
    }

    /// Columns are looked up by position: the export repeats several headers
    /// (`Distance` is km first, metres second; `Elapsed Time` twice).
    static func activities(csv: String) -> [Activity] {
        let rows = parseCSV(csv)
        guard let header = rows.first else { return [] }
        func columns(_ name: String) -> [Int] {
            header.indices.filter { header[$0].trimmingCharacters(in: .whitespaces) == name }
        }
        guard let idCol = columns("Activity ID").first,
              let dateCol = columns("Activity Date").first,
              let typeCol = columns("Activity Type").first else { return [] }
        let fileCol = columns("Filename").first
        let elapsedCol = columns("Elapsed Time").last
        let movingCol = columns("Moving Time").first
        let distanceCols = columns("Distance")
        let gainCol = columns("Elevation Gain").first
        let lossCol = columns("Elevation Loss").first

        return rows.dropFirst().compactMap { row in
            func field(_ col: Int?) -> String? {
                guard let col, col < row.count else { return nil }
                let value = row[col].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
            func number(_ col: Int?) -> Double? { field(col).flatMap(Double.init) }
            guard let id = field(idCol), let date = field(dateCol).flatMap(date),
                  let type = field(typeCol) else { return nil }
            let distance: Double? = distanceCols.count > 1
                ? number(distanceCols.last)
                : number(distanceCols.first).map { $0 * 1000 }
            return Activity(
                id: id,
                date: date,
                type: type,
                filename: field(fileCol) ?? "",
                elapsedS: number(elapsedCol),
                movingS: number(movingCol),
                distanceM: distance,
                gainM: number(gainCol),
                lossM: number(lossCol)
            )
        }
    }

    /// RFC 4180: quoted fields may contain commas, quotes ("") and newlines.
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = iterator.next()
        while let c = pending {
            pending = iterator.next()
            if quoted {
                if c == "\"" {
                    if pending == "\"" {
                        field.unicodeScalars.append("\"")
                        pending = iterator.next()
                    } else {
                        quoted = false
                    }
                } else {
                    field.unicodeScalars.append(c)
                }
                continue
            }
            switch c {
            case "\"": quoted = true
            case ",":
                row.append(field)
                field = ""
            case "\r": break
            case "\n":
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            case "\u{FEFF}" where rows.isEmpty && row.isEmpty && field.isEmpty: break
            default: field.unicodeScalars.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    // MARK: gzip

    /// Minimal gzip (RFC 1952) member decode for `.gpx.gz` activity files.
    static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var p = 10
        if flags & 0x04 != 0 {
            guard p + 2 <= bytes.count else { return nil }
            p += 2 + (Int(bytes[p]) | Int(bytes[p + 1]) << 8)
        }
        if flags & 0x08 != 0 { while p < bytes.count, bytes[p] != 0 { p += 1 }; p += 1 }
        if flags & 0x10 != 0 { while p < bytes.count, bytes[p] != 0 { p += 1 }; p += 1 }
        if flags & 0x02 != 0 { p += 2 }
        let end = bytes.count - 8
        guard p < end else { return nil }
        let size = Int(bytes[end + 4]) | Int(bytes[end + 5]) << 8
            | Int(bytes[end + 6]) << 16 | Int(bytes[end + 7]) << 24
        return try? ZipReader.inflate(Data(bytes[p..<end]), size: size)
    }
}
