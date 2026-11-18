import SwiftUI

/// Settings → About on the TV: the installed version against the newest GitHub release, and how
/// to update when one is newer.
struct TVReleaseCheckSection: View {
    @ObservedObject private var checker = TVReleaseChecker.shared
    @State private var showingUpdate = false

    var body: some View {
        Section {
            LabeledContent("Latest Release", value: latestText)
            if let release = checker.available {
                Button("How to Update to \(release.version)") { showingUpdate = true }
            }
            if checker.enabled {
                Button(checker.status == .checking ? "Checking…" : "Check Now") {
                    Task { await checker.check() }
                }
                .disabled(checker.status == .checking)
            }
            Toggle("Check for Updates", isOn: $checker.enabled)
        } header: {
            Text("Updates")
        } footer: {
            Text("OpenNOW asks GitHub (github.com/\(TVRelease.repository)) at most twice a day whether a newer Apple TV release is out. Nothing about you or your account is sent.")
        }
        .fullScreenCover(isPresented: $showingUpdate) {
            if let release = checker.available {
                TVReleaseUpdatePanel(release: release, installed: checker.installedVersion)
            }
        }
    }

    private var latestText: String {
        guard checker.enabled else { return "Not checked" }
        if let release = checker.available { return "\(release.version) available" }
        switch checker.status {
        case .checking: return "Checking…"
        case .failed: return "Couldn’t reach GitHub"
        case .idle, .checked:
            guard let lastChecked = checker.lastChecked else { return "Not checked yet" }
            return "Up to date · checked \(lastChecked.formatted(.relative(presentation: .named)))"
        }
    }
}

/// How to update: the release page as a QR code for a phone, and the command for the Mac that
/// installed the app.
private struct TVReleaseUpdatePanel: View {
    let release: TVRelease
    let installed: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TVConsoleSheetPanel(eyebrow: "UPDATE", title: "Version \(release.version)", description: release.name) {
            VStack(alignment: .leading, spacing: 22) {
                Text("You have \(installed). Scan the code to read what’s new, then update from the Mac you installed OpenNOW with:")
                    .font(TVConsoleTheme.display(19, weight: 600))
                    .foregroundStyle(TVConsoleTheme.label)
                    .fixedSize(horizontal: false, vertical: true)
                Text(TVRelease.updateCommand)
                    .font(TVConsoleTheme.mono(15, bold: true))
                    .foregroundStyle(TVConsoleTheme.mint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 16).fill(TVConsoleTheme.face.opacity(0.06)))
                if let image = openNowQRCodeImage(release.url.absoluteString) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 240, height: 240)
                        .padding(14)
                        .background(.white, in: RoundedRectangle(cornerRadius: 18))
                        .accessibilityLabel("QR code for the release page")
                }
                TVConsoleActionButton(title: "Done", primary: true, pill: true) { dismiss() }
            }
            .padding(.top, 26)
        }
    }
}
