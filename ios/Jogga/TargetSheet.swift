import SwiftUI

/// Set target sheet: distance picker, wheel time picker, live pace line,
/// current best, one accent button.
struct TargetSheet: View {
    @Environment(RunStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var distance: String
    @State private var hours = 0
    @State private var minutes = 25
    @State private var seconds = 0
    @State private var didSet = false
    @State private var saving = false

    init(distance: String = "5k") {
        _distance = State(initialValue: distance)
    }

    private static let defaults: [String: Int] = [
        "5k": 25 * 60, "10k": 52 * 60, "half": 115 * 60, "marathon": 240 * 60,
    ]

    private var targetSeconds: Int {
        hours * 3600 + minutes * 60 + seconds
    }

    private var pace: Double {
        RunMath.requiredPace(distanceKey: distance, targetS: Double(targetSeconds))
    }

    private var best: Double? {
        store.stats[distance]?.bestS
            ?? store.runs.lazy.compactMap { $0.efforts[distance] }.min()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("Distance", selection: $distance) {
                ForEach(RunMath.standardDistances, id: \.key) { d in
                    Text(Fmt.distanceName(d.key)).tag(d.key)
                }
            }
            .pickerStyle(.segmented)
            .padding(.top, 20)

            HStack(spacing: 0) {
                wheel(0..<7, selection: $hours, unit: "hr")
                wheel(0..<60, selection: $minutes, unit: "min")
                wheel(0..<60, selection: $seconds, unit: "sec")
            }
            .frame(height: 180)
            .padding(.top, 8)

            VStack(spacing: 6) {
                Metric(value: Fmt.pace(pace), unit: "/km", size: 44)
                    .animation(reduceMotion ? nil : .snappy, value: pace)
                Text("Pace you'll need to hold")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)

            if let best {
                HStack {
                    Text("Your best \(Fmt.distanceName(distance))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(RunMath.formatTime(best))
                        .font(Jogga.numerals(17))
                }
                .font(.subheadline)
                .card(padding: 16)
                .padding(.top, 20)
            }

            Spacer(minLength: 20)

            Button {
                saving = true
                Task {
                    await store.setTarget(distance: distance, seconds: targetSeconds)
                    didSet = true
                    try? await Task.sleep(for: .milliseconds(350))
                    dismiss()
                }
            } label: {
                Text(store.targets[distance] == nil ? "Set target" : "Update target")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(targetSeconds <= 0 || saving)
            .sensoryFeedback(.success, trigger: didSet)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 12)
        .background(Color(.systemGroupedBackground))
        .presentationDetents([.large])
        .presentationCornerRadius(36)
        .onAppear { load(distance) }
        .onChange(of: distance) { _, new in load(new) }
        .sensoryFeedback(.selection, trigger: distance)
        .trackScreen(.target)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your target")
                    .font(Jogga.rounded(.largeTitle, weight: .bold))
                Text("Pick a distance and the time you want to beat.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Color(.tertiarySystemFill), in: Circle())
            }
            .accessibilityLabel("Close")
        }
    }

    private func load(_ key: String) {
        let total = store.targets[key] ?? Self.defaults[key] ?? 1500
        hours = total / 3600
        minutes = total % 3600 / 60
        seconds = total % 60
    }

    private func wheel(
        _ range: Range<Int>,
        selection: Binding<Int>,
        unit: String
    ) -> some View {
        Picker(unit, selection: selection) {
            ForEach(range, id: \.self) { value in
                Text("\(value) \(unit)")
                    .font(Jogga.numerals(20, weight: .medium))
                    .tag(value)
            }
        }
        .pickerStyle(.wheel)
        .accessibilityLabel(unit)
    }

    static func label(for key: String) -> String { Fmt.distanceName(key) }
}
