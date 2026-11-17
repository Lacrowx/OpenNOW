import SwiftUI

/// Settings rows that fix the TV's display mode for the whole app, or leave it Automatic.
struct TVDisplayModeSetting: View {
    private static let confirmationSeconds = 15

    @State private var choices: [TVDisplayMode.Choice] = []
    @State private var selection: TVDisplayMode.Choice?
    /// What to go back to while a newly chosen mode waits to be confirmed.
    @State private var previous: TVDisplayMode.Choice?
    @State private var confirming = false
    @State private var leavePolicy = TVDisplayMode.leavePolicy

    var body: some View {
        TVLabeledPicker("Display Mode", selection: Binding(get: { selection }, set: choose)) {
            Text("Automatic").tag(TVDisplayMode.Choice?.none)
            ForEach(choices, id: \.self) { Text($0.label).tag(Optional($0)) }
        }
        .onAppear {
            choices = TVDisplayMode.choices
            // A mode saved for another TV is not offered here and behaves as Automatic.
            selection = TVDisplayMode.selection.flatMap { choices.contains($0) ? $0 : nil }
        }
        // A mode the TV cannot show leaves the screen black, so a new one must be confirmed.
        .alert("Keep this display mode?", isPresented: $confirming) {
            Button("Keep") { TVDisplayMode.select(selection, save: true) }
            Button("Revert", role: .cancel) { revert() }
        } message: {
            Text("The previous mode returns in \(Self.confirmationSeconds) seconds unless you keep this one.")
        }
        .task(id: confirming) {
            guard confirming, (try? await Task.sleep(for: .seconds(Self.confirmationSeconds))) != nil else { return }
            confirming = false
            revert()
        }

        TVLabeledPicker("When You Leave the App", selection: Binding(get: { leavePolicy }, set: {
            leavePolicy = $0
            TVDisplayMode.setLeavePolicy($0)
        })) {
            ForEach(TVDisplayMode.LeavePolicy.allCases, id: \.self) { Text($0.label).tag($0) }
        }

        Text("Automatic keeps the TV's own mode in menus and matches each stream while it plays. A fixed mode is used for the whole app; HDR streams use its HDR variant when the TV has one. When you leave the app, the TV can return to its own mode at once, stay in the stream's mode while the stream waits about 20 seconds for you to come back, which avoids switching modes twice on a quick trip to the Home screen, or keep the app's mode, for a TV you want to stay at, say, 1440p and 120 Hz.")
            .font(.footnote).foregroundStyle(.secondary)
    }

    private func choose(_ choice: TVDisplayMode.Choice?) {
        guard choice != selection else { return }
        previous = selection
        selection = choice
        TVDisplayMode.select(choice, save: choice == nil)
        confirming = choice != nil
    }

    private func revert() {
        selection = previous
        TVDisplayMode.select(previous, save: true)
    }
}
