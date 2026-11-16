import XCTest
@testable import OpenNOWiOS

final class TVConsoleFailureNoticeTests: XCTestCase {
    private func failure(_ kind: OpenNOWFailure.Kind, _ message: String = "Something specific.") -> OpenNOWFailure {
        OpenNOWFailure(kind: kind, message: message, recovery: .none, code: nil)
    }

    private func make(_ failure: OpenNOWFailure, queue: Bool = false, rejoin: Bool = false,
                      signedIn: Bool = true) -> TVConsoleFailureNotice? {
        TVConsoleFailureNotice.make(failure: failure, queueScreenVisible: queue, rejoinScreenVisible: rejoin,
                                    isSignedIn: signedIn)
    }

    func testAPlainFailureShowsItsMessageWithOneOKButton() {
        let notice = make(failure(.capacity, "All rigs in this region are busy right now."))
        XCTAssertEqual(notice?.message, "All rigs in this region are busy right now.")
        XCTAssertEqual(notice?.title, "No rigs available")
        XCTAssertEqual(notice?.buttons, [.dismiss])
        XCTAssertEqual(notice?.title(for: .dismiss), "OK")
    }

    func testNothingShowsWhileAScreenAlreadyShowsTheFailure() {
        XCTAssertNil(make(failure(.offline), queue: true))
        XCTAssertNil(make(failure(.offline), rejoin: true))
        XCTAssertNil(make(failure(.authExpired), queue: true))
    }

    func testAnEmptyMessageShowsNothing() {
        XCTAssertNil(make(failure(.unknown, "")))
    }

    func testAnExpiredLoginOffersSignInAgainNextToADismiss() {
        let notice = make(failure(.authExpired))
        XCTAssertEqual(notice?.buttons, [.signInAgain, .dismiss])
        XCTAssertEqual(notice?.title, "Your sign-in has expired")
        XCTAssertEqual(notice?.title(for: .signInAgain), "Sign in again")
        XCTAssertEqual(notice?.title(for: .dismiss), "Not now")
    }

    func testAnExpiredLoginShowsNothingOnceSignedOut() {
        XCTAssertNil(make(failure(.authExpired), signedIn: false))
    }

    func testOtherFailuresNeverOfferSignIn() {
        for kind in [OpenNOWFailure.Kind.offline, .timeout, .notEntitled, .sessionLimit, .capacity,
                     .maintenance, .transportLost, .rejected, .unknown] {
            XCTAssertEqual(make(failure(kind))?.buttons, [.dismiss], "\(kind)")
        }
    }
}
