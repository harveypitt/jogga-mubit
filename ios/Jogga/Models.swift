import CoreLocation
import Foundation

/// A finished run, stored locally and posted to the server.
struct Run: Codable, Identifiable, Hashable {
    var id: UUID
    var startedAt: Date
    var distanceM: Double
    var movingS: Double
    var elapsedS: Double
    var gainM: Double
    var lossM: Double
    var splits: [Split]
    var efforts: [String: Double]
    /// Route stays on device only.
    var route: [RoutePoint]
    /// nil for runs recorded in Jogga; "strava" for imported history.
    var source: String?
    /// Activity id in `source`.
    var externalID: String?
    var mode: String? = nil

    var isImported: Bool { source != nil }

    struct Split: Codable, Hashable {
        var distanceM: Double
        var movingS: Double
        var gainM: Double
        var lossM: Double

        enum CodingKeys: String, CodingKey {
            case distanceM = "distance_m"
            case movingS = "moving_s"
            case gainM = "gain_m"
            case lossM = "loss_m"
        }
    }

    struct RoutePoint: Codable, Hashable {
        var lat: Double
        var lon: Double
        var t: TimeInterval
        /// Metres; only imported routes carry altitude.
        var alt: Double?

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at"
        case distanceM = "distance_m"
        case movingS = "moving_s"
        case elapsedS = "elapsed_s"
        case gainM = "gain_m"
        case lossM = "loss_m"
        case splits, efforts, route, source
        case externalID = "external_id"
        case mode
    }

    var primaryDistance: String? { RunMath.primaryDistance(distanceM) }
    var averagePace: Double { distanceM > 0 ? movingS / (distanceM / 1000) : 0 }

    /// Body sent to POST /runs and /runs/import (route excluded — routes stay on device).
    var uploadBody: [String: Any] {
        var body: [String: Any] = [
            "id": id.uuidString,
            "started_at": ISO8601DateFormatter().string(from: startedAt),
            "distance_m": distanceM,
            "moving_s": movingS,
            "elapsed_s": elapsedS,
            "gain_m": gainM,
            "loss_m": lossM,
            "splits": splits.map {
                [
                    "distance_m": $0.distanceM,
                    "moving_s": $0.movingS,
                    "gain_m": $0.gainM,
                    "loss_m": $0.lossM,
                ]
            },
            "efforts": efforts,
        ]
        if let externalID { body["external_id"] = externalID }
        if let mode { body["mode"] = mode }
        body["tz"] = TimeZone.current.identifier
        return body
    }
}

/// A coach note returned by the server.
struct CoachNote: Codable, Hashable {
    var source: String
    var model: String?
    var payload: Payload
    var createdAt: Date

    struct Payload: Codable, Hashable {
        var feedback: String
        var pacing: String
        var next: Next
        var frequency: Frequency
        /// Structured feedback fields; older notes only have `feedback`.
        var wentWell: String?
        var workOn: String?
        var result: String?

        enum CodingKeys: String, CodingKey {
            case feedback, pacing, next, frequency
            case wentWell = "went_well"
            case workOn = "work_on"
            case result
        }

        struct Next: Codable, Hashable {
            var km: Double
            var pace: Int
            var kind: String
            var detail: String
            var why: String
        }

        struct Frequency: Codable, Hashable {
            var runsPerWeek: Int
            var note: String

            enum CodingKeys: String, CodingKey {
                case runsPerWeek = "runs_per_week"
                case note
            }
        }

        /// Human-friendly pacing label — server codes aren't user-facing.
        var pacingLabel: String {
            switch pacing {
            case "positive": return "Faded"
            case "negative": return "Finished faster"
            case "even": return "Even pacing"
            case "erratic": return "Uneven pacing"
            default: return "\(pacing.capitalized) pacing"
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case source, model, payload
        case createdAt = "created_at"
    }
}

/// GET /me response, shared by AuthStore and RunStore.
struct MeResponse: Decodable {
    var user: UserBody
    var targets: [String: Int]
    var stats: [String: DistanceStats]

    struct UserBody: Decodable {
        var id: UUID
        var display_name: String?
    }
}

/// Per-distance stats from GET /me.
struct DistanceStats: Codable, Hashable {
    var bestS: Double?
    var lastS: Double?
    var count: Int
    var count4w: Int

    enum CodingKeys: String, CodingKey {
        case bestS = "best_s"
        case lastS = "last_s"
        case count
        case count4w = "count_4w"
    }
}
