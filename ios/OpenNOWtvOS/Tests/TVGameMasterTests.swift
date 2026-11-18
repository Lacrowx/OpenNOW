import XCTest
@testable import OpenNOWiOS

final class TVGameMasterTests: XCTestCase {
    // MARK: ADB packets

    func testConnectPacketMatchesTheWireFormat() {
        let packet = TVAdbMessage(command: .connect, arg0: TVAdbMessage.version, arg1: TVAdbMessage.maxPayload,
                                  payload: TVAdbMessage.cString("host::")).encoded()
        XCTAssertEqual(packet.count, 24 + 7)
        XCTAssertEqual(Array(packet.prefix(4)), Array("CNXN".utf8))
        XCTAssertEqual(Array(packet[4..<8]), [0x01, 0x00, 0x00, 0x01])
        // Checksum: the byte sum of "host::\0"; magic: the command with every bit flipped.
        XCTAssertEqual(Array(packet[16..<20]), [0x32, 0x02, 0x00, 0x00])
        XCTAssertEqual(Array(packet[20..<24]), [0xbc, 0xb1, 0xa7, 0xb1])
    }

    func testHeaderRoundTrips() throws {
        let packet = TVAdbMessage(command: .write, arg0: 7, arg1: 1, payload: Data([1, 2, 3])).encoded()
        let header = try TVAdbMessage.decodeHeader(packet.prefix(24))
        XCTAssertEqual(header, .init(command: TVAdbMessage.Command.write.rawValue, arg0: 7, arg1: 1, length: 3))
    }

    func testHeaderWithBadMagicIsRejected() {
        var packet = TVAdbMessage(command: .okay, arg0: 1, arg1: 2).encoded()
        packet[23] ^= 0xff
        XCTAssertThrowsError(try TVAdbMessage.decodeHeader(packet.prefix(24))) {
            XCTAssertEqual($0 as? TVAdbMessage.DecodeError, .badMagic)
        }
    }

    // MARK: Key

    /// A throwaway key made with `adb keygen` (never approved anywhere) and adb's own public form of it.
    private static let testKeyDER = "MIIEowIBAAKCAQEApxMrqyOexpydZp0QID7MJLkaYFIm2BiS41FEwo/vbzK7mshW9H1Uxhq0utIN8VzJYp7qaKuYs7/2Qwtd6vHGs6LMiD+Pmg3fJm7fIn33iUDzYAYOCOlUNUuv8WWR5njyLfwLijfgHxlkO1pun9xlYzV50fuXNxRMh1EVR2vF0sQutthdqZWd51J7otg34hdpFjWwP5jQqR7tGM6GTBZNLv048774P2J5kuEHT2cvHorKe4JJICZOwp0K5vDC7OhnXLGxaLhL1g6HNPsO8Ooa3f8SGPV0evc5ZYJ2mYD845mcZNx5YFsY9hZCC25pQLMHn+eqDB80cudFifvkY3zDBQIDAQABAoIBAAusYDm15GsWGD1KLg1Ctfq+4CPouYQRu3mcfQRnECCh18/JvaGZfCnXRddjw8ugYwW7+r7TdnjgqbEngyleOTbl4gqG/l6SJ4xE5NxBFuGFIzwLUEG5I8QRhLqGETqcKrehy6CdpNAncwRenioXORJEcz2DqZ4UkgBGXwk9c3X1WDFWnV6W7Gww9CgbbAhkyZMnKsmnxjqT/u0APHgehozvpgh8OVuQrSEDy6nUFSFd2hOJ7f3aa/yCYhtwb0hy0tbFbzo8So4BXauUGtzTIjROZzgRNZO3ftYmbk3XriD13Vug9UzZHGFcXaL6oARRA18H2Ns7rixnE7VVcp/OBkECgYEA1ESPQO7TwrJDA9VL4gjgbWpDpMX6ZgFUn2gyDU726gUndWp7pSHP4zu2Zjxyo7qutp8hFwo+ht27Z2WrT0WEO9TWm1e8/l1k805EyX/JZViQZfPJkLkLxPTKENgXawuVnQ+huMPzVwWPYHpJRY31vxzUp5+JTgmOVInKLEK8OnECgYEAyX8LEkNvOXXyp/3gMEn9dMU65T6MlrDVri+uAFIaJoiy4RqNTIe9JmAPXUeFvQK/4B/qXN3rQY1r60zMw2JlRal/LKvfP7OX34wK8kFwYCBDCQl5LHD2NstUzQ6fEx8vpK3v1ycIXeUUfqXCoX49m7MkdXokGxJXbPr8cRyF09UCgYB3yMSqWNvJF/13UUuEH4w+UmQfvNUj8QZG+m6cUf5Ga2gr+04RDraYvZ6drOjoejWTutLahJ5qTwAtRhNZJZqMhPwiJ23wgNWx824f42vMNCEwV1VcxP/eQmExBjCY6K2iNysE8BcG+Y1CXV+xz31pPqTGfuHl1sCp9iPPvE0qEQKBgFQYSa6dplX8/AFQ27hLqRSLHEGBEXvy4buI+r33hiJ++ukoA8DlBfR2MvNjXlW8SAhqSY3osL7zHw9dRjhlYI7qZsFmGg6kDcam1Aq3dQcpb9Ddu0zo+Fl2EzZh29JHOcMpNOg+yicl7J/O3qQ3486Pva+qAleqGALL3X/3v4LhAoGBAL3IAo/LdEo6NPhhskxCOF2zsb5r9UTzbuEGbiCjyBRgPdl7ynwqdWzYIKs+St3ucmDIxbw69T8ltMEYm86cSbrnCCNZVm/+T9FU14JJkQRZujeyq51cbnGwzUGkkH5lHeHxFqmevIuY8VQPXiaqcjAcDbk5x1qEnuX7JqHTYNkA"
    private static let testKeyAdbPublic = "QAAAADNuRZoFw3xj5PuJRedyNB8MquefB7NAaW4LQhb2GFtgedxknJnj/ICZdoJlOfd6dPUYEv/dGurwDvs0hw7WS7hosbFcZ+jswvDmCp3CTiYgSYJ7yooeL2dPB+GSeWI/+L7zOP0uTRZMhs4Y7R6p0Jg/sDUWaRfiN9iie1LnnZWpXdi2LsTSxWtHFVGHTBQ3l/vReTVjZdyfblo7ZBkf4DeKC/wt8njmkWXxr0s1VOkIDgZg80CJ930i324m3w2ajz+IzKKzxvHqXQtD9r+zmKto6p5iyVzxDdK6tBrGVH30VsiauzJv74/CRFHjkhjYJlJgGrkkzD4gEJ1mnZzGniOrKxOnmjISn/W9oABudNJtvd0TxVfVXA6pGJahSz7ZzTcYdXhD9fujxLz59XOV9ZvDgPH7+cZMDZfunS38PTiuw3288htS7uc/yvtMLnXcTSD/VV2T4SGAnVTeY3vnLXci8YwdfGKivOXjZiYHUt/SsGNPrBEHQ0uIZq3uDnovxdFNSMWpB2p/qOBDK6Pytq8jZMIxdeM+OWlGKsZuB3o/r0QWXlv4nAh6W409URIc+GIxiGnBrzGECLYIINPhcm9NFMgamAMuH8iv2pdFZ1opmsT1NP9pmG0bU3Dy9N3y4S2tVCEIly3h/ibCEFZhAp08uofg70nxIMLCxnTdWQMfS5iggAEAAQA="

    func testPublicKeyMatchesAdb() throws {
        let key = try TVAdbKey(der: try XCTUnwrap(Data(base64Encoded: Self.testKeyDER)))
        XCTAssertEqual(try key.androidPublicKey(name: "OpenNOW@AppleTV"), Self.testKeyAdbPublic + " OpenNOW@AppleTV")
    }

    func testKeySurvivesStorage() throws {
        let key = try TVAdbKey()
        let restored = try TVAdbKey(der: try key.derRepresentation())
        XCTAssertEqual(try restored.androidPublicKey(name: "x"), try key.androidPublicKey(name: "x"))
        XCTAssertEqual(try key.signToken(Data(repeating: 7, count: 20)).count, 256)
    }

    // MARK: TCL Game Master

    func testServiceCallResultIsRead() {
        XCTAssertEqual(TVGameMaster.parcelInt("Result: Parcel(\t00000000 00000002   '........')\n"), 2)
        XCTAssertEqual(TVGameMaster.parcelInt("Result: Parcel(00000000 00000001   '........')"), 1)
        // A nonzero first word is an exception from the service.
        XCTAssertNil(TVGameMaster.parcelInt("Result: Parcel(ffffffff 00000000 'error')"))
        XCTAssertNil(TVGameMaster.parcelInt("service: not found"))
    }

    func testInputsMapToTCLSources() {
        XCTAssertEqual(TVGameMaster.Input(deviceID: 15)?.number, 1)
        XCTAssertEqual(TVGameMaster.Input(deviceID: 15)?.source, 8)
        XCTAssertEqual(TVGameMaster.Input(deviceID: 18)?.source, 11)
        XCTAssertNil(TVGameMaster.Input(deviceID: 21))
    }

    func testWriteSetsTheServiceAndTheMenuMirror() throws {
        let hdmi2 = try XCTUnwrap(TVGameMaster.Input(number: 2))
        XCTAssertEqual(TVGameMaster.writeCommand(hdmi2, .on),
                       "service call tcl_tv_display 159 i32 9 i32 1 i32 2 && settings put global GAME_MODE_HDMI_2 1")
        XCTAssertEqual(TVGameMaster.writeCommand(hdmi2, .auto).suffix(1), "0")
        XCTAssertEqual(TVGameMaster.writeCommand(hdmi2, .off).suffix(1), "2")
    }
}
