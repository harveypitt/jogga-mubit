import SwiftUI

/// History tab: run cards grouped by month; tap -> summary; long-press to delete
/// (local only — server delete is out of scope for v0).
struct HistoryTabView: View {
    @Environment(RunStore.self) private var store
    @State private var visible = Self.pageSize

    private static let pageSize = 6

    private static func month(_ run: Run) -> String {
        run.startedAt.formatted(.dateTime.month(.wide).year())
    }

    /// The visible runs grouped by month, newest first.
    private var grouped: [(String, [Run])] {
        var groups: [(String, [Run])] = []
        for run in store.runs.prefix(visible) {
            let key = Self.month(run)
            if groups.last?.0 == key {
                groups[groups.count - 1].1.append(run)
            } else {
                groups.append((key, [run]))
            }
        }
        return groups
    }

    /// Whole-month totals, so a partly shown month still reads correctly.
    private var monthTotals: [String: (km: Double, runs: Int)] {
        var totals: [String: (km: Double, runs: Int)] = [:]
        for run in store.runs {
            let total = totals[Self.month(run), default: (0, 0)]
            totals[Self.month(run)] = (total.km + run.distanceM / 1000, total.runs + 1)
        }
        return totals
    }

    var body: some View {
        NavigationStack {
            JoggaScreen {
                let totals = monthTotals
                ForEach(grouped, id: \.0) { month, runs in
                    HStack(alignment: .firstTextBaseline) {
                        Text(month)
                            .font(Jogga.rounded(.title3, weight: .bold))
                        Spacer()
                        let total = totals[month] ?? (0, runs.count)
                        Text(String(format: "%.1f km · %d runs", total.km, total.runs))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
                    ForEach(runs) { run in
                        NavigationLink {
                            RunSummaryView(run: run)
                        } label: {
                            RunCard(run: run)
                        }
                        .buttonStyle(PressableStyle(scale: 0.98))
                        .tint(.primary)
                        .contextMenu {
                            Button(role: .destructive) {
                                withAnimation(.smooth) { store.delete(run) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                if store.runs.count > visible {
                    ShowMoreButton(remaining: store.runs.count - visible) {
                        withAnimation(.smooth) { visible += Self.pageSize }
                    }
                }
            }
            .navigationTitle("History")
            .overlay {
                if store.runs.isEmpty {
                    ContentUnavailableView(
                        "No runs yet",
                        systemImage: "figure.run",
                        description: Text("Your runs will appear here.")
                    )
                }
            }
        }
        .trackScreen(.history)
    }
}

/// Reveals the next page of run cards.
private struct ShowMoreButton: View {
    let remaining: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("Show more")
                    .font(Jogga.rounded(.subheadline, weight: .semibold))
                Text("\(remaining) earlier")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.brand)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: Jogga.cardRadius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: Jogga.cardRadius, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .tint(.primary)
        .padding(.top, 4)
    }
}
