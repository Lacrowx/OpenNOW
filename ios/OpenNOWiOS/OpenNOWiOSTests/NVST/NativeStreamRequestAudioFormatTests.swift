import Foundation
import Testing
@testable import OpenNOWiOS

/// The native session request carries the surround format the session and claim bodies asked for.
struct NativeStreamRequestAudioFormatTests {
    private func nativeRequest(_ request: [String: Any]) throws -> [String: Any] {
        let result = NativeStreamNVSTConfiguration.requestBody(["sessionRequestData": request], enabled: true)
        return try #require(result["sessionRequestData"] as? [String: Any])
    }

    @Test(arguments: [2, 3])
    func aSurroundFormatIsKept(format: Int) throws {
        let request = try nativeRequest(["requestedAudioFormat": format, "secureRTSPSupported": false])
        #expect(request["requestedAudioFormat"] as? Int == format)
    }

    @Test func aStereoRequestStillSendsZero() throws {
        let request = try nativeRequest(["secureRTSPSupported": false])
        #expect(request["requestedAudioFormat"] as? Int == 0)
    }
}
