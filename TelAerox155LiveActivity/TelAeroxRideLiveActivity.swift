import ActivityKit
import SwiftUI
import WidgetKit

/// UI Dynamic Island & Lock Screen Live Activity untuk TelAerox155.
///
/// Mendukung 3 kondisi dalam satu aktivitas terpadu agar Dynamic Island tidak
/// terpecah jadi dua pulau:
/// 1. Hanya rekam perjalanan (CSV / BLE mentah)
/// 2. Hanya navigasi rute aktif (turn-by-turn)
/// 3. Navigasi rute + rekam perjalanan aktif bersamaan
struct TelAeroxRideLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideLiveActivityAttributes.self) { context in
            LockScreenRideView(state: context.state)
                .activityBackgroundTint(LiveActivityPalette.background)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(context.state.deepLinkURL)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ExpandedLeadingView(state: state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedTrailingView(state: state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBottomView(state: state)
                }
            } compactLeading: {
                CompactLeadingView(state: state)
            } compactTrailing: {
                CompactTrailingView(state: state)
            } minimal: {
                MinimalView(state: state)
            }
            .keylineTint(LiveActivityPalette.keylineTint(for: state))
            .widgetURL(state.deepLinkURL)
        }
    }
}

// MARK: - Palet warna (selaras dengan TelAerox155)

private enum LiveActivityPalette {
    static let background = Color(red: 0.05, green: 0.08, blue: 0.14)
    static let card = Color.white.opacity(0.08)
    static let accent = Color(red: 0.20, green: 0.56, blue: 0.95)
    static let red = Color(red: 0.95, green: 0.26, blue: 0.30)
    static let green = Color(red: 0.20, green: 0.80, blue: 0.45)
    static let orange = Color(red: 1.00, green: 0.62, blue: 0.15)

    static func keylineTint(for state: RideLiveActivityState) -> Color {
        if state.hasArrived { return green }
        if state.isNavigating { return accent }
        if state.autoStopDeadline != nil { return orange }
        return red
    }
}

// MARK: - Compact & Minimal Dynamic Island

private struct CompactLeadingView: View {
    let state: RideLiveActivityState

    var body: some View {
        switch state.mode {
        case .recording:
            HStack(spacing: 4) {
                Image(systemName: "record.circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(state.autoStopDeadline != nil ? LiveActivityPalette.orange : LiveActivityPalette.red)
                if let speed = state.speedKmh {
                    Text("\(speed)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                } else {
                    Text("REC")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(LiveActivityPalette.red)
                }
            }
            .padding(.leading, 2)

        case .navigating:
            Image(systemName: state.activeManeuverSymbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(state.hasArrived ? LiveActivityPalette.green : LiveActivityPalette.accent)
                .padding(.leading, 2)

        case .navigatingAndRecording:
            HStack(spacing: 4) {
                Circle()
                    .fill(LiveActivityPalette.red)
                    .frame(width: 6, height: 6)
                Image(systemName: state.activeManeuverSymbol)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(state.hasArrived ? LiveActivityPalette.green : LiveActivityPalette.accent)
            }
            .padding(.leading, 2)
        }
    }
}

private struct CompactTrailingView: View {
    let state: RideLiveActivityState

    var body: some View {
        switch state.mode {
        case .recording:
            if let deadline = state.autoStopDeadline {
                Text(timerInterval: Date.now...max(Date.now, deadline), countsDown: true)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(LiveActivityPalette.orange)
                    .monospacedDigit()
                    .frame(maxWidth: 46, alignment: .trailing)
            } else if let startedAt = state.recordingStartedAt {
                Text(startedAt, style: .timer)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(maxWidth: 48, alignment: .trailing)
            } else {
                Text(state.recordingFormatLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }

        case .navigating, .navigatingAndRecording:
            Text(state.compactManeuverText)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(state.hasArrived ? LiveActivityPalette.green : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.trailing, 2)
        }
    }
}

private struct MinimalView: View {
    let state: RideLiveActivityState

    var body: some View {
        switch state.mode {
        case .recording:
            Image(systemName: "record.circle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(state.autoStopDeadline != nil ? LiveActivityPalette.orange : LiveActivityPalette.red)

        case .navigating:
            Image(systemName: state.activeManeuverSymbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(state.hasArrived ? LiveActivityPalette.green : LiveActivityPalette.accent)

        case .navigatingAndRecording:
            ZStack(alignment: .topTrailing) {
                Image(systemName: state.activeManeuverSymbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(state.hasArrived ? LiveActivityPalette.green : LiveActivityPalette.accent)
                Circle()
                    .fill(LiveActivityPalette.red)
                    .frame(width: 5, height: 5)
                    .offset(x: 2, y: -2)
            }
        }
    }
}

// MARK: - Expanded Dynamic Island

private struct ExpandedLeadingView: View {
    let state: RideLiveActivityState

    var body: some View {
        if state.isNavigating {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill((state.hasArrived ? LiveActivityPalette.green : LiveActivityPalette.accent).gradient)
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: state.activeManeuverSymbol)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                    }
                if state.isRecording {
                    Circle()
                        .fill(LiveActivityPalette.red)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                        .offset(x: 3, y: -3)
                }
            }
            .padding(.leading, 4)
            .padding(.top, 2)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "record.circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(LiveActivityPalette.red)
                    Text("MEREKAM")
                        .font(.caption2.weight(.heavy))
                        .tracking(0.6)
                        .foregroundStyle(LiveActivityPalette.red)
                }
                HStack(spacing: 4) {
                    Text(state.recordingFormatLabel)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(LiveActivityPalette.accent.opacity(0.28), in: Capsule())
                    if state.isAutomaticRecording {
                        Text("AUTO")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(LiveActivityPalette.accent)
                    }
                }
            }
            .padding(.leading, 4)
            .padding(.top, 2)
        }
    }
}

private struct ExpandedTrailingView: View {
    let state: RideLiveActivityState

    var body: some View {
        if state.isNavigating {
            VStack(alignment: .trailing, spacing: 2) {
                Text(state.compactManeuverText)
                    .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(state.hasArrived ? LiveActivityPalette.green : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                HStack(spacing: 4) {
                    Text("\(state.speedText) km/h")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                    if state.speedKmh != nil {
                        Text(state.speedSourceLabel)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(state.speedFromMotor ? LiveActivityPalette.accent : .secondary)
                    }
                }
            }
            .padding(.trailing, 4)
            .padding(.top, 2)
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                if let startedAt = state.recordingStartedAt {
                    Text(startedAt, style: .timer)
                        .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 92, alignment: .trailing)
                }
                Text(state.motorConnected ? "Motor terhubung" : "Motor terputus")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(state.motorConnected ? LiveActivityPalette.green : LiveActivityPalette.orange)
                    .lineLimit(1)
            }
            .padding(.trailing, 4)
            .padding(.top, 2)
        }
    }
}

private struct ExpandedBottomView: View {
    let state: RideLiveActivityState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.isNavigating {
                Text(state.nextInstruction)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                if let rain = state.rainWarning {
                    HStack(spacing: 5) {
                        Image(systemName: "cloud.rain.fill")
                            .font(.caption2)
                            .foregroundStyle(LiveActivityPalette.orange)
                        Text(rain)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(LiveActivityPalette.orange)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 8) {
                    if let eta = state.etaClockText, !state.hasArrived {
                        Label("Tiba \(eta)", systemImage: "clock")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                    }
                    if !state.remainingDistanceText.isEmpty && !state.hasArrived {
                        Text("· \(state.remainingDistanceText)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if state.hasArrived {
                        Text(state.destinationName)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if state.isRecording, let startedAt = state.recordingStartedAt {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(LiveActivityPalette.red)
                                .frame(width: 6, height: 6)
                            Text(startedAt, style: .timer)
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(LiveActivityPalette.red)
                                .frame(maxWidth: 46, alignment: .trailing)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(LiveActivityPalette.red.opacity(0.18), in: Capsule())
                    } else if let rpm = state.rpmText {
                        Text("\(rpm) rpm")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                // Mode rekam perjalanan saja
                HStack(spacing: 8) {
                    MetricPill(
                        title: state.speedKmh != nil ? "km/h · \(state.speedSourceLabel)" : "Kecepatan",
                        value: state.speedText,
                        tint: .white
                    )
                    if state.motorConnected {
                        MetricPill(
                            title: "RPM",
                            value: state.rpmText ?? "--",
                            tint: .white
                        )
                        MetricPill(
                            title: "Mesin / Aki",
                            value: motorHealthText(state),
                            tint: (state.isCoolantWarning || state.isBatteryWarning)
                                ? LiveActivityPalette.orange : LiveActivityPalette.green
                        )
                    } else {
                        MetricPill(
                            title: state.recordingFormatLabel == "CSV" ? "Baris" : "Frame",
                            value: state.lineCount.formatted(),
                            tint: .white
                        )
                    }
                }

                if let deadline = state.autoStopDeadline {
                    HStack(spacing: 5) {
                        Image(systemName: "timer")
                            .font(.caption2)
                        Text(state.autoStopIsInactivity ? "Potong otomatis dalam" : "Berhenti otomatis dalam")
                            .font(.caption2)
                        Text(timerInterval: Date.now...max(Date.now, deadline), countsDown: true)
                            .font(.caption2.weight(.bold).monospacedDigit())
                    }
                    .foregroundStyle(LiveActivityPalette.orange)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private func motorHealthText(_ state: RideLiveActivityState) -> String {
        switch (state.coolantText, state.batteryText) {
        case let (c?, b?): return "\(c) · \(b)"
        case let (c?, nil): return c
        case let (nil, b?): return b
        default: return "--"
        }
    }
}

// MARK: - Lock Screen / StandBy Banner

private struct LockScreenRideView: View {
    let state: RideLiveActivityState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.isNavigating {
                navigationHeader
                if let rain = state.rainWarning {
                    HStack(spacing: 6) {
                        Image(systemName: "cloud.rain.fill")
                            .font(.caption)
                            .foregroundStyle(LiveActivityPalette.orange)
                        Text("\(rain) · Open-Meteo.com")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(LiveActivityPalette.orange)
                            .lineLimit(1)
                    }
                }
                navigationFooter
            } else {
                recordingHeader
                recordingMetrics
                if let deadline = state.autoStopDeadline {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption)
                        Text(state.autoStopIsInactivity
                             ? "Tidak ada aktivitas · potong otomatis dalam"
                             : "Motor terputus · berhenti otomatis dalam")
                            .font(.caption2)
                        Text(timerInterval: Date.now...max(Date.now, deadline), countsDown: true)
                            .font(.caption2.weight(.bold).monospacedDigit())
                    }
                    .foregroundStyle(LiveActivityPalette.orange)
                }
            }
        }
        .padding(16)
    }

    private var navigationHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill((state.hasArrived ? LiveActivityPalette.green : LiveActivityPalette.accent).gradient)
                .frame(width: 48, height: 48)
                .overlay {
                    Image(systemName: state.activeManeuverSymbol)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(state.compactManeuverText)
                        .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(state.hasArrived ? LiveActivityPalette.green : .white)
                    Spacer(minLength: 4)
                    if state.isRecording, let startedAt = state.recordingStartedAt {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(LiveActivityPalette.red)
                                .frame(width: 6, height: 6)
                            Text("REC")
                                .font(.caption2.weight(.heavy))
                            Text(startedAt, style: .timer)
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .frame(maxWidth: 46, alignment: .trailing)
                        }
                        .foregroundStyle(LiveActivityPalette.red)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(LiveActivityPalette.red.opacity(0.18), in: Capsule())
                    } else {
                        Text("TelAerox")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(state.nextInstruction)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
        }
    }

    private var navigationFooter: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                if state.hasArrived {
                    Text(state.destinationName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                } else {
                    Text(state.etaClockText.map { "Tiba \($0)" } ?? state.destinationName)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !state.remainingDistanceText.isEmpty {
                        Text("Sisa \(state.remainingDistanceText)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 8)

            HStack(spacing: 10) {
                CompactStat(value: "\(state.speedText)", unit: "km/h", accent: .white)
                if state.motorConnected {
                    if let rpm = state.rpmText {
                        CompactStat(value: rpm, unit: "RPM", accent: .white)
                    }
                    if let coolant = state.coolantText {
                        CompactStat(value: coolant, unit: "Mesin",
                                    accent: state.isCoolantWarning ? LiveActivityPalette.orange : .white)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(LiveActivityPalette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var recordingHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "record.circle.fill")
                .font(.title3)
                .foregroundStyle(LiveActivityPalette.red)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Merekam \(state.recordingFormatLabel == "CSV" ? "Perjalanan" : "BLE Mentah")")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    if state.isAutomaticRecording {
                        Text("AUTO")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(LiveActivityPalette.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(LiveActivityPalette.accent.opacity(0.2), in: Capsule())
                    }
                }
                Text(state.motorConnected ? "TelAerox · Motor terhubung" : "TelAerox · Motor terputus")
                    .font(.caption2)
                    .foregroundStyle(state.motorConnected ? LiveActivityPalette.green : LiveActivityPalette.orange)
            }
            Spacer(minLength: 4)
            if let startedAt = state.recordingStartedAt {
                Text(startedAt, style: .timer)
                    .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 96, alignment: .trailing)
            }
        }
    }

    private var recordingMetrics: some View {
        HStack(spacing: 8) {
            MetricPill(
                title: state.speedKmh != nil ? "km/h · \(state.speedSourceLabel)" : "Kecepatan",
                value: state.speedText,
                tint: .white
            )
            if state.motorConnected {
                MetricPill(title: "RPM", value: state.rpmText ?? "--", tint: .white)
                MetricPill(title: "Mesin", value: state.coolantText ?? "--",
                           tint: state.isCoolantWarning ? LiveActivityPalette.orange : .white)
                MetricPill(title: "Aki", value: state.batteryText ?? "--",
                           tint: state.isBatteryWarning ? LiveActivityPalette.orange : LiveActivityPalette.green)
            } else {
                MetricPill(
                    title: state.recordingFormatLabel == "CSV" ? "Baris tersimpan" : "Frame tersimpan",
                    value: state.lineCount.formatted(),
                    tint: .white
                )
            }
        }
    }
}

// MARK: - Subkomponen

private struct MetricPill: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(LiveActivityPalette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct CompactStat: View {
    let value: String
    let unit: String
    let accent: Color

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(value)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(accent)
                .lineLimit(1)
            Text(unit)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Preview

#Preview("Rekam Aktif", as: .dynamicIsland(.expanded), using: RideLiveActivityAttributes(sessionID: "preview")) {
    TelAeroxRideLiveActivity()
} contentStates: {
    RideLiveActivityState(
        mode: .recording,
        isRecording: true,
        recordingStartedAt: Date().addingTimeInterval(-742),
        recordingFormatLabel: "CSV",
        isAutomaticRecording: true,
        autoStopDeadline: nil,
        lineCount: 742,
        isNavigating: false,
        hasArrived: false,
        isRerouting: false,
        maneuverSymbol: "arrow.up",
        distanceToManeuverText: "",
        nextInstruction: "",
        destinationName: "",
        remainingDistanceText: "",
        etaDate: nil,
        rainWarning: nil,
        speedKmh: 56,
        speedFromMotor: true,
        motorConnected: true,
        rpm: 5200,
        coolantC: 88,
        batteryV10: 141
    )
}

#Preview("Navigasi + Rekam", as: .content, using: RideLiveActivityAttributes(sessionID: "preview")) {
    TelAeroxRideLiveActivity()
} contentStates: {
    RideLiveActivityState(
        mode: .navigatingAndRecording,
        isRecording: true,
        recordingStartedAt: Date().addingTimeInterval(-510),
        recordingFormatLabel: "CSV",
        isAutomaticRecording: false,
        autoStopDeadline: nil,
        lineCount: 510,
        isNavigating: true,
        hasArrived: false,
        isRerouting: false,
        maneuverSymbol: "arrow.turn.up.right",
        distanceToManeuverText: "250 m",
        nextInstruction: "Belok kanan ke Jl. Asia Afrika",
        destinationName: "Alun-Alun Bandung",
        remainingDistanceText: "4,2 km",
        etaDate: Date().addingTimeInterval(660),
        rainWarning: "Hujan ringan diperkirakan di tujuan",
        speedKmh: 48,
        speedFromMotor: true,
        motorConnected: true,
        rpm: 4600,
        coolantC: 90,
        batteryV10: 140
    )
}
