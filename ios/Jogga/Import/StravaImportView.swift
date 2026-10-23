import SwiftUI
import UniformTypeIdentifiers

extension Color {
    static let strava = Color(red: 252 / 255, green: 76 / 255, blue: 2 / 255)
}

/// Small "Strava" tag on imported runs.
struct StravaBadge: View {
    var body: some View {
        Text("Strava")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(Color.strava)
            .background(Color.strava.opacity(0.13), in: Capsule())
            .accessibilityLabel("Imported from Strava")
    }
}

/// Import runs from a Strava bulk export. Parsing happens on device; only
/// run summaries go to the server, and the coach runs once at the end.
struct StravaImportView: View {
    @Environment(RunStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case idle
        case reading(Double)
        case uploading
        case coaching
        case done(Summary)
        case failed(String)
    }

    private struct Summary: Equatable {
        var added: Int
        var withRoute: Int
        var duplicates: Int
        var otherActivities: Int
        var unreadable: Int
        var next: CoachNote.Payload.Next?
    }

    @State private var phase: Phase = .idle
    @State private var picking = false

    private var busy: Bool {
        switch phase {
        case .reading, .uploading, .coaching: return true
        default: return false
        }
    }

    var body: some View {
        NavigationStack {
            JoggaScreen {
                hero
                switch phase {
                case .idle, .failed:
                    stepsCard
                    if case .failed(let message) = phase { errorCard(message) }
                    chooseButton
                    privacyNote
                case .reading(let fraction):
                    progressCard(title: "Reading your runs…", fraction: fraction)
                case .uploading:
                    progressCard(title: "Saving your history…", fraction: nil)
                case .coaching:
                    progressCard(title: "Updating your coach…", fraction: nil)
                case .done(let summary):
                    resultCard(summary)
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Import from Strava")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !busy {
                        Button("Close") { dismiss() }
                    }
                }
            }
            .interactiveDismissDisabled(busy)
            .fileImporter(
                isPresented: $picking, allowedContentTypes: [.zip, .folder]
            ) { result in
                if case .success(let url) = result { start(url) }
            }
        }
        .trackScreen(.stravaImport)
    }

    // MARK: Sections

    private var hero: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.strava.opacity(0.13)).frame(width: 72, height: 72)
                Image(systemName: "figure.run")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Color.strava)
            }
            Text("Bring your running history")
                .font(Jogga.rounded(.title2, weight: .bold))
            Text("Your past runs give your coach the full picture: how long you've been running, your best times and your recent load.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var stepsCard: some View {
        Card(spacing: 14) {
            Text("Get your export").statLabel()
            step(1, "On strava.com, open Settings → My Account → Download or Delete Your Account.")
            step(2, "Tap Request Your Archive. Strava emails you a link, usually within a few hours.")
            step(3, "Download the ZIP to Files, then choose it below.")
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(Jogga.numerals(13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.strava, in: Circle())
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var chooseButton: some View {
        Button {
            picking = true
        } label: {
            Label("Choose Strava export", systemImage: "doc.zipper")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(.strava)
        .controlSize(.large)
    }

    private var privacyNote: some View {
        Label {
            Text("Only runs are imported. Routes stay on your iPhone; your coach sees run summaries only.")
        } icon: {
            Image(systemName: "lock.fill")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private func errorCard(_ message: String) -> some View {
        Card {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.red)
        }
    }

    private func progressCard(title: String, fraction: Double?) -> some View {
        Card(spacing: 14) {
            Text(title).font(.headline)
            if let fraction {
                ProgressView(value: fraction).tint(.strava)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    private func resultCard(_ summary: Summary) -> some View {
        Card(spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Metric(value: "\(summary.added)", unit: summary.added == 1 ? "run" : "runs",
                       size: 44, weight: .bold)
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.green)
            }
            Text("imported from Strava").statLabel()
            Divider()
            row("map", "With routes", summary.withRoute)
            if summary.duplicates > 0 { row("arrow.triangle.2.circlepath", "Already in Jogga", summary.duplicates) }
            if summary.otherActivities > 0 {
                row("bicycle", "Rides and other activities skipped", summary.otherActivities)
            }
            if summary.unreadable > 0 { row("questionmark.circle", "Runs without data", summary.unreadable) }
            if let next = summary.next {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your coach suggests").statLabel()
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Metric(value: Fmt.kmShort(next.km), unit: "km", size: 28, weight: .bold)
                        Metric(value: Fmt.pace(Double(next.pace)), unit: "/km", size: 20)
                            .foregroundStyle(Color.brand)
                        Spacer()
                        Chip(text: next.kind.capitalized)
                    }
                    Text(next.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func row(_ icon: String, _ label: String, _ value: Int) -> some View {
        HStack {
            Label(label, systemImage: icon)
                .font(.subheadline)
            Spacer()
            Text("\(value)")
                .font(Jogga.numerals(16))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Import

    private func start(_ url: URL) {
        phase = .reading(0)
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let parsed = try await Task.detached(priority: .userInitiated) {
                    let files: ExportFiles = url.hasDirectoryPath
                        ? FolderFiles(root: url) : try ZipReader(url: url)
                    return try StravaImporter.load(files) { fraction in
                        Task { @MainActor in
                            if case .reading = phase { phase = .reading(fraction) }
                        }
                    }
                }.value
                phase = .uploading
                let outcome = try await store.importRuns(parsed.runs, source: StravaImporter.source)
                var next: CoachNote.Payload.Next?
                if outcome.added > 0 {
                    phase = .coaching
                    next = await store.replanCoach()?.payload.next
                }
                Analytics.capture(.stravaImported, [
                    "runs": .string(Analytics.countBand(outcome.added)),
                    "with_route": .string(Analytics.countBand(parsed.withRoute)),
                    "other_skipped": .string(Analytics.countBand(parsed.otherActivities)),
                ])
                phase = .done(Summary(
                    added: outcome.added,
                    withRoute: parsed.withRoute,
                    duplicates: outcome.duplicates,
                    otherActivities: parsed.otherActivities,
                    unreadable: parsed.unreadable,
                    next: next
                ))
            } catch let error as StravaImporter.ImportError {
                phase = .failed(error.localizedDescription)
            } catch is ZipReader.ZipError {
                phase = .failed("Couldn't open that file. Choose the ZIP Strava emailed you.")
            } catch {
                phase = .failed("Couldn't reach Jogga. Check your connection and try again.")
            }
        }
    }
}
