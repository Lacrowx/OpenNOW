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
        TVStreamHost(coordinator: coordinator)
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

    func makeUIViewController(context: Context) -> TVStreamHostController {
        TVStreamHostController(coordinator: coordinator)
    }

    func updateUIViewController(_ controller: TVStreamHostController, context: Context) {}
}

/// `GCEventViewController` keeps controller and remote buttons away from UIKit for the whole
/// stream, so B or Back reach the game or the stream menu instead of leaving the app.
private final class TVStreamHostController: GCEventViewController {
    private let coordinator: TVStreamCoordinator
    private let overlay: UIHostingController<TVStreamOverlay>
    private var displayCriteriaObserver: AnyCancellable?

    init(coordinator: TVStreamCoordinator) {
        self.coordinator = coordinator
        overlay = UIHostingController(rootView: TVStreamOverlay(coordinator: coordinator))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
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
            print("[TVStream] display criteria \(criteria == nil ? "cleared" : "set") matchContent=\(manager.isDisplayCriteriaMatchingEnabled)")
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

    var body: some View {
        ZStack {
            if coordinator.failed {
                panel {
                    Text(coordinator.status).font(.title2.bold())
                    Text(coordinator.confirmingEnd ? Self.endQuestion : coordinator.detail)
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    menuRows
                }
            } else if coordinator.menuVisible {
                panel {
                    Text(coordinator.session.game.title).font(.title2.bold())
                    if coordinator.confirmingEnd {
                        Text(Self.endQuestion)
                            .font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("Server \(serverLabel) · GPU \(gpuLabel)")
                            .font(.callout).foregroundStyle(.secondary)
                        if !coordinator.stats.isEmpty {
                            Text(coordinator.stats).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    menuRows
                    Text("Up / Down to choose · Select or A to confirm · Back or B to \(coordinator.confirmingEnd ? "go back" : "resume")")
                        .font(.footnote).foregroundStyle(.tertiary)
                }
            } else if !coordinator.videoActive {
                VStack(spacing: 16) {
                    ProgressView()
                    Text(coordinator.status).font(.headline)
                    Text(coordinator.detail).font(.callout).foregroundStyle(.secondary)
                    Text("Press Back on the remote, or hold Options on a controller for a second, to open the stream menu.")
                        .font(.footnote).foregroundStyle(.tertiary)
                }
                .padding(60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: coordinator.statsPosition.alignment) {
            if coordinator.statsVisible, coordinator.videoActive, !coordinator.failed,
               coordinator.showsClock || !coordinator.hudItems.isEmpty { statsHUD }
        }
        .foregroundStyle(.white)
    }

    private static let endQuestion = "End this session? The game closes and unsaved progress may be lost."

    /// One line of the figures chosen in Settings, inside the TV's title-safe area.
    private var statsHUD: some View {
        HStack(spacing: 14) {
            if coordinator.showsClock {
                TimelineView(.everyMinute) { Text($0.date, style: .time) }
            }
            ForEach(coordinator.hudItems, id: \.self) { Text($0) }
        }
        .font(.caption.monospacedDigit().weight(.semibold))
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(.horizontal, 80)
        .padding(.top, 60)
    }

    /// Zone the session was allocated in, with the host address when the provider reported one.
    private var serverLabel: String {
        let session = coordinator.session
        let zone = session.zone.isEmpty ? "not reported" : session.zone
        guard let address = session.serverIp, !address.isEmpty else { return zone }
        return "\(zone) (\(address))"
    }

    private var gpuLabel: String {
        let gpu = coordinator.session.gpuType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return gpu.isEmpty ? "not reported" : gpu
    }

    /// Plain rows with a highlight: selection comes from the coordinator, not the focus engine.
    private var menuRows: some View {
        VStack(spacing: 12) {
            ForEach(Array(coordinator.menuItems.enumerated()), id: \.offset) { index, item in
                Text(coordinator.title(of: item))
                    .font(.headline)
                    .foregroundStyle(index == coordinator.selection ? .black : .white)
                    .frame(maxWidth: 520)
                    .padding(.vertical, 18)
                    .background(index == coordinator.selection ? Color.white : Color.white.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 24) { content() }
            .padding(60)
            .frame(maxWidth: 900)
            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
    }
}
