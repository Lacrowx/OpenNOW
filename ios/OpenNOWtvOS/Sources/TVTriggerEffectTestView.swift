import GameController
import SwiftUI

/// The adaptive trigger effects the settings test page can play. Each is the eleven bytes a game
/// on the host would write for it, so the test goes through the same decoding as a stream does.
enum TVTriggerEffectTest: String, CaseIterable, Identifiable {
    case resistance, weapon, slowVibration, fastVibration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .resistance: "Resistance"
        case .weapon: "Weapon Trigger"
        case .slowVibration: "Slow Vibration"
        case .fastVibration: "Fast Vibration"
        }
    }

    var detail: String {
        switch self {
        case .resistance: "Pushes back from a third of the way down."
        case .weapon: "Holds, then gives way like a trigger pull."
        case .slowVibration: "Pulses at 10 Hz while the trigger is held."
        case .fastVibration: "Buzzes at 40 Hz while the trigger is held."
        }
    }

    /// The mode byte, a ten-bit zone mask, then three bits of strength per zone (7 is full); a
    /// vibration's frequency in hertz is its tenth byte.
    var bytes: [UInt8] {
        switch self {
        case .resistance: [0x21, 0xf8, 0x03, 0x00, 0xfe, 0xff, 0x3f, 0, 0, 0, 0]
        case .weapon: [0x25, 0x24, 0x00, 0x07, 0, 0, 0, 0, 0, 0, 0]
        case .slowVibration: [0x26, 0xfe, 0x03, 0xf8, 0xff, 0xff, 0x3f, 0, 0, 10, 0]
        case .fastVibration: [0x26, 0xfe, 0x03, 0xf8, 0xff, 0xff, 0x3f, 0, 0, 40, 0]
        }
    }

    var effect: NvstHidPassthrough.DualSense.TriggerEffect { .init(bytes: bytes) }
}

/// Plays one trigger effect at a time on the connected DualSense, without a game or a stream.
struct TVTriggerEffectTestView: View {
    @State private var playing: TVTriggerEffectTest?
    @State private var padConnected = TVTriggerEffectTestView.pad != nil

    private static var pad: GCDualSenseGamepad? {
        GCController.controllers().lazy.compactMap { $0.extendedGamepad as? GCDualSenseGamepad }.first
    }

    var body: some View {
        Form {
            Section {
                ForEach(TVTriggerEffectTest.allCases) { test in
                    Button { play(test) } label: { row(test.title, detail: test.detail, selected: playing == test) }
                }
                Button { play(nil) } label: { row("Off", detail: "Triggers move freely.", selected: playing == nil) }
            } header: {
                Text(padConnected ? "DualSense Connected" : "No DualSense Connected")
            } footer: {
                Text("Choose an effect, then pull L2 and R2. Both triggers play it until you choose another or leave this page.")
            }
        }
        .navigationTitle("Trigger Effect Test")
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in controllersChanged() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in controllersChanged() }
        .onDisappear { play(nil) }
    }

    private func row(_ title: String, detail: String, selected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if selected { Image(systemName: "checkmark") }
        }
    }

    private func play(_ test: TVTriggerEffectTest?) {
        playing = test
        guard let pad = Self.pad else { return }
        let effect = test?.effect ?? .off
        pad.leftTrigger.apply(effect)
        pad.rightTrigger.apply(effect)
    }

    /// A pad that connects mid-test has free triggers, so the test goes back to Off with it.
    private func controllersChanged() {
        padConnected = Self.pad != nil
        play(nil)
    }
}
