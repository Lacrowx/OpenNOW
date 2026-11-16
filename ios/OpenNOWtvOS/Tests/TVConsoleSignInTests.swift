import XCTest
@testable import OpenNOWiOS

final class TVConsoleSignInTests: XCTestCase {
    private func signIn(code: String? = "NVIDIA", name: String = "NVIDIA", hasCode: Bool = false,
                        busy: Bool = false, error: String? = nil, phase: String? = nil) -> TVConsoleSignIn {
        TVConsoleSignIn(providerCode: code, providerName: name, hasCode: hasCode,
                        isAuthenticating: busy, error: error, phase: phase)
    }

    func testNVIDIALeadsWithTheQRCode() {
        XCTAssertEqual(signIn().buttons, [.qrCode, .signIn, .provider])
        XCTAssertEqual(signIn(code: "nvidia").buttons, [.qrCode, .signIn, .provider])
        XCTAssertEqual(signIn(code: nil).buttons, [.qrCode, .signIn, .provider])
    }

    func testOtherProvidersHaveNoQRCodeAndSignInIsPrimary() {
        let other = signIn(code: "KDD", name: "au Cloud Gaming")
        XCTAssertEqual(other.buttons, [.signIn, .provider])
        XCTAssertEqual(other.title(for: .signIn), "Sign In with au Cloud Gaming")
        XCTAssertEqual(other.title(for: .provider), "Provider · au Cloud Gaming")
    }

    func testWhileACodeIsShownOnlyCancelIsOffered() {
        let shown = signIn(hasCode: true, busy: true)
        XCTAssertEqual(shown.buttons, [.cancel])
        XCTAssertTrue(shown.isEnabled(.cancel))
        XCTAssertEqual(shown.title(for: .cancel), "Cancel this sign-in")
    }

    func testConnectingDisablesTheButtonsAndRenamesThePrimaryOne() {
        let nvidia = signIn(busy: true)
        XCTAssertEqual(nvidia.title(for: .qrCode), "Connecting")
        XCTAssertEqual(nvidia.title(for: .signIn), "Sign In with NVIDIA")
        XCTAssertFalse(nvidia.isEnabled(.qrCode))
        XCTAssertFalse(nvidia.isEnabled(.provider))
        let other = signIn(code: "KDD", name: "au", busy: true)
        XCTAssertEqual(other.title(for: .signIn), "Connecting")
        XCTAssertTrue(signIn().isEnabled(.qrCode))
    }

    func testStatusPrefersTheErrorThenThePhase() {
        XCTAssertEqual(signIn().statusText, "No password is entered in OpenNOW")
        XCTAssertFalse(signIn().statusIsError)
        XCTAssertEqual(signIn(phase: "Waiting for approval").statusText, "Waiting for approval")
        let failed = signIn(error: "Sign-in expired", phase: "Waiting for approval")
        XCTAssertEqual(failed.statusText, "Sign-in expired")
        XCTAssertTrue(failed.statusIsError)
    }

    func testCountdownRoundsUpAndStopsAtZero() {
        let end = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(TVConsoleSignIn.countdown(until: end, now: end.addingTimeInterval(-300)), "5:00")
        XCTAssertEqual(TVConsoleSignIn.countdown(until: end, now: end.addingTimeInterval(-59.2)), "1:00")
        XCTAssertEqual(TVConsoleSignIn.countdown(until: end, now: end.addingTimeInterval(-9)), "0:09")
        XCTAssertEqual(TVConsoleSignIn.countdown(until: end, now: end.addingTimeInterval(30)), "0:00")
    }

    func testHostTextDropsTheSchemeAndTheQuery() {
        XCTAssertEqual(TVConsoleSignIn.hostText(for: URL(string: "https://www.nvidia.com/link")!), "www.nvidia.com/link")
        XCTAssertEqual(TVConsoleSignIn.hostText(for: URL(string: "https://login.example.com/pin?user_code=1234")!),
                       "login.example.com/pin")
    }
}
