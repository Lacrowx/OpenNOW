import SwiftUI

/// Experimental settings rows for switching a TCL TV's Game Master on while streaming.
struct TVGameMasterSetting: View {
    @State private var enabled = TVGameMaster.enabled
    @State private var busy = false
    @State private var status: String?
    @State private var address = TVGameMasterLink.host ?? ""

    var body: some View {
        Section {
            Toggle("TCL TV Game Master While Streaming", isOn: Binding(get: { enabled }, set: {
                enabled = $0
                TVGameMaster.enabled = $0
            }))
            TextField("TV Address (found automatically)", text: $address)
                .keyboardType(.numbersAndPunctuation)
                .onSubmit {
                    let trimmed = address.trimmingCharacters(in: .whitespaces)
                    TVGameMasterLink.host = trimmed.isEmpty ? nil : trimmed
                }
            Button(busy ? "Connecting…" : "Connect to TV") { connect() }
                .disabled(busy)
            if let status {
                Text(status).font(.footnote)
            }
        } header: {
            Text("TV Game Master")
        } footer: {
            Text("For TCL Google TVs: Apple TV does not tell the TV it is playing a game, so the TV's Auto Game Master never starts. With this on, OpenNOW switches Game Master on for the HDMI input the Apple TV is on while a stream plays, and back to the input's own setting afterwards. Setup: on the TV, turn on Developer options, then Wireless debugging. On a computer paired with the TV, run adb tcpip 5555 once, then choose Connect to TV here and allow the prompt on the TV with Always allow ticked.")
        }
    }

    private func connect() {
        busy = true
        status = "Looking for the TV…"
        let link = TVGameMasterLink.shared
        link.queue.async {
            let result: String
            do {
                _ = try TVGameMasterKey.ensure()
                try link.approve(waiting: {
                    DispatchQueue.main.async {
                        status = "On the TV, tick Always allow, then choose Allow."
                    }
                })
                let input = try TVGameMaster.currentInput(link)
                let mode = try TVGameMaster.read(input, link)
                result = "Connected. HDMI \(input.number) Game Master is \(mode.label)."
            } catch {
                result = Self.message(for: error)
            }
            DispatchQueue.main.async {
                status = result
                address = TVGameMasterLink.host ?? address
                busy = false
            }
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case TVGameMasterLink.Failure.notFound:
            "No TV found. Turn on Wireless debugging in the TV's Developer options, or enter the TV's address (Settings > Network on the TV) above."
        case TVGameMasterLink.Failure.portClosed:
            "The TV has not approved OpenNOW yet. On a computer paired with the TV, run adb tcpip 5555, then try again."
        case TVAdbConnection.Failure.notApproved:
            "The TV did not allow OpenNOW."
        case TVGameMaster.Failure.notOnHDMI:
            "Connected, but the TV is not showing an HDMI input."
        default:
            "Could not reach the TV: \(error)"
        }
    }
}
