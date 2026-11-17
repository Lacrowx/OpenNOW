import SwiftUI

/// The stream menu and the failed-stream screen, as the console shell's sheet over the dimmed
/// game. Rows are lit from the coordinator's selection, not the focus engine: controller input
/// stays away from UIKit for the whole stream.
struct TVStreamMenuPanel: View {
    @ObservedObject var coordinator: TVStreamCoordinator
    /// Only for the hints' button symbols; it reads the controller while the menu is up.
    @StateObject private var input = TVConsoleInput()

    var body: some View {
        TVConsoleSheetPanel(eyebrow: eyebrow, title: coordinator.session.game.title, description: serverLine) {
            VStack(alignment: .leading, spacing: 0) {
                if let message {
                    Text(message)
                        .font(TVConsoleTheme.display(19, weight: 700))
                        .foregroundStyle(coordinator.failed && !coordinator.confirmingEnd
                            ? TVConsoleTheme.coral : TVConsoleTheme.label)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 22)
                }
                rows.padding(.top, 26)
                Spacer(minLength: 20)
                if !coordinator.failed, !coordinator.confirmingEnd, !coordinator.figures.isEmpty {
                    figures.padding(.bottom, 26)
                }
                hints
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .environmentObject(input)
        .onAppear { input.start() }
        .onDisappear { input.stop() }
    }

    private var eyebrow: String {
        if coordinator.confirmingEnd { return "END SESSION" }
        return coordinator.failed ? "STREAM FAILED" : "STREAM MENU"
    }

    private var message: String? {
        if coordinator.confirmingEnd { return "End this session? The game closes and unsaved progress may be lost." }
        return coordinator.failed ? coordinator.detail : nil
    }

    /// Zone the session was allocated in, with the host address when the provider reported one,
    /// and the GPU.
    private var serverLine: String {
        let session = coordinator.session
        var server = session.zone.isEmpty ? "Server not reported" : session.zone
        if let address = session.serverIp, !address.isEmpty { server += " (\(address))" }
        let gpu = session.gpuType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return gpu.isEmpty ? server : "\(server) · \(gpu)"
    }

    private var rows: some View {
        VStack(spacing: 4) {
            ForEach(Array(coordinator.menuItems.enumerated()), id: \.element) { index, item in
                row(item, selected: index == coordinator.selection)
            }
        }
        .animation(.easeOut(duration: TVConsoleTheme.focusDuration), value: coordinator.selection)
    }

    private func row(_ item: TVStreamMenuItem, selected: Bool) -> some View {
        let ink = item.isDestructive ? TVConsoleTheme.coral : TVConsoleTheme.label
        let feel = triggerFeel(of: item)
        return HStack(spacing: 0) {
            Image(systemName: item.symbol)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(ink)
                .frame(width: 30)
                .padding(.leading, 22)
                .padding(.trailing, 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(feel == nil ? coordinator.title(of: item) : item.rawValue)
                    .font(TVConsoleTheme.display(21, weight: selected ? 900 : 800))
                    .foregroundStyle(ink)
                Text(item.detail(failed: coordinator.failed))
                    .font(TVConsoleTheme.display(15, weight: 600))
                    .foregroundStyle(TVConsoleTheme.textMuted)
            }
            Spacer(minLength: 12)
            if let feel {
                // Left and Right change the feel of the row that is lit.
                HStack(spacing: 12) {
                    Image(systemName: "chevron.left").opacity(selected ? 1 : 0)
                    Text(feel)
                    Image(systemName: "chevron.right").opacity(selected ? 1 : 0)
                }
                .font(TVConsoleTheme.display(19, weight: 800))
                .foregroundStyle(TVConsoleTheme.label)
                .padding(.trailing, 22)
            }
        }
        .lineLimit(1)
        .frame(minHeight: 66)
        .modifier(TVConsoleSheetRow(focused: selected))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func triggerFeel(of item: TVStreamMenuItem) -> String? {
        switch item {
        case .leftTriggerFeel: coordinator.triggerFeels.left.title
        case .rightTriggerFeel: coordinator.triggerFeels.right.title
        default: nil
        }
    }

    /// The running stream's figures, as the shell's status pill draws its readings.
    private var figures: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(TVConsoleTheme.mint).frame(width: 9, height: 9)
                Text("LIVE")
                    .font(TVConsoleTheme.mono(14, bold: true))
                    .tracking(1.4)
                    .foregroundStyle(TVConsoleTheme.textMuted)
            }
            // Four to a row; the last figure of a short row takes the cells left over.
            let columns = 4
            let rows = stride(from: 0, to: coordinator.figures.count, by: columns).map {
                Array(coordinator.figures[$0..<min($0 + columns, coordinator.figures.count)])
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
                ForEach(rows, id: \.first?.label) { row in
                    GridRow {
                        ForEach(row, id: \.label) { figure in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(figure.label.uppercased())
                                    .font(TVConsoleTheme.mono(12))
                                    .tracking(1.1)
                                    .foregroundStyle(TVConsoleTheme.textMuted)
                                Text(figure.value)
                                    .font(TVConsoleTheme.mono(17, bold: true))
                                    .foregroundStyle(TVConsoleTheme.label)
                                    .minimumScaleFactor(0.7)
                            }
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .gridCellColumns(figure == row.last ? columns - row.count + 1 : 1)
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvConsoleGlass(radius: 24, fill: TVConsoleTheme.face.opacity(0.05))
    }

    private var hints: some View {
        let back = coordinator.confirmingEnd ? "Go back" : coordinator.failed ? "Close" : "Resume"
        return HStack {
            TVConsoleHintRow(hints: [.init(button: .back, label: back)])
            Spacer()
            TVConsoleHintRow(hints: [.init(button: .select, label: "Select")])
        }
    }
}
