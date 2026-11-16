import Foundation
import Testing
@testable import OpenNOWiOS

/// Asking the seat to resend lost video packets: the request it understands, when it is sent, and
/// how long the receiver waits for the answer.
@Suite(.serialized)
struct NvstNackTests {
    private static let millisecond: UInt64 = 1_000_000

    // MARK: - Request

    /// Layout read from the official client's `RtpSourceQueueExtV2::createNackRequest`: a version
    /// word, an entry count, then per entry a first packet and a mask of the 64 packets after it.
    @Test func theRequestNamesAFirstPacketAndAMaskOfTheSixtyFourAfterIt() throws {
        let request = try #require(NvstRtpNackRequest(missing: [100, 101, 103, 164, 165, 400]))
        #expect(request.command.code == .rtpNackRequest)
        var expected: [UInt8] = [0x02, 0x00, 0x03]
        // 100, then 101 (bit 0), 103 (bit 2) and 164 (bit 63).
        expected += [0x64, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80]
        // 165 is 65 past 100, so it starts its own entry.
        expected += [0xa5, 0x00] + [UInt8](repeating: 0, count: 8)
        expected += [0x90, 0x01] + [UInt8](repeating: 0, count: 8)
        #expect([UInt8](request.command.payload) == expected)
    }

    @Test func theMaskCarriesAcrossTheSequenceNumberWrap() throws {
        let request = try #require(NvstRtpNackRequest(missing: [0xfffe, 0xffff, 0x0001]))
        // 0xffff is one past the first packet (bit 0), 0x0001 is three past it (bit 2).
        #expect([UInt8](request.command.payload) == [0x02, 0x00, 0x01, 0xfe, 0xff, 0x05, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test func nothingMissingMakesNoRequest() {
        #expect(NvstRtpNackRequest(missing: []) == nil)
    }

    // MARK: - Tracker

    @Test func aMissingPacketIsRequestedAtOnceThenAgainOnlyAfterTheAnswerIsOverdue() {
        var tracker = NvstNackTracker()
        tracker.roundTripNanoseconds = 6 * Self.millisecond
        tracker.noteMissing(10...11, now: 0)
        let first = tracker.takeDue(now: 0)
        // The answer needs a round trip plus the retry margin; asking again sooner is noise.
        let early = tracker.takeDue(now: 10 * Self.millisecond)
        let retry = tracker.takeDue(now: 11 * Self.millisecond)
        #expect(first == [10, 11])
        #expect(early.isEmpty)
        #expect(retry == [10, 11])
        #expect(tracker.counters.requestsSent == 2)
        #expect(tracker.counters.packetsRequested == 4)
        #expect(tracker.counters.packetsRetried == 2)
    }

    @Test func aPacketIsWaitedForUntilItsLastRequestHasTimedOut() {
        var tracker = NvstNackTracker()
        tracker.roundTripNanoseconds = 6 * Self.millisecond
        tracker.noteMissing(10...10, now: 0)
        var now: UInt64 = 0
        var requests = 0
        while tracker.isAwaiting(10, now: now) {
            requests += tracker.takeDue(now: now).count
            now += Self.millisecond
        }
        #expect(requests == NvstNackTracker.maximumRequests)
        // Three requests 11 ms apart, and the last one gets its 11 ms too.
        #expect(now == 33 * Self.millisecond)
    }

    @Test func aResentPacketIsCountedAndNoLongerRequested() {
        var tracker = NvstNackTracker()
        tracker.noteMissing(10...11, now: 0)
        _ = tracker.takeDue(now: 0)
        tracker.noteArrived(10, wasResent: true)
        #expect(tracker.counters.packetsReceived == 1)
        #expect(!tracker.isAwaiting(10, now: 0))
        #expect(tracker.isAwaiting(11, now: 0))
        let retry = tracker.takeDue(now: 100 * Self.millisecond)
        #expect(retry == [11])
    }

    /// A jump of thousands of packets is a stream restart or a long outage, not something to ask
    /// for packet by packet.
    @Test func aHoleTooLargeToRepairIsNotTracked() {
        var tracker = NvstNackTracker()
        tracker.noteMissing(10...10_000, now: 0)
        let due = tracker.takeDue(now: 0)
        #expect(tracker.isEmpty)
        #expect(due.isEmpty)
    }

    // MARK: - Receiver

    /// Three packets of one frame, in wire order.
    private func frame(_ frameIndex: UInt32, firstSequence: UInt16) -> [(sequence: UInt16, packet: Data)] {
        [(firstSequence, NvstReceiverFixtures.packet(sequence: firstSequence, frameIndex: frameIndex, flags: 0x05, media: [0x00, 0x00, 0x00, 0x01, 0x65])),
         (firstSequence + 1, NvstReceiverFixtures.packet(sequence: firstSequence + 1, frameIndex: frameIndex, flags: 0x01, media: [0xbb])),
         (firstSequence + 2, NvstReceiverFixtures.packet(sequence: firstSequence + 2, frameIndex: frameIndex, flags: 0x03, media: [0xcc]))]
    }

    private func requested(_ events: [NvstReceiveEvent]) -> [UInt16] {
        events.flatMap { if case .retransmissionWanted(let sequences) = $0 { return sequences } else { return [] } }
    }

    /// Frames 1...4 with packet 5 (the middle of frame 2) withheld, a millisecond apart.
    private func feedWithPacketFiveMissing(_ receiver: NvstVideoReceiver, handoff: NVSTVideoHandoff) throws -> [NvstReceiveEvent] {
        var events: [NvstReceiveEvent] = []
        var now: UInt64 = 0
        for frameIndex in UInt32(1)...4 {
            for (sequence, packet) in frame(frameIndex, firstSequence: UInt16(frameIndex - 1) * 3 + 1) where sequence != 5 {
                events += receiver.process(datagram: try NvstReceiverFixtures.seal(packet, sequence: sequence, handoff: handoff), now: now)
            }
            now += Self.millisecond
        }
        return events
    }

    @Test func aLostPacketIsRequestedAtOnceAndTheFramesBehindItWaitForTheAnswer() throws {
        let handoff = NvstReceiverFixtures.makeHandoff(reorderWindow: 4)
        let receiver = try NvstVideoReceiver(handoff: handoff)
        receiver.updateRoundTrip(milliseconds: 6)

        var events = try feedWithPacketFiveMissing(receiver, handoff: handoff)
        #expect(requested(events) == [5])
        // Seven packets have arrived behind the hole, past the reorder window of four, but the
        // answer to the request is not overdue yet.
        #expect(NvstReceiverFixtures.frames(events).map(\.frameIndex) == [1])
        #expect(NvstReceiverFixtures.recoveries(events) == 0)

        let resent = frame(2, firstSequence: 4)[1]
        events = receiver.process(datagram: try NvstReceiverFixtures.seal(resent.packet, sequence: 5, handoff: handoff), now: 8 * Self.millisecond)
        #expect(NvstReceiverFixtures.frames(events).map(\.frameIndex) == [2, 3, 4])
        #expect(NvstReceiverFixtures.recoveries(events) == 0)
        #expect(receiver.snapshot.finalizedLossPackets == 0)
        #expect(receiver.snapshot.nack.packetsReceived == 1)
    }

    @Test func aPacketTheSeatNeverResendsIsGivenUpOnceTheLastRequestTimesOut() throws {
        let handoff = NvstReceiverFixtures.makeHandoff(reorderWindow: 4)
        let receiver = try NvstVideoReceiver(handoff: handoff)
        receiver.updateRoundTrip(milliseconds: 6)

        var events = try feedWithPacketFiveMissing(receiver, handoff: handoff)
        var sequence: UInt16 = 13
        var frameIndex: UInt32 = 5
        // One frame every 4 ms: at 4...32 ms the last request is still open, at 36 ms it is not.
        for step in UInt64(1)...9 {
            for (packetSequence, packet) in frame(frameIndex, firstSequence: sequence) {
                events += receiver.process(datagram: try NvstReceiverFixtures.seal(packet, sequence: packetSequence, handoff: handoff),
                                           now: step * 4 * Self.millisecond)
            }
            sequence += 3
            frameIndex += 1
            if step < 9 { #expect(NvstReceiverFixtures.recoveries(events) == 0) }
        }
        #expect(requested(events) == [5, 5, 5])
        #expect(NvstReceiverFixtures.recoveries(events) == 1)
        #expect(receiver.snapshot.finalizedLossPackets == 1)
        // Frame 2 lost its middle packet; everything that arrived whole behind it is delivered.
        #expect(NvstReceiverFixtures.frames(events).map(\.frameIndex) == [1] + Array(3...13))
    }

    // MARK: - Replay window

    /// A resent packet arrives a round trip after its neighbours, which at stream bitrates is
    /// hundreds of packets later. The 64-packet window rejected it as a replay.
    @Test func aPacketResentWellAfterItsNeighboursIsNotAReplay() {
        var window = SrtpReplayWindow()
        _ = window.accept(0)
        _ = window.accept(1000)
        let acceptable = window.wouldAccept(500)
        let resent = window.accept(500)
        let replayed = window.accept(500)
        #expect(acceptable)
        #expect(resent)
        #expect(!replayed)

        _ = window.accept(2000)
        // 600 is now 1400 behind: outside the window, so it can no longer be told from a replay.
        let tooOld = window.wouldAccept(600)
        let seenBefore = window.accept(1000)
        let neverSeen = window.accept(1001)
        #expect(!tooOld)
        #expect(!seenBefore)
        #expect(neverSeen)
    }
}
