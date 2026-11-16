import SwiftUI

struct StreamSessionsView: View {
    @ObservedObject var history: StreamSessionHistoryStore

    var body: some View {
        #if os(tvOS)
        TVConsoleSessionsLayout(records: history.records, summary: summary, details: details) { record in
            if let index = history.records.firstIndex(of: record) { history.delete(at: [index]) }
        }
        #else
        NavigationStack { content }
        #endif
    }

    private var content: some View {
        Group {
            if history.records.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath").font(.largeTitle)
                    Text("Your sessions will appear here").font(.headline)
                    #if os(tvOS)
                    Text("See how long you played. History is saved on this device.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    #else
                    Text("See how long you played and how your battery changed. History is saved on this device.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    #endif
                }
                .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(history.records) { record in
                        NavigationLink {
                            details(record)
                                .hidingTabBarWhenPushed()
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(record.gameTitle).font(.headline)
                                Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(summary(record))
                                    .font(.subheadline)
                                if record.endedAt == nil || record.interrupted {
                                    Text(record.status).font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 4)
                        }
                        .deleteDisabled(record.endedAt == nil)
                    }
                    .onDelete(perform: history.delete)
                }
            }
        }
        .navigationTitle("Sessions")
        .toolbar { if !history.records.isEmpty { EditButton() } }
    }

    private func details(_ record: StreamSessionRecord) -> some View {
        Form {
            Section("Session") {
                row("Game", record.gameTitle)
                row("Started", record.startedAt.formatted(date: .abbreviated, time: .shortened))
                if let end = record.endedAt {
                    row(record.interrupted ? "Last recorded" : "Ended",
                        end.formatted(date: .abbreviated, time: .shortened))
                }
                row("Duration", record.durationText)
                row("Status", record.status)
            }
            // An Apple TV has no battery to report on.
            #if !os(tvOS)
            Section {
                LabeledContent("At start", value: percent(record.battery.startPercent))
                LabeledContent(record.endedAt == nil ? "Current" : record.interrupted ? "Last recorded" : "At end",
                               value: percent(record.battery.currentPercent))
                LabeledContent("Battery change", value: record.battery.changeText)
                LabeledContent("Charging during session", value: record.battery.includedCharging ? "Yes" : "No")
            } header: { Text("Battery") } footer: {
                Text("Battery change compares the first available percentage with the latest reading. Sessions that include charging show the net change.")
            }
            #endif
            Section("Requested stream") {
                row("Resolution", record.resolution)
                row("Frame rate", "\(record.targetFPS) FPS")
                row("Codec", record.codec)
                row("HDR", record.hdr ? "On" : "Off")
                row("Connection", record.transport)
            }
        }
        .navigationTitle(record.gameTitle)
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value).readableRowOnTV()
    }

    private func summary(_ record: StreamSessionRecord) -> String {
        #if os(tvOS)
        record.durationText
        #else
        "\(record.durationText) · \(record.battery.changeText)"
        #endif
    }

    private func percent(_ value: Int?) -> String { value.map { "\($0)%" } ?? "Unavailable" }
}
