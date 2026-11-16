import SwiftUI

/// The console Sessions page. The Qt client has none, so it follows the Library layout: the
/// history list beside a panel with the details of the session that has focus. The details are
/// the shared iOS page's own `Form`, which draws as console rows in this target.
struct TVConsoleSessionsLayout<Details: View>: View {
    let records: [StreamSessionRecord]
    let summary: (StreamSessionRecord) -> String
    @ViewBuilder let details: (StreamSessionRecord) -> Details
    let onDelete: (StreamSessionRecord) -> Void

    @FocusState private var focusedID: UUID?
    @FocusState private var inDetails: Bool
    /// The session whose details are shown: the focused one, or the last one that was while focus
    /// is on the dock.
    @State private var shownID: UUID?
    @State private var deleting: StreamSessionRecord?

    private static var panelHeight: CGFloat { 792 }

    private var shown: StreamSessionRecord? {
        records.first { $0.id == shownID } ?? records.first
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TVConsoleBackground(artwork: nil, tint: 0x17233B)
            if records.isEmpty {
                TVConsoleCatalogNotice(
                    title: "Your sessions will appear here",
                    detail: "See how long you played. History is saved on this device."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 24) {
                    // The list spans the dock, so Up from any dock item lands in it.
                    list
                        .frame(width: 1144, height: Self.panelHeight)
                        .tvConsoleGlass(radius: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 40))
                        .focusSection()
                        .defaultFocus($focusedID, shown?.id, priority: .userInitiated)
                    Group {
                        if let shown {
                            details(shown)
                                .tvConsoleFormHeading(shown.gameTitle)
                                .id(shown.id)
                        }
                    }
                    .frame(width: 560, height: Self.panelHeight)
                    .tvConsoleGlass(radius: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 40))
                    .focusSection()
                    .focused($inDetails)
                    // Back from the details goes to the session they belong to; from the list
                    // the shell takes it.
                    .onExitCommand(perform: inDetails ? { focusedID = shown?.id } : nil)
                }
                .padding(.leading, 96)
                .padding(.top, 124)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .onChange(of: focusedID) { _, focused in
            if let focused { shownID = focused }
        }
        .preference(key: TVConsoleHintsKey.self, value: TVConsoleHints(
            left: [.init(button: .back, label: inDetails ? "Sessions" : "Back")],
            right: canDelete(shown) && focusedID != nil ? [.init(button: .select, label: "Options")] : [],
            // The shell would send Back to the dock instead of the list.
            handlesBack: inDetails
        ))
        .fullScreenCover(item: $deleting) { record in
            TVConsoleChoiceSheet(
                eyebrow: "SESSION", title: record.gameTitle,
                description: record.startedAt.formatted(date: .abbreviated, time: .shortened),
                choices: [TVConsoleChoice(id: "delete", label: "Delete from history") {
                    deleting = nil
                    onDelete(record)
                }]
            )
        }
    }

    /// A session that is still running is not deleted, as on iOS.
    private func canDelete(_ record: StreamSessionRecord?) -> Bool { record?.endedAt != nil }

    private var list: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(records) { record in
                    let focused = focusedID == record.id
                    Button {
                        if canDelete(record) { deleting = record }
                    } label: {
                        row(record)
                            .modifier(TVConsoleSheetRow(focused: focused, marked: shown?.id == record.id,
                                                        radius: 24))
                    }
                    .buttonStyle(TVConsolePlainButtonStyle())
                    .focused($focusedID, equals: record.id)
                }
            }
            // Room for the focus ring, which the scroll view would otherwise clip.
            .padding(.horizontal, 28)
            .padding(.vertical, 28)
        }
    }

    private func row(_ record: StreamSessionRecord) -> some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.gameTitle)
                    .font(TVConsoleTheme.display(21))
                    .foregroundStyle(TVConsoleTheme.label)
                Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(TVConsoleTheme.display(16, weight: 600))
                    .foregroundStyle(TVConsoleTheme.textMuted)
            }
            Spacer(minLength: 24)
            VStack(alignment: .trailing, spacing: 4) {
                Text(summary(record))
                    .font(TVConsoleTheme.display(18, weight: 800))
                    .foregroundStyle(TVConsoleTheme.label)
                if record.endedAt == nil || record.interrupted {
                    Text(record.status)
                        .font(TVConsoleTheme.display(16, weight: 600))
                        .foregroundStyle(record.endedAt == nil ? TVConsoleTheme.mint : TVConsoleTheme.textMuted)
                }
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 25)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
    }
}
