import Foundation
import Testing
@testable import OpenNOWiOS

/// The raw-HID codec, byte for byte as the official client's `RiClientBackend` writes it and
/// `ServerControl::handleServerCommand` reads it. See `NvstHidPassthrough`.
@Suite struct NvstHidPassthroughTests {
    typealias DualShock4 = NvstHidPassthrough.SynthesizedDualShock4

    @Test func changeEventIsA14ByteBigEndianBodyUnderType0x12() {
        let event = NvstHidPassthrough.ChangeEvent(deviceId: 2, change: .added, flags: 0x0000_0001, vendorId: 0x054c, productId: 0x09cc, field3: 0x0100, field4: 0x0005)
        let packet = [UInt8](event.packet)
        // [u32 BE len 18][u32 LE type 0x12][body]
        #expect(Array(packet[0..<8]) == [0x00, 0x00, 0x00, 0x12, 0x12, 0x00, 0x00, 0x00])
        #expect(Array(packet[8...]) == [0x02, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x4c, 0x09, 0xcc, 0x01, 0x00, 0x00, 0x05])
        #expect([UInt8](event.event) == Array(packet[4...]))
        #expect(NvstHidPassthrough.ChangeEvent(event: event.event) == event)
    }

    @Test func removalUsesControlThree() {
        let packet = [UInt8](NvstHidPassthrough.ChangeEvent(deviceId: 0, change: .removed, vendorId: 1, productId: 2).packet)
        #expect(packet[9] == 0x03)
    }

    /// `handlePrSequenceNumber<10>` is called with an offset of four, so device 6 is index 10.
    @Test func partiallyReliableReportIndexesTheDeviceAfterTheFourGamepads() {
        let report = NvstHidPassthrough.Report(deviceId: 6, kind: 4, reportType: 0, data: Data([0xaa, 0xbb, 0xcc]))
        let command = report.command(sequence: 0x0102, timestampMicroseconds: 0x0000_0000_0001_0000)
        #expect(command.code == .gamepadEvent)
        let bytes = [UInt8](command.payload)
        #expect(bytes[0] == 0x23)
        #expect(Array(bytes[1..<9]) == [0, 0, 0, 0, 0, 1, 0, 0])
        #expect(bytes[9] == 0x26)
        #expect(bytes[10] == 10)
        #expect(Array(bytes[11..<13]) == [0x01, 0x02])
        #expect(bytes[13] == 0x21)
        // 7-byte event header + 3 data bytes.
        #expect(Array(bytes[14..<16]) == [0x00, 0x0a])
        #expect(Array(bytes[16...]) == [0x11, 0x00, 0x00, 0x00, 0x06, 0x04, 0x00, 0xaa, 0xbb, 0xcc])
    }

    @Test func reliableReportIsTheBareEventBehindTheSingleTag() {
        let report = NvstHidPassthrough.Report(deviceId: 6, kind: 4, reportType: 0, data: Data([0xaa]))
        let bytes = [UInt8](report.payload(sequence: nil, timestampMicroseconds: 1))
        #expect(Array(bytes[0..<10]) == [0x23, 0, 0, 0, 0, 0, 0, 0, 1, 0x22])
        #expect(Array(bytes[10...]) == [0x11, 0x00, 0x00, 0x00, 0x06, 0x04, 0x00, 0xaa])
        #expect(NvstHidPassthrough.Report(event: Data(bytes[10...])) == report)
    }

    @Test func outputReportParsesFromTheRemoteInputCommand() {
        let payload = Data([0x11, 0, 0, 0, 0x02, 0x00, 0x02, 0x05, 0x11, 0x22])
        let report = NvstHidPassthrough.parseOutputReport(NvstControlCommand(code: .remoteInput, payload: payload))
        #expect(report == NvstHidPassthrough.Report(deviceId: 2, kind: 0, reportType: 2, data: Data([0x05, 0x11, 0x22])))
    }

    /// The official dispatcher's own guard: fewer than seven bytes is "Corrupted ... PACKET_HID".
    @Test func shortOrForeignPayloadsAreNotOutputReports() {
        #expect(NvstHidPassthrough.parseOutputReport(NvstControlCommand(code: .remoteInput, payload: Data([0x11, 0, 0, 0, 1, 2]))) == nil)
        #expect(NvstHidPassthrough.parseOutputReport(NvstControlCommand(code: .remoteInput, payload: Data([0x1a, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7]))) == nil)
        #expect(NvstHidPassthrough.parseOutputReport(NvstControlCommand(code: .hapticEvent, payload: Data([0x11, 0, 0, 0, 1, 2, 3]))) == nil)
    }

    /// `handleServerCommand` case `0x1a`: the request id first, the assigned device id last.
    @Test func changeResponseParses() {
        func response(_ bytes: [UInt8]) -> NvstHidPassthrough.ChangeResponse? {
            NvstHidPassthrough.ChangeResponse.parse(NvstControlCommand(code: .remoteInput, payload: Data(bytes)))
        }
        let accepted = response([0x1a, 0, 0, 0, 0x0a, 0x01, 0x00, 0x00, 0x00, 0x0f, 0x0b])
        #expect(accepted == NvstHidPassthrough.ChangeResponse(requestId: 10, status: 1, flags: 0xf, deviceId: 11))
        #expect(accepted?.isAccepted == true)
        // `HIDDevice::start(0xff)` disallows the device; a status other than 1 does too.
        #expect(response([0x1a, 0, 0, 0, 0x0a, 0x01, 0, 0, 0, 0x0f, 0xff])?.isAccepted == false)
        #expect(response([0x1a, 0, 0, 0, 0x0a, 0x00, 0, 0, 0, 0x0f, 0x0b])?.isAccepted == false)
    }

    /// `applyServerHidCapabilities`: DS4 is bit 2, DS5 is bit 1.
    @Test func seatCapabilityBits() {
        let dualShock4Only = NvstHidPassthrough.SeatCapability(raw: 0x4, partiallyReliableDevices: 1 << 6)
        #expect(dualShock4Only.supportsDualShock4 && !dualShock4Only.supportsDualSense)
        #expect(dualShock4Only.usesPartiallyReliableTransfer(deviceId: 6))
        #expect(!dualShock4Only.usesPartiallyReliableTransfer(deviceId: 7))
        let dualSenseOnly = NvstHidPassthrough.SeatCapability(raw: 0x2)
        #expect(dualSenseOnly.supportsDualSense && !dualSenseOnly.supportsDualShock4)
        #expect(!NvstHidPassthrough.SeatCapability(raw: 0x1).supportsDualShock4)
        // `handlePrSequenceNumber<10>` has ten slots: a seat-assigned id of 10 or more is reliable.
        let everything = NvstHidPassthrough.SeatCapability(raw: 0x6, partiallyReliableDevices: 0xffff_ffff)
        #expect(everything.usesPartiallyReliableTransfer(deviceId: 9))
        #expect(!everything.usesPartiallyReliableTransfer(deviceId: 10))
    }

    /// `sendSynthesizedHidDevices`: device id 6 + slot, flags 1, no vendor or product.
    @Test func synthesizedPadIsAnnouncedByIdAndFlagAlone() {
        let added = DualShock4.changeEvent(gamepadIndex: 1, connected: true)
        #expect(added == NvstHidPassthrough.ChangeEvent(deviceId: 7, change: .added, flags: 1, vendorId: 0, productId: 0))
        #expect(DualShock4.changeEvent(gamepadIndex: 0, connected: false).change == .removed)
        #expect(DualShock4.gamepadIndex(deviceId: 9) == 3)
        #expect(DualShock4.gamepadIndex(deviceId: 5) == nil)
        #expect(DualShock4.gamepadIndex(deviceId: 10) == nil)
    }

    @Test func idleReportIsTheSynthesizersNeutralDualShock4() {
        let idle = DualShock4.State(buttons: 0, leftTrigger: 0, rightTrigger: 0, leftStickX: 0, leftStickY: 0, rightStickX: 0, rightStickY: 0)
        let report = DualShock4.report(idle, gamepadIndex: 0, timestampMicroseconds: 16)
        #expect(report.deviceId == 6 && report.kind == 4 && report.reportType == 0)
        var expected = [UInt8](repeating: 0, count: 64)
        expected[0] = 0x01
        expected[1] = 0x80; expected[2] = 0x80; expected[3] = 0x80; expected[4] = 0x80
        expected[5] = 0x08
        expected[10] = 3
        expected[30] = 0x1b
        expected[33] = 1
        expected[35] = 0x80
        expected[39] = 0x80
        #expect([UInt8](report.data) == expected)
    }

    @Test func reportMapsXInputStateOntoDualShock4Fields() {
        typealias Button = NvstGamepadPacket.Button
        let state = DualShock4.State(
            buttons: Button.dPadUp | Button.dPadRight | Button.a | Button.y | Button.leftShoulder | Button.back
                | Button.start | Button.rightThumb | Button.guide,
            leftTrigger: 0, rightTrigger: 0xc8,
            leftStickX: 32767, leftStickY: 32767, rightStickX: -32768, rightStickY: -32768,
            touchpadPressed: true)
        let data = [UInt8](DualShock4.report(state, gamepadIndex: 2, timestampMicroseconds: 0).data)
        // Right and up on the left stick, left and down on the right one: DS4 Y grows downward.
        #expect(Array(data[1...4]) == [0xff, 0x00, 0x00, 0xff])
        // North-east hat, cross and triangle.
        #expect(data[5] == 0x01 | 0x20 | 0x80)
        // L1, R2 (from its analog value), share, options, R3.
        #expect(data[6] == 0x01 | 0x08 | 0x10 | 0x20 | 0x80)
        #expect(data[7] == 0x03)
        #expect(data[8] == 0 && data[9] == 0xc8)
    }

    @Test func hatCoversEveryDirectionAndCancelsOpposites() {
        let up: UInt16 = 0x1, down: UInt16 = 0x2, left: UInt16 = 0x4, right: UInt16 = 0x8
        #expect([up, up | right, right, down | right, down, down | left, left, up | left].map(DualShock4.hat(dPad:)) == [0, 1, 2, 3, 4, 5, 6, 7])
        #expect(DualShock4.hat(dPad: 0) == 8)
        #expect(DualShock4.hat(dPad: up | down) == 8)
        #expect(DualShock4.hat(dPad: left | right | down) == 4)
    }

    /// `parseGamepadHidOutput`: report 0x05 with the rumble flag, weak motor at 4, strong at 5.
    @Test func rumbleComesFromTheSynthesizedPadsOutputReport() {
        let output = NvstHidPassthrough.Report(deviceId: 7, kind: 0, reportType: 2, data: Data([0x05, 0x01, 0x00, 0x00, 0x40, 0xff, 0, 0, 0]))
        #expect(DualShock4.rumble(in: output) == NvstHapticEvent(gamepadIndex: 1, leftMotor: 0xff00, rightMotor: 0x4000))
        let lightBarOnly = NvstHidPassthrough.Report(deviceId: 7, kind: 0, reportType: 2, data: Data([0x05, 0x02, 0x00, 0x00, 0x40, 0xff]))
        #expect(DualShock4.rumble(in: lightBarOnly) == nil)
        let otherDevice = NvstHidPassthrough.Report(deviceId: 2, kind: 0, reportType: 2, data: Data([0x05, 0x01, 0x00, 0x00, 0x40, 0xff]))
        #expect(DualShock4.rumble(in: otherDevice) == nil)
    }

    /// The input bridge hands the transport the bare events; the translator has to give them back.
    @Test func translatorRecognisesBothHidEvents() throws {
        let report = DualShock4.report(.init(buttons: 0, leftTrigger: 0, rightTrigger: 0, leftStickX: 0, leftStickY: 0, rightStickX: 0, rightStickY: 0),
                                       gamepadIndex: 0, timestampMicroseconds: 0)
        let outputs = try NativeStreamNVSTInput.translate(report.event, timestamp: 0, sequence: 0)
        guard case .hidReport(let translated)? = outputs.first else { Issue.record("not a HID report"); return }
        #expect(translated == report)

        let removal = DualShock4.changeEvent(gamepadIndex: 0, connected: false)
        guard case .hidChange(let change)? = try NativeStreamNVSTInput.translate(removal.event, timestamp: 0, sequence: 0).first else {
            Issue.record("not a HID change"); return
        }
        #expect(change == removal)
    }

    // MARK: DualSense

    typealias DualSense = NvstHidPassthrough.DualSense

    /// `HIDDevicesController::devicesConnected`: request id 10 + n, flags 0xf, vendor, product,
    /// release number and a zero word.
    @Test func dualSenseIsAnnouncedWithItsUsbIdentityUnderARequestId() {
        let add = DualSense.changeEvent(gamepadIndex: 1)
        #expect(Array([UInt8](add.packet)[8...]) == [0x0b, 0x01, 0x00, 0x00, 0x00, 0x0f, 0x05, 0x4c, 0x0c, 0xe6, 0x01, 0x00, 0x00, 0x00])
        #expect(DualSense.gamepadIndex(requestId: 11) == 1)
        #expect(DualSense.gamepadIndex(requestId: 9) == nil && DualSense.gamepadIndex(requestId: 14) == nil)
        let removal = DualSense.removalEvent(deviceId: 0x20)
        #expect(Array([UInt8](removal.packet)[8...]) == [0x20, 0x03, 0x00, 0x00, 0x00, 0x0f, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    /// USB input report 0x01 as `TransformPacketDS5::transformInput` expects it: the sequence
    /// number at 7 and the sensor timestamp, a third of a microsecond per tick, at 0x1c.
    @Test func dualSenseInputReportLayout() {
        typealias Button = NvstGamepadPacket.Button
        let state = DualSense.State(buttons: 0x0001 | Button.a | Button.leftShoulder | Button.guide, leftTrigger: 0x40, rightTrigger: 0xff,
                                    leftStickX: 32767, leftStickY: 32767, rightStickX: -32768, rightStickY: 0, touchpadPressed: true)
        let report = DualSense.report(state, gamepadIndex: 1, sequence: 0x7f, timestampMicroseconds: 0x1_0000)
        #expect(report.deviceId == 11 && report.kind == 3 && report.reportType == 0)
        let data = [UInt8](report.data)
        #expect(data.count == 64)
        #expect(Array(data[0..<11]) == [0x01, 0xff, 0x00, 0x00, 0x80, 0x40, 0xff, 0x7f, 0x20, 0x0d, 0x03])
        #expect(Array(data[28..<32]) == [0x00, 0x00, 0x03, 0x00])
        // Both touch points up.
        #expect(data[33] == 0x80 && data[37] == 0x80)
        // Charged, on a cable.
        #expect(data[53] == 0x2a)
        let filled = Set(Array(0...10) + Array(28...31) + [33, 37, 53])
        #expect(data.indices.allSatisfy { filled.contains($0) || data[$0] == 0 })
    }

    @Test func dualSenseOutputReportCarriesRumbleAndBothTriggerEffects() {
        var data = [UInt8](repeating: 0, count: 48)
        data[0] = 0x02
        data[1] = 0x01 | 0x02 | 0x04 | 0x08
        data[3] = 0x40
        data[4] = 0xff
        // Right trigger: weapon between zones 2 and 5 at full strength.
        data[11...14] = [0x25, 0x24, 0x00, 0x07]
        // Left trigger: vibration from zone 4 on, amplitude 4 of 8, 128 Hz.
        data[22...28] = [0x26, 0xf0, 0x03, 0x00, 0xb0, 0x6d, 0x1b]
        data[31] = 0x80
        let output = DualSense.output(in: NvstHidPassthrough.Report(deviceId: 11, kind: 0, reportType: 0, data: Data(data)))
        #expect(output?.rumble == DualSense.Rumble(weak: 0x40, strong: 0xff))
        #expect(output?.rightTrigger == .weapon(start: 2.0 / 9, end: 5.0 / 9, strength: 1))
        #expect(output?.leftTrigger == .vibration(amplitudes: [0, 0, 0, 0, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5], frequency: 128.0 / 255))
    }

    /// Fields whose valid bit is clear keep whatever the pad is doing.
    @Test func dualSenseOutputReportLeavesUnflaggedFieldsAlone() {
        var data = [UInt8](repeating: 0, count: 48)
        data[0] = 0x02
        data[1] = 0x04
        data[3] = 0x40
        data[11] = 0x05
        let output = DualSense.output(in: NvstHidPassthrough.Report(deviceId: 11, kind: 0, reportType: 1, data: Data(data)))
        #expect(output == DualSense.Output(rumble: nil, rightTrigger: .off, leftTrigger: nil))
        // Newer firmware flags rumble in the second flag block instead.
        data[1] = 0
        data[39] = 0x04
        #expect(DualSense.output(in: .init(deviceId: 11, reportType: 0, data: Data(data)))?.rumble == DualSense.Rumble(weak: 0x40, strong: 0))
        // Not an output report for the pad: a feature write, another report id, a short one.
        #expect(DualSense.output(in: .init(deviceId: 11, reportType: 4, data: Data(data))) == nil)
        #expect(DualSense.output(in: .init(deviceId: 11, reportType: 0, data: Data([0x05] + data.dropFirst()))) == nil)
        #expect(DualSense.output(in: .init(deviceId: 11, reportType: 0, data: Data(data.prefix(20)))) == nil)
    }

    @Test func dualSenseTriggerEffectModes() {
        func effect(_ bytes: [UInt8]) -> DualSense.TriggerEffect {
            DualSense.TriggerEffect(bytes: bytes + [UInt8](repeating: 0, count: 11 - bytes.count))
        }
        #expect(effect([0x05]) == .off)
        #expect(effect([0x00]) == .off)
        // Zones 0 and 9 active with strengths 1 and 8 of 8.
        #expect(effect([0x21, 0x01, 0x02, 0x00, 0x00, 0x00, 0x38]) == .feedback(strengths: [0.125, 0, 0, 0, 0, 0, 0, 0, 0, 1]))
        #expect(effect([0x25, 0x24, 0x00, 0x03]) == .weapon(start: 2.0 / 9, end: 5.0 / 9, strength: 0.5))
        // The positional forms of the same three effects.
        #expect(effect([0x01, 0x80, 0xff]) == .feedback(strengths: [0, 0, 0, 0, 0, 1, 1, 1, 1, 1]))
        #expect(effect([0x02, 0x33, 0x66, 0xff]) == .weapon(start: 0.2, end: 0.4, strength: 1))
        #expect(effect([0x06, 0x80, 0xff, 0x80]) == .vibration(amplitudes: [0, 0, 0, 0, 0, 1, 1, 1, 1, 1], frequency: 128.0 / 255))
        // Effects Game Controller has no call for end as no effect.
        #expect(effect([0x22, 0x24, 0x00, 0x3f]) == .off)
    }

    /// Body rumble played on the triggers: the stronger motor sets the level, to the nearest of
    /// the pad's eighths, which motor leads sets the pitch, and a trigger that is not pulled at
    /// least a third of the way stays still.
    @Test func rumbleMirroredOntoTheTriggers() {
        typealias Effect = DualSense.TriggerEffect
        func pulled(_ level: Float) -> [Float] { [0, 0, 0] + [Float](repeating: level, count: 7) }
        #expect(Effect.mirroringRumble(weak: 0, strong: 0) == .off)
        #expect(Effect.mirroringRumble(weak: 0.5, strong: 1) == .vibration(amplitudes: pulled(1), frequency: 25.0 / 255))
        #expect(Effect.mirroringRumble(weak: 0.3, strong: 0.1) == .vibration(amplitudes: pulled(0.25), frequency: 60.0 / 255))
        #expect(Effect.mirroringRumble(weak: 4, strong: -1) == .vibration(amplitudes: pulled(1), frequency: 60.0 / 255))
        // A motor value too low to turn a real motor does not shake the triggers either.
        #expect(Effect.mirroringRumble(weak: 0, strong: 0.05) == .off)
        #expect(Effect.mirroringRumble(weak: 0, strong: 0.07) == .vibration(amplitudes: pulled(0.125), frequency: 25.0 / 255))
    }

    /// The user's trigger strength scales the motors before the level is taken: it can silence a
    /// rumble, weaken it, or lift a faint one, and which motor leads does not change.
    @Test func triggerStrengthScalesTheMirroredRumble() {
        typealias Effect = DualSense.TriggerEffect
        func pulled(_ level: Float) -> [Float] { [0, 0, 0] + [Float](repeating: level, count: 7) }
        #expect(Effect.mirroringRumble(weak: 0, strong: 1, strength: 0) == .off)
        #expect(Effect.mirroringRumble(weak: 0, strong: 1, strength: 0.5) == .vibration(amplitudes: pulled(0.5), frequency: 25.0 / 255))
        #expect(Effect.mirroringRumble(weak: 0, strong: 0.2, strength: 0.25) == .off)
        #expect(Effect.mirroringRumble(weak: 0.25, strong: 0.2, strength: 2) == .vibration(amplitudes: pulled(0.5), frequency: 60.0 / 255))
        #expect(Effect.mirroringRumble(weak: 0, strong: 0.2) == Effect.mirroringRumble(weak: 0, strong: 0.2, strength: 1))
    }

    /// `HIDDevice::processHidOutputPayload`: a get-report request is `[report id][u16 LE length]`
    /// and the answer goes back as the same report type, its second byte the error flag.
    @Test func dualSenseAnswersFeatureReportRequests() {
        let request = NvstHidPassthrough.Report(deviceId: 11, kind: 3, reportType: 3, data: Data([0x05, 41, 0]))
        let answer = DualSense.response(toGetReport: request)
        #expect(answer?.deviceId == 11 && answer?.kind == 0 && answer?.reportType == 3)
        #expect(answer?.data.count == 41 && answer?.data.first == 0x05)
        #expect(DualSense.response(toGetReport: .init(deviceId: 11, reportType: 3, data: Data([0x09, 20, 0])))?.data.count == 20)
        #expect(DualSense.response(toGetReport: .init(deviceId: 11, reportType: 3, data: Data([0x20, 64, 0])))?.data.count == 64)
        // A shorter buffer gets a shorter report.
        #expect(DualSense.response(toGetReport: .init(deviceId: 11, reportType: 3, data: Data([0x20, 8, 0])))?.data.count == 8)
        // A report this pad cannot produce is answered as a failed read, not left hanging.
        let unknown = DualSense.response(toGetReport: .init(deviceId: 11, reportType: 3, data: Data([0x77, 16, 0])))
        #expect(unknown == NvstHidPassthrough.Report(deviceId: 11, kind: 1, reportType: 3, data: Data()))
        #expect(DualSense.response(toGetReport: .init(deviceId: 11, reportType: 2, data: Data([0x01, 64, 0])))?.kind == 1)
        // Output and feature writes are not requests.
        #expect(DualSense.response(toGetReport: .init(deviceId: 11, reportType: 0, data: Data([0x02, 1, 0]))) == nil)
        #expect(DualSense.response(toGetReport: .init(deviceId: 11, reportType: 3, data: Data([0x05, 41]))) == nil)
    }

    /// The seat names the device in its answer; reports then carry that id, not the request id.
    @Test func deviceTableMapsRequestIdsToSeatIds() {
        var table = NvstHidPassthrough.DeviceTable()
        #expect(!table.isAnnounced(10))
        table.request(10)
        #expect(table.isAnnounced(10) && table.seatId(forRequest: 10) == nil)
        #expect(table.resolve(.init(requestId: 12, status: 1, flags: 0, deviceId: 30)) == nil)
        #expect(table.resolve(.init(requestId: 10, status: 1, flags: 0, deviceId: 32)) == true)
        #expect(table.seatId(forRequest: 10) == 32 && table.requestId(forSeat: 32) == 10)
        #expect(table.requestId(forSeat: 10) == nil)
        // Answered once: a repeat does not move the device.
        #expect(table.resolve(.init(requestId: 10, status: 1, flags: 0, deviceId: 33)) == nil)
        #expect(table.remove(request: 10) == 32)
        #expect(table.seatId(forRequest: 10) == nil && table.remove(request: 10) == nil)
        table.request(11)
        #expect(table.resolve(.init(requestId: 11, status: 1, flags: 0, deviceId: 0xff)) == false)
        #expect(table.seatId(forRequest: 11) == nil && !table.isAnnounced(11))
    }

    @Test func translatorPassesTheDualSenseAnnouncementThrough() throws {
        let add = DualSense.changeEvent(gamepadIndex: 0)
        guard case .hidChange(let change)? = try NativeStreamNVSTInput.translate(add.event, timestamp: 0, sequence: 0).first else {
            Issue.record("not a HID change"); return
        }
        #expect(change == add)
    }
}
