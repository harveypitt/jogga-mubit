import Foundation

/// One run's worth of cue events — what the coach wanted to say and what
/// happened to each cue (spoken, suppressed, expired, replaced).
struct CueLog: Codable, Equatable {
    var runID: UUID? = nil
    var context: RunContext
    var entries: [Entry] = []

    struct Entry: Codable, Equatable {
        var clock: Double
        var distanceM: Double
        var kind: String
        var text: String
        var outcome: String // spoken | suppressed | expired | replaced | failed
        var reason: String? = nil
        // Synthesis metrics for spoken cues (nil on old logs / system voice).
        var voice: String? = nil
        var firstAudioMs: Int? = nil
        var synthS: Double? = nil
        var audioS: Double? = nil
        var prefillS: Double? = nil
        var genTokens: Int? = nil
        var genS: Double? = nil
        var decodeS: Double? = nil

        /// "Sophie · ready in 4.2 s" — shown small under spoken rows.
        var voiceMeta: String? {
            guard let voice else { return nil }
            if let synthS {
                return String(format: "%@ · ready in %.1f s", voice, synthS)
            }
            return voice
        }
    }
}

/// Per-run cue log persistence in Application Support/Jogga/cuelogs.
enum CueLogStore {
    private static var directory: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Jogga/cuelogs", isDirectory: true)
    }

    private static func url(runID: UUID) -> URL {
        directory.appendingPathComponent("\(runID.uuidString).json")
    }

    static func save(_ log: CueLog) {
        guard let id = log.runID else { return }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(log) {
            try? data.write(to: url(runID: id), options: .atomic)
        }
    }

    static func load(runID: UUID) -> CueLog? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url(runID: runID)) else { return nil }
        return try? decoder.decode(CueLog.self, from: data)
    }

    static func delete(runID: UUID) {
        try? FileManager.default.removeItem(at: url(runID: runID))
    }
}
