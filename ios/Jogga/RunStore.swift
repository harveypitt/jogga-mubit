import Foundation

private struct MeCache: Codable {
    var targets: [String: Int]
    var stats: [String: DistanceStats]
}

#if DEBUG
private struct SeedRun: Decodable {
    var id: UUID
    var startedAt: Date
    var distanceM: Double
    var movingS: Double
    var elapsedS: Double
    var gainM: Double
    var lossM: Double
    var splits: [Run.Split]
    var efforts: [String: Double]
    var source: String?
    var externalID: String?
    var mode: String?

    enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at"
        case distanceM = "distance_m"
        case movingS = "moving_s"
        case elapsedS = "elapsed_s"
        case gainM = "gain_m"
        case lossM = "loss_m"
        case splits, efforts, source, mode
        case externalID = "external_id"
    }
}
#endif

/// Local JSON persistence in Application Support plus a pending-upload queue
/// retried on launch and foreground.
@Observable
final class RunStore {
    private(set) var runs: [Run] = []
    private(set) var targets: [String: Int] = [:]
    private(set) var stats: [String: DistanceStats] = [:]
    private(set) var hasSyncedMe = false
    private(set) var latestCoach: CoachNote?
    private(set) var pendingUploads: [UUID] = []
    private(set) var pendingDeletes: [UUID] = []

    private let api: APIClient
    private let directory: URL
    private let runsURL: URL
    private let queueURL: URL
    private let deletesURL: URL
    private let coachURL: URL
    private let meURL: URL
    private var uploadInFlight: Task<CoachNote?, Never>?
#if DEBUG
    private var usingSeedRunsFile = false
#endif

    init(api: APIClient) {
        self.api = api
        directory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Jogga", isDirectory: true)
        runsURL = directory.appendingPathComponent("runs.json")
        queueURL = directory.appendingPathComponent("pending.json")
        deletesURL = directory.appendingPathComponent("deletes.json")
        coachURL = directory.appendingPathComponent("latestCoach.json")
        meURL = directory.appendingPathComponent("me.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    // MARK: Persistence

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: runsURL),
           let loaded = try? decoder.decode([Run].self, from: data) {
            runs = loaded.sorted { $0.startedAt > $1.startedAt }
        }
        if let data = try? Data(contentsOf: queueURL),
           let queue = try? JSONDecoder().decode([UUID].self, from: data) {
            pendingUploads = queue
        }
        if let data = try? Data(contentsOf: deletesURL),
           let queue = try? JSONDecoder().decode([UUID].self, from: data) {
            pendingDeletes = queue
        }
        if let data = try? Data(contentsOf: meURL),
           let me = try? decoder.decode(MeCache.self, from: data) {
            targets = me.targets
            stats = me.stats
        }
        if let data = try? Data(contentsOf: coachURL),
           let note = try? decoder.decode(CoachNote.self, from: data) {
            latestCoach = note
        }
    }

    private func saveRuns() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(runs) {
            try? data.write(to: runsURL, options: .atomic)
        }
    }

    private func saveQueue() {
        if let data = try? JSONEncoder().encode(pendingUploads) {
            try? data.write(to: queueURL, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(pendingDeletes) {
            try? data.write(to: deletesURL, options: .atomic)
        }
    }

    private func saveMe() {
        let me = MeCache(targets: targets, stats: stats)
        if let data = try? JSONEncoder().encode(me) {
            try? data.write(to: meURL, options: .atomic)
        }
    }

    private func saveCoach() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let note = latestCoach, let data = try? encoder.encode(note) {
            try? data.write(to: coachURL, options: .atomic)
        }
    }

    // MARK: Runs

    func add(_ run: Run) {
        if let index = runs.firstIndex(where: { $0.id == run.id }) {
            runs[index] = run
        } else {
            runs.insert(run, at: 0)
            runs.sort { $0.startedAt > $1.startedAt }
        }
        saveRuns()
    }

    func delete(_ run: Run) {
        CueLogStore.delete(runID: run.id)
        runs.removeAll { $0.id == run.id }
        pendingUploads.removeAll { $0 == run.id }
        if !pendingDeletes.contains(run.id) {
            pendingDeletes.append(run.id)
        }
        saveRuns()
        saveQueue()
        Task { await syncDeletes() }
    }

    /// Push queued deletes to the server, in queue order; stops on the first
    /// failure (offline) so it stays idempotent across launches.
    func syncDeletes() async {
        guard api.token != nil else { return }
        // Wait for any in-flight upload so a discard can't orphan a run that
        // is mid-POST on the server.
        _ = await uploadInFlight?.value
        var deletedAny = false
        for id in pendingDeletes {
            do {
                try await api.delete("runs/\(id.uuidString.lowercased())")
                pendingDeletes.removeAll { $0 == id }
                deletedAny = true
            } catch {
                break
            }
        }
        saveQueue()
        guard deletedAny else { return }
        if let me: MeResponse = try? await api.get("me") {
            targets = me.targets
            stats = me.stats
            saveMe()
        }
        let note = (try? await api.get("coach/latest")) as CoachNote??
        latestCoach = note ?? nil
        if latestCoach == nil {
            try? FileManager.default.removeItem(at: coachURL)
        } else {
            saveCoach()
        }
    }

    func run(id: UUID) -> Run? {
        runs.first { $0.id == id }
    }

#if DEBUG
    func seedRunsFile(at url: URL) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let seeded = try? decoder.decode([SeedRun].self, from: data)
        else {
            assertionFailure("Could not load run fixture at \(url.path)")
            return
        }
        runs = seeded.map {
            Run(
                id: $0.id, startedAt: $0.startedAt, distanceM: $0.distanceM,
                movingS: $0.movingS, elapsedS: $0.elapsedS, gainM: $0.gainM,
                lossM: $0.lossM, splits: $0.splits, efforts: $0.efforts,
                route: [], source: $0.source, externalID: $0.externalID,
                mode: $0.mode
            )
        }.sorted { $0.startedAt > $1.startedAt }
        usingSeedRunsFile = true
        saveRuns()
    }
#endif

    /// Add a finished run, queue it and try the upload immediately.
    @discardableResult
    func record(_ run: Run) async -> CoachNote? {
        add(run)
        queueUpload(run.id)
        return await uploadSerially()
    }

    func queueUpload(_ id: UUID) {
        if !pendingUploads.contains(id) {
            pendingUploads.append(id)
            saveQueue()
        }
    }

    /// One upload pass at a time, so a run is never posted twice concurrently.
    private func uploadSerially() async -> CoachNote? {
        let previous = uploadInFlight
        let task = Task { () -> CoachNote? in
            let earlier = await previous?.value
            return await uploadPending() ?? earlier
        }
        uploadInFlight = task
        return await task.value
    }

    /// Upload queued runs; returns the newest coach note received, if any.
    @discardableResult
    private func uploadPending() async -> CoachNote? {
        guard api.token != nil else { return nil }
        var note: CoachNote?
        // Upload oldest first so coach alternation and history are realistic.
        let queue = pendingUploads.sorted {
            (run(id: $0)?.startedAt ?? .distantPast) < (run(id: $1)?.startedAt ?? .distantPast)
        }
        for id in queue where !pendingDeletes.contains(id) {
            guard let run = run(id: id) else {
                pendingUploads.removeAll { $0 == id }
                continue
            }
            do {
                struct Response: Decodable {
                    var coach: CoachNote?
                }
                let response: Response = try await api.post("runs", body: run.uploadBody)
                pendingUploads.removeAll { $0 == id }
                if let coach = response.coach {
                    note = coach
                    latestCoach = coach
                }
            } catch {
                break // offline — try again next foreground
            }
        }
        saveQueue()
        saveCoach()
        return note
    }

    // MARK: Imports

    struct ImportOutcome {
        var added: Int
        /// Already imported, or the same run recorded in Jogga.
        var duplicates: Int
    }

    /// Store imported history on the server (never coached) then locally.
    /// Re-importing is safe: the server answers with ids it already holds.
    func importRuns(_ imported: [Run], source: String) async throws -> ImportOutcome {
        let known = Set(runs.filter { $0.source == source }.compactMap(\.externalID))
        let recorded = runs.filter { !$0.isImported }
        let candidates = imported.filter { run in
            guard let externalID = run.externalID, !known.contains(externalID) else { return false }
            return !recorded.contains { Self.sameRun($0, run) }
        }
        struct Response: Decodable {
            var ids: [String: UUID]
        }
        var ids: [String: UUID] = [:]
        for start in stride(from: 0, to: candidates.count, by: 200) {
            let batch = candidates[start..<min(start + 200, candidates.count)]
            let response: Response = try await api.post("runs/import", body: [
                "source": source,
                "runs": batch.map(\.uploadBody),
            ])
            ids.merge(response.ids) { $1 }
        }
        var added = 0
        for var run in candidates {
            guard let externalID = run.externalID, let id = ids[externalID] else { continue }
            run.id = id
            runs.removeAll { $0.id == id }
            runs.append(run)
            added += 1
        }
        runs.sort { $0.startedAt > $1.startedAt }
        saveRuns()
        if let me: MeResponse = try? await api.get("me") {
            targets = me.targets
            stats = me.stats
            saveMe()
        }
        return ImportOutcome(added: added, duplicates: imported.count - added)
    }

    /// One coach call so the next-run plan reflects imported history.
    @discardableResult
    func replanCoach() async -> CoachNote? {
        guard let note = (try? await api.post("coach/replan", body: [:])) as CoachNote?? else {
            return nil
        }
        if let note {
            latestCoach = note
            saveCoach()
        }
        return note
    }

    func removeImported(source: String) async throws {
        try await api.delete("runs", query: [URLQueryItem(name: "source", value: source)])
        runs.removeAll { $0.source == source }
        saveRuns()
        if let me: MeResponse = try? await api.get("me") {
            targets = me.targets
            stats = me.stats
            saveMe()
        }
        let note = (try? await api.get("coach/latest")) as CoachNote??
        latestCoach = note ?? nil
        if latestCoach == nil {
            try? FileManager.default.removeItem(at: coachURL)
        } else {
            saveCoach()
        }
    }

    /// Same tolerance as the server: starts within 3 min, distance within 5%.
    static func sameRun(_ a: Run, _ b: Run) -> Bool {
        abs(a.startedAt.timeIntervalSince(b.startedAt)) <= 180
            && abs(a.distanceM - b.distanceM) <= 0.05 * max(a.distanceM, b.distanceM)
    }

    // MARK: Server state

    func refresh() async {
#if DEBUG
        guard !usingSeedRunsFile else { return }
#endif
        guard api.token != nil else { return }
        if let me: MeResponse = try? await api.get("me") {
            targets = me.targets
            stats = me.stats
            saveMe()
            hasSyncedMe = true
        }
        if let note = (try? await api.get("coach/latest")) as CoachNote?? {
            if let note {
                latestCoach = note
                saveCoach()
            }
        }
        _ = await uploadSerially()
        await syncDeletes()
    }

    func setTarget(distance: String, seconds: Int) async {
        targets[distance] = seconds
        saveMe()
        do {
            try await api.put("targets/\(distance)", body: ["target_s": seconds])
            await refresh()
        } catch {
            // Offline — the local target stays and syncs on next refresh.
        }
    }

    /// DEBUG `-resetDemo`: drop every run, the upload queue and cached coach.
    func wipe() {
        runs = []
        pendingUploads = []
        pendingDeletes = []
        targets = [:]
        stats = [:]
        hasSyncedMe = false
        latestCoach = nil
        for url in [runsURL, queueURL, deletesURL, coachURL, meURL] {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
