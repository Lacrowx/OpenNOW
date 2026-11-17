import Charts
import SwiftUI

/// The report shown after a stream, as a console page: the score and the actions on the left,
/// the measurements, the latency over time and the findings on the right. It reads the same
/// `SessionReport` as the iOS sheet. Back closes it, as Done does.
struct TVConsoleSessionReportView: View {
    let report: SessionReport
    let onReportProblem: () -> Void
    let onDismiss: (_ disableFutureReports: Bool) -> Void

    @EnvironmentObject private var store: OpenNOWStore
    @Environment(\.openNowAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ringProgress = 0.0

    private enum Field: Hashable {
        case done, reportProblem, stopShowing
        case finding(String)
    }
    @FocusState private var focus: Field?

    var body: some View {
        ZStack(alignment: .topLeading) {
            TVConsoleBackground(artwork: artwork, tint: 0x17233B)
            HStack(alignment: .top, spacing: 64) {
                summary.frame(width: 560)
                VStack(alignment: .leading, spacing: 24) {
                    measurements
                    HStack(alignment: .top, spacing: 24) {
                        if report.showsTrendChart { trend.frame(width: 500) }
                        findings
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(width: 1056)
            }
            .padding(.leading, 120)
            .padding(.top, 96)
            .padding(.bottom, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .defaultFocus($focus, .done)
        .presentationBackground(TVConsoleTheme.shell)
        .task {
            let progress = Double(report.score) / 100
            guard !reduceMotion else { ringProgress = progress; return }
            withAnimation(.easeOut(duration: 0.8)) { ringProgress = progress }
        }
    }

    /// The game's artwork behind the page, when the catalog has a game of that name.
    private var artwork: String? {
        let game = store.libraryGames.first { $0.title == report.gameTitle }
            ?? store.allGames.first { $0.title == report.gameTitle }
        return game?.heroImageUrl ?? game?.detailsArtworkUrl
    }

    private var tone: Color { Self.color(for: report.rating.qualityLevel) }

    private static func color(for level: StreamQualityLevel) -> Color {
        switch level {
        case .good: TVConsoleTheme.mint
        case .fair: TVConsoleTheme.yellow
        case .poor: TVConsoleTheme.coral
        }
    }

    // MARK: Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SESSION REPORT")
                .font(TVConsoleTheme.mono(15))
                .tracking(2.1)
                .foregroundStyle(tone)
            Text(report.gameTitle)
                .font(TVConsoleTheme.display(56))
                .tracking(-1.2)
                .foregroundStyle(TVConsoleTheme.label)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .padding(.top, 10)
                .accessibilityAddTraits(.isHeader)
            Text("\(durationLabel) · \(report.networkKind.label)")
                .font(TVConsoleTheme.display(22, weight: 600))
                .foregroundStyle(TVConsoleTheme.textMuted)
                .padding(.top, 6)
            scoreRing.padding(.top, 40)
            if report.limitedData {
                Label("Too short to measure properly: treat the score as a rough reading.",
                      systemImage: "info.circle.fill")
                    .font(TVConsoleTheme.display(17, weight: 600))
                    .foregroundStyle(TVConsoleTheme.textMuted)
                    .padding(.top, 24)
            }
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 14) {
                TVConsoleActionButton(title: "Done", primary: true, fillsWidth: true) { onDismiss(false) }
                    .focused($focus, equals: .done)
                TVConsoleActionButton(title: "Report a problem", detail: "Send what OpenNOW knows about this session",
                                      fillsWidth: true, action: onReportProblem)
                    .focused($focus, equals: .reportProblem)
                TVConsoleActionButton(title: "Don't show after sessions", detail: "Turn it back on in Settings",
                                      fillsWidth: true) { onDismiss(true) }
                    .focused($focus, equals: .stopShowing)
            }
            .frame(width: 480)
            .focusSection()
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var scoreRing: some View {
        HStack(spacing: 32) {
            ZStack {
                Circle().stroke(TVConsoleTheme.seam, lineWidth: 14)
                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(tone, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(report.score)")
                    .font(TVConsoleTheme.display(72))
                    .monospacedDigit()
                    .foregroundStyle(TVConsoleTheme.label)
            }
            .frame(width: 180, height: 180)
            VStack(alignment: .leading, spacing: 4) {
                Text(report.rating.label)
                    .font(TVConsoleTheme.display(34))
                    .foregroundStyle(tone)
                Text("Session quality, out of 100")
                    .font(TVConsoleTheme.display(17, weight: 600))
                    .foregroundStyle(TVConsoleTheme.textMuted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Session quality")
        .accessibilityValue("\(report.score) out of 100, \(report.rating.label)")
    }

    private var durationLabel: String {
        let hours = report.durationSeconds / 3_600
        let minutes = (report.durationSeconds % 3_600) / 60
        if hours > 0 { return "\(hours) hr \(minutes) min" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(report.durationSeconds) sec"
    }

    // MARK: Measurements

    private var measurements: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4), spacing: 16) {
            ForEach(measurementTiles) { tile in
                VStack(alignment: .leading, spacing: 4) {
                    Text(tile.title.uppercased())
                        .font(TVConsoleTheme.mono(13))
                        .tracking(1.3)
                        .foregroundStyle(TVConsoleTheme.textMuted)
                    HStack(spacing: 8) {
                        // Colour is never the only signal: a glyph carries the same reading.
                        if let glyph = tile.level.glyph {
                            Image(systemName: glyph).font(.system(size: 20, weight: .bold))
                        }
                        Text(tile.primary)
                            .font(TVConsoleTheme.display(34))
                            .monospacedDigit()
                            .minimumScaleFactor(0.6)
                    }
                    .foregroundStyle(tile.level == .good ? TVConsoleTheme.label : Self.color(for: tile.level))
                    Text(tile.secondary ?? " ")
                        .font(TVConsoleTheme.display(15, weight: 700))
                        .foregroundStyle(TVConsoleTheme.textMuted)
                }
                .lineLimit(1)
                .padding(.horizontal, 22)
                .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
                .tvConsoleGlass(radius: 28)
                .accessibilityElement(children: .combine)
                .accessibilityValue(tile.level == .good ? "" : tile.level.label)
            }
        }
    }

    private struct Tile: Identifiable {
        let title: String
        let primary: String
        let secondary: String?
        let level: StreamQualityLevel
        var id: String { title }
    }

    /// The figures of the iOS report's Measurements list, rated on the same ladders as the score.
    private var measurementTiles: [Tile] {
        var tiles: [Tile] = []
        if let avg = report.averagePingMs {
            tiles.append(Tile(title: "Latency", primary: "\(avg) ms",
                secondary: report.peakPingMs.map { "peak \($0) ms" }, level: StreamQuality.latency(avg)))
        }
        if let loss = report.packetLossPercent {
            tiles.append(Tile(title: "Packet loss", primary: String(format: "%.1f%%", loss),
                secondary: report.peakPacketLossPercent.map { String(format: "peak %.1f%%", $0) },
                level: StreamQuality.packetLoss(loss)))
        }
        if let jitter = report.averageJitterMs {
            tiles.append(Tile(title: "Jitter", primary: String(format: "%.1f ms", jitter),
                secondary: nil, level: StreamQuality.jitter(jitter)))
        }
        if let fps = report.averageFps {
            tiles.append(Tile(title: "Frame rate", primary: String(format: "%.0f fps", fps),
                secondary: report.lowestFps.map { "low \($0) fps" },
                level: StreamQuality.frameRate(fps, targetFps: report.targetFps)))
        }
        if let decode = report.averageDecodeMs {
            tiles.append(Tile(title: "Decode", primary: String(format: "%.1f ms", decode),
                secondary: report.peakDecodeMs.map { String(format: "peak %.1f ms", $0) },
                level: StreamQuality.decode(decode, targetFps: report.targetFps, actualFps: report.averageFps)))
        }
        if let bitrate = report.averageBitrateKbps {
            tiles.append(Tile(title: "Bitrate", primary: String(format: "%.1f Mb/s", Double(bitrate) / 1_000),
                secondary: report.peakBitrateKbps.map { String(format: "peak %.1f Mb/s", Double($0) / 1_000) },
                level: .good))
        }
        let delivered = report.deliveredResolution
        let differs = delivered.map {
            StreamSessionReportAccumulator.normalizedResolutionLabel($0) != report.requestedResolution
        } ?? false
        tiles.append(Tile(title: "Resolution", primary: delivered ?? report.requestedResolution,
            secondary: differs ? "asked for \(report.requestedResolution)" : nil, level: differs ? .fair : .good))
        return tiles
    }

    // MARK: Trend

    private var trend: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeader("Latency over time")
            Chart(report.trend) { point in
                AreaMark(x: .value("Time", point.offsetSeconds), y: .value("Latency", point.pingMs))
                    .foregroundStyle(LinearGradient(colors: [accent.color.opacity(0.32), accent.color.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", point.offsetSeconds), y: .value("Latency", point.pingMs))
                    .foregroundStyle(accent.color)
                    .lineStyle(StrokeStyle(lineWidth: 3))
                    .interpolationMethod(.monotone)
            }
            // The line runs to the right edge instead of a rounded-up end of the axis.
            .chartXScale(domain: 0...max(1, report.trend.last?.offsetSeconds ?? 1))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(TVConsoleTheme.seam)
                    AxisValueLabel {
                        if let ms = value.as(Int.self) {
                            Text("\(ms) ms").font(TVConsoleTheme.mono(13)).foregroundStyle(TVConsoleTheme.textMuted)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisValueLabel {
                        if let seconds = value.as(Int.self) {
                            Text("\(seconds / 60) min").font(TVConsoleTheme.mono(13))
                                .foregroundStyle(TVConsoleTheme.textMuted)
                        }
                    }
                }
            }
            .accessibilityLabel("Latency over the session, in milliseconds")
        }
        .padding(28)
        .frame(maxHeight: .infinity, alignment: .top)
        .tvConsoleGlass(radius: 32)
    }

    // MARK: Findings

    /// Focusable rows, so a list longer than the panel scrolls as focus moves down it.
    private var findings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if !report.downgrades.isEmpty {
                    sectionHeader("What happened").padding(.horizontal, 18).padding(.bottom, 6)
                    ForEach(report.downgrades) { finding($0, section: "downgrade") }
                }
                if !report.recommendations.isEmpty {
                    sectionHeader("Suggestions")
                        .padding(.horizontal, 18)
                        .padding(.top, report.downgrades.isEmpty ? 0 : 20)
                        .padding(.bottom, 6)
                    ForEach(report.recommendations) { finding($0, section: "suggestion") }
                }
            }
            // Room for the focus ring, which the scroll view would otherwise clip.
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .tvConsoleGlass(radius: 32)
        .clipShape(RoundedRectangle(cornerRadius: 32))
        .focusSection()
    }

    private func finding(_ finding: SessionReportFinding, section: String) -> some View {
        let field = Field.finding("\(section).\(finding.id)")
        let warning = finding.kind == .warning
        return HStack(alignment: .top, spacing: 16) {
            Image(systemName: warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(warning ? TVConsoleTheme.yellow : accent.color)
                .frame(width: 26)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(finding.title)
                    .font(TVConsoleTheme.display(20, weight: 900))
                    .foregroundStyle(TVConsoleTheme.label)
                Text(finding.detail)
                    .font(TVConsoleTheme.display(16, weight: 600))
                    .lineSpacing(3)
                    .foregroundStyle(TVConsoleTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .modifier(TVConsoleSheetRow(focused: focus == field))
        .focusable()
        .focused($focus, equals: field)
        .accessibilityElement(children: .combine)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(TVConsoleTheme.mono(14, bold: true))
            .tracking(1.4)
            .foregroundStyle(TVConsoleTheme.textMuted)
    }
}
