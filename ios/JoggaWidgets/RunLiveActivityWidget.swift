import ActivityKit
import SwiftUI
import WidgetKit

struct RunLiveActivityWidget: Widget {
    private var brand: Color { Color("AccentColor") }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RunActivityAttributes.self) { context in
            lockScreen(context)
                .activitySystemActionForegroundColor(brand)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    islandDistanceMetric(context.state)
                        .padding(.leading, 6)
                        .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    islandTimeMetric(context.state)
                        .padding(.trailing, 6)
                        .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 3) {
                        Text("KM \(context.state.splitKm) · LIVE SPLIT")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .tracking(1)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(context.state.splitPaceText)
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(brand)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .monospacedDigit()
                            Text("/km")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 4)
                }
            } compactLeading: {
                Image(systemName: "figure.run")
                    .foregroundStyle(brand)
            } compactTrailing: {
                ViewThatFits(in: .horizontal) {
                    compactSplitPace(context.state, includesUnit: true)
                    compactSplitPace(context.state, includesUnit: false)
                    compactSplitPace(
                        context.state,
                        includesUnit: false,
                        allowsCompression: true
                    )
                }
            } minimal: {
                Image(systemName: "figure.run")
                    .foregroundStyle(brand)
            }
            .keylineTint(brand)
        }
    }

    private func lockScreen(
        _ context: ActivityViewContext<RunActivityAttributes>
    ) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("KM \(context.state.splitKm) · LIVE SPLIT")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(brand)
                    .tracking(1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(context.state.splitPaceText)
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .monospacedDigit()
                    Text("/km")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                if context.state.pausedElapsed != nil {
                    Text("Paused")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 12) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("TIME")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .tracking(0.8)
                    timer(context.state)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .monospacedDigit()
                }

                VStack(alignment: .trailing, spacing: 1) {
                    Text("DISTANCE")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .tracking(0.8)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(context.state.distanceText)
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .monospacedDigit()
                        Text("km")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
            }
        }
        .padding(16)
    }

    private func islandDistanceMetric(
        _ state: RunActivityAttributes.ContentState
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.distanceText)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .monospacedDigit()
            Text("KM")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .tracking(0.8)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func islandTimeMetric(
        _ state: RunActivityAttributes.ContentState
    ) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            timer(state)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .monospacedDigit()
            Text("TIME")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .tracking(0.8)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func compactSplitPace(
        _ state: RunActivityAttributes.ContentState,
        includesUnit: Bool,
        allowsCompression: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text("LIVE")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(brand.opacity(0.75))
                .tracking(0.5)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Text(state.splitPaceText)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(brand)
                .lineLimit(1)
                .minimumScaleFactor(allowsCompression ? 0.8 : 1)
                .monospacedDigit()
                .fixedSize(horizontal: !allowsCompression, vertical: false)

            if includesUnit {
                Text("/km")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .fixedSize(horizontal: !allowsCompression, vertical: false)
    }

    @ViewBuilder
    private func timer(_ state: RunActivityAttributes.ContentState) -> some View {
        if state.pausedElapsed != nil {
            Text(state.pausedText)
                .monospacedDigit()
        } else {
            Text(timerInterval: state.timerStart...Date.distantFuture, countsDown: false)
                .monospacedDigit()
        }
    }
}
