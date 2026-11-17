import AVFoundation
import AVKit
import Combine
import GameController
import SwiftUI
import UIKit

/// tvOS stream screen: native NVST video with a status overlay and an in-stream menu.
struct TVStreamerView: View {
    @StateObject private var coordinator: TVStreamCoordinator
    @EnvironmentObject private var store: OpenNOWStore

    init(make: @escaping @MainActor () -> TVStreamCoordinator) {
        _coordinator = StateObject(wrappedValue: make())
    }

    var body: some View {
        TVStreamHost(coordinator: coordinator, accent: store.settings.uiAccent)
            .ignoresSafeArea()
            .onAppear {
                coordinator.onEndSession = { [store] in Task { await store.endSession() } }
                coordinator.start()
            }
            .onDisappear { coordinator.stop() }
    }
}

private struct TVStreamHost: UIViewControllerRepresentable {
    let coordinator: TVStreamCoordinator
    /// The overlay is hosted on its own, outside the app's environment.
    let accent: UIAccent
    /// Lets a preview show artwork in place of the video.
    var transparent = false

    func makeUIViewController(context: Context) -> TVStreamHostController {
        TVStreamHostController(coordinator: coordinator, accent: accent, transparent: transparent)
    }

    func updateUIViewController(_ controller: TVStreamHostController, context: Context) {}
}

/// `GCEventViewController` keeps controller and remote buttons away from UIKit for the whole
/// stream, so B or Back reach the game or the stream menu instead of leaving the app.
private final class TVStreamHostController: GCEventViewController {
    private let coordinator: TVStreamCoordinator
    private let overlay: UIHostingController<TVStreamOverlay>
    private let transparent: Bool
    private var displayCriteriaObserver: AnyCancellable?

    init(coordinator: TVStreamCoordinator, accent: UIAccent, transparent: Bool) {
        self.coordinator = coordinator
        self.transparent = transparent
        overlay = UIHostingController(rootView: TVStreamOverlay(coordinator: coordinator, accent: accent))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = transparent ? .clear : .black
        view.layer.addSublayer(coordinator.displayLayer)
        addChild(overlay)
        overlay.view.backgroundColor = .clear
        overlay.view.frame = view.bounds
        overlay.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(overlay.view)
        overlay.didMove(toParent: self)
        controllerUserInteractionEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The display manager belongs to the window, which exists only once the view is on screen.
        displayCriteriaObserver = coordinator.$displayCriteria.sink { [weak self] criteria in
            guard let manager = self?.view.window?.avDisplayManager else { return }
            manager.preferredDisplayCriteria = criteria
            tvStreamDebug("[TVStream] display criteria \(criteria == nil ? "cleared" : "set") matchContent=\(manager.isDisplayCriteriaMatchingEnabled)")
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        displayCriteriaObserver = nil
        view.window?.avDisplayManager.preferredDisplayCriteria = nil
    }

    /// The Siri Remote's buttons still arrive here; game controllers stay with GameController.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses { coordinator.remotePressed(press.type) }
        super.pressesBegan(presses, with: event)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        coordinator.displayLayer.frame = view.bounds
        CATransaction.commit()
    }
}

private struct TVStreamOverlay: View {
    @ObservedObject var coordinator: TVStreamCoordinator
    let accent: UIAccent

    var body: some View {
        ZStack {
            if coordinator.failed || coordinator.menuVisible {
                TVStreamMenuPanel(coordinator: coordinator)
                    .transition(.opacity)
            } else if !coordinator.videoActive {
                TVStreamConnectingView(coordinator: coordinator)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) { if !coordinator.failed { TVControllerNotice(videoActive: coordinator.videoActive) } }
        .overlay(alignment: coordinator.statsPosition.alignment) {
            // The menu shows the same figures, and the strip would lie over it.
            if coordinator.statsVisible, coordinator.videoActive, !coordinator.failed, !coordinator.menuVisible,
               coordinator.showsClock || !coordinator.hudItems.isEmpty { statsHUD }
        }
        .foregroundStyle(.white)
        .environment(\.openNowAccent, accent)
        .animation(.easeOut(duration: TVConsoleTheme.focusDuration), value: coordinator.failed || coordinator.menuVisible)
        .animation(.easeOut(duration: TVConsoleTheme.enterDuration), value: coordinator.videoActive)
    }

    /// One line of the figures chosen in Settings, drawn as the shell's status pill, inside the
    /// TV's title-safe area.
    private var statsHUD: some View {
        HStack(spacing: 16) {
            if coordinator.showsClock {
                TimelineView(.everyMinute) { Text($0.date.formatted(date: .omitted, time: .shortened)) }
                if !coordinator.hudItems.isEmpty { seam }
            }
            ForEach(Array(coordinator.hudItems.enumerated()), id: \.offset) { index, item in
                if index > 0 { seam }
                Text(item)
            }
        }
        .font(TVConsoleTheme.mono(15))
        .monospacedDigit()
        .foregroundStyle(TVConsoleTheme.label)
        .lineLimit(1)
        .padding(.horizontal, 22)
        .frame(height: 46)
        .tvConsoleGlass(radius: 23, strong: true)
        .padding(.horizontal, 80)
        .padding(.top, 60)
    }

    private var seam: some View {
        Rectangle().fill(TVConsoleTheme.seam).frame(width: 1, height: 18)
    }
}

/// Shown until the first frame: the queue screen's layout at its last step, so the hand-off
/// from the queue to the stream reads as one screen. Nothing on it takes focus; Back on the
/// remote, or holding Options on a controller, opens the stream menu as during play.
private struct TVStreamConnectingView: View {
    @ObservedObject var coordinator: TVStreamCoordinator
    /// Only for the hint's button symbol.
    @StateObject private var input = TVConsoleInput()
    @Environment(\.openNowAccent) private var accent

    /// A session past the queue with a rig ready to stream is at the rail's last step.
    private static let stage = TVConsoleLaunchStage(sessionStatus: 2, isPastQueue: true,
                                                    queuePosition: nil, queuePaused: false)

    var body: some View {
        TVConsoleLaunchStageView(
            game: coordinator.session.game,
            status: coordinator.status, tone: accent.color,
            eyebrow: "Starting your session",
            headline: Self.stage.headline,
            detail: Self.stage.detail,
            stage: Self.stage
        ) {
            TVConsoleRigCard(session: coordinator.session)
        } actions: {
            HStack(spacing: 22) {
                HStack(spacing: 10) {
                    TVConsoleGlyph(button: input.hasGamepad ? .options : .back)
                    Text(input.hasGamepad ? "Hold for the stream menu" : "Stream menu")
                        .font(TVConsoleTheme.display(17, weight: 800))
                        .foregroundStyle(TVConsoleTheme.label)
                }
                if !coordinator.detail.isEmpty {
                    Rectangle().fill(TVConsoleTheme.seam).frame(width: 1, height: 22)
                    // The handshake step or the requested video, for telling a stall apart.
                    Text(coordinator.detail.uppercased())
                        .font(TVConsoleTheme.mono(14))
                        .tracking(1.4)
                        .foregroundStyle(TVConsoleTheme.textMuted)
                        .lineLimit(1)
                }
            }
            .frame(height: 72)
        }
        .environmentObject(input)
        .onAppear { input.start() }
        .onDisappear { input.stop() }
    }
}

/// The stream menu and the failed-stream screen, as the console shell's sheet over the dimmed
/// game. Rows are lit from the coordinator's selection, not the focus engine: controller input
/// stays away from UIKit for the whole stream.
private struct TVStreamMenuPanel: View {
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
                Text(detail(of: item))
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

    private func detail(of item: TVStreamMenuItem) -> String {
        switch item {
        case .resume: "Back to the game"
        case .showStats: "Show the stream figures over the game"
        case .hideStats: "Hide the stream figures over the game"
        case .leftTriggerFeel, .rightTriggerFeel: "Left or Right to change · kept for this game"
        case .leave: "The game keeps running. Rejoin it from Home."
        case .endSession: "Close the game on the server"
        case .keepPlaying: coordinator.failed ? "Leave the game running on the server" : "Back to the game"
        case .confirmEndSession: "Unsaved progress may be lost"
        case .retry: "Connect to the session again"
        case .close: "Back to OpenNOW"
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

private extension TVStreamMenuItem {
    /// Ending the session closes the game on the host.
    var isDestructive: Bool { self == .endSession || self == .confirmEndSession }

    var symbol: String {
        switch self {
        case .resume, .keepPlaying: "play.fill"
        case .showStats: "chart.bar.xaxis"
        case .hideStats: "chart.bar.xaxis"
        case .leftTriggerFeel: "l2.rectangle.roundedtop.fill"
        case .rightTriggerFeel: "r2.rectangle.roundedtop.fill"
        case .leave: "rectangle.portrait.and.arrow.right"
        case .endSession, .confirmEndSession: "power"
        case .retry: "arrow.clockwise"
        case .close: "xmark"
        }
    }
}

#if DEBUG
extension TVStreamerView {
    /// `--opennow-stream-menu-preview`: the stream menu over game artwork. `=failed` shows the
    /// failed-stream panel, `=confirm` the question before ending the session, `=connecting` the
    /// screen shown until the first frame, `=hud` the stats strip over the game.
    static func menuPreview(state: String) -> some View {
        TVStreamMenuPreview(state: state)
    }
}

private struct TVStreamMenuPreview: View {
    let state: String

    @EnvironmentObject private var store: OpenNOWStore
    @StateObject private var coordinator: TVStreamCoordinator

    init(state: String) {
        self.state = state
        let game = OpenNOWStore.debugStorePreviewGames[0]
        var session = ActiveSession(id: "menu-preview", game: game, startedAt: .now, status: 2,
            queuePosition: nil, seatSetupStep: nil, serverIp: nil, mediaIp: nil, mediaPort: 0,
            signalingServer: nil, signalingUrl: nil, iceServers: [], zone: "EU Central",
            streamingBaseUrl: "", clientId: "preview", deviceId: "preview", adState: nil)
        session.gpuType = "RTX 4080"
        _coordinator = StateObject(wrappedValue: TVStreamCoordinator(session: session, settings: .default,
            membershipTier: nil, sessionHistory: nil, onStatsOverlayChange: { _ in }, onRuntimeSample: { _ in },
            onTransportStable: {}, onStreamTermination: { _ in }, onTransportFailure: {}, onClose: {},
            onRetry: state == "failed" ? {} : nil))
    }

    var body: some View {
        TVStreamHost(coordinator: coordinator, accent: store.settings.uiAccent, transparent: true)
            // An overlay of the canvas, so the aspect-filled artwork never sizes the screen.
            .background {
                Color.black.overlay {
                    if let url = OpenNOWStore.debugStorePreviewGames[0].heroImageUrl.flatMap(URL.init(string:)) {
                        CachedRemoteImage(url: url, targetPixelSize: 1920) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.black
                        } failure: {
                            Color.black
                        }
                    }
                }
                .clipped()
            }
            .ignoresSafeArea()
        .onAppear {
            guard state != "connecting" else { return }
            coordinator.installMenuPreview(failed: state == "failed")
            switch state {
            case "confirm":
                coordinator.menuItems.indices.dropFirst().forEach { _ in coordinator.handleMenu(.down) }
                coordinator.handleMenu(.activate)
            case "hud":
                coordinator.handleMenu(.activate) // Resume
            default:
                break
            }
        }
    }
}
#endif
