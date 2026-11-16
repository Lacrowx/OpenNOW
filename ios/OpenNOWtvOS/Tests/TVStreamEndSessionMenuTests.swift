import XCTest
@testable import OpenNOWiOS

/// A session without a streaming endpoint fails as soon as the stream starts, which puts the
/// coordinator on the failed screen without a host.
@MainActor
final class TVStreamEndSessionMenuTests: XCTestCase {
    private var ended = 0

    private func failedCoordinator(canRetry: Bool = false) -> TVStreamCoordinator {
        let game = CloudGame(id: "test", title: "A Game", genre: "Cloud Game",
            platform: "STEAM", icon: "gamecontroller.fill", imageUrl: nil, launchAppId: "12345",
            launchOptions: [], uuid: nil,
            summary: nil, longDescription: nil, publisher: nil, developer: nil, releaseDate: nil,
            featureLabels: nil, tags: nil, stores: nil, playType: nil, membershipTierLabel: nil,
            catalogSectionId: nil, catalogSectionTitle: nil, contentRatings: nil)
        let session = ActiveSession(id: "session", game: game, startedAt: .now, status: 3,
            queuePosition: nil, seatSetupStep: nil, serverIp: nil, mediaIp: nil, mediaPort: 0,
            signalingServer: nil, signalingUrl: nil, iceServers: [], zone: "", streamingBaseUrl: "",
            clientId: "client", deviceId: "device", adState: nil)
        let coordinator = TVStreamCoordinator(session: session, settings: .default, membershipTier: nil,
            sessionHistory: nil, onStatsOverlayChange: { _ in }, onRuntimeSample: { _ in },
            onTransportStable: {}, onStreamTermination: { _ in }, onTransportFailure: {},
            onClose: {}, onRetry: canRetry ? {} : nil)
        coordinator.onEndSession = { [weak self] in self?.ended += 1 }
        coordinator.start()
        addTeardownBlock { @MainActor in coordinator.stop() }
        return coordinator
    }

    func testAFailedStreamOffersToEndTheSession() {
        XCTAssertTrue(failedCoordinator().failed)
        XCTAssertEqual(failedCoordinator().menuItems, [.close, .endSession])
        XCTAssertEqual(failedCoordinator(canRetry: true).menuItems, [.retry, .close, .endSession])
    }

    func testEndingAFailedStreamAsksFirst() {
        let coordinator = failedCoordinator()
        coordinator.handleMenu(.down)
        coordinator.handleMenu(.activate)
        XCTAssertEqual(coordinator.menuItems, [.keepPlaying, .confirmEndSession])
        XCTAssertEqual(coordinator.selection, 0)
        XCTAssertEqual(coordinator.title(of: .keepPlaying), "Keep Session")
        XCTAssertEqual(ended, 0)
    }

    func testBackAndKeepSessionReturnToTheFailedScreenWithoutEnding() {
        for command in [NativeStreamControllerHUDCommand.back, .activate] {
            let coordinator = failedCoordinator()
            coordinator.handleMenu(.down)
            coordinator.handleMenu(.activate)
            coordinator.handleMenu(command)
            XCTAssertEqual(coordinator.menuItems, [.close, .endSession])
            XCTAssertEqual(coordinator.selection, 1)
        }
        XCTAssertEqual(ended, 0)
    }

    func testConfirmingEndsTheSessionOnce() {
        let coordinator = failedCoordinator()
        coordinator.handleMenu(.down)
        coordinator.handleMenu(.activate)
        coordinator.handleMenu(.down)
        coordinator.handleMenu(.activate)
        coordinator.handleMenu(.activate)
        XCTAssertEqual(ended, 1)
    }
}
