import SwiftUI

/// `LaunchStage.qml`: the full-screen layout shared by the queue and the running-game conflict.
/// A game header and status chip on top, a large headline on the left, an aside on the right, and
/// either the four-step rail with the actions along the bottom, or the actions as a column.
struct TVConsoleLaunchStageView<Aside: View, Actions: View>: View {
    let game: CloudGame?
    let status: String
    var tone: Color
    let eyebrow: String
    let headline: String
    let detail: String
    var detailColor = TVConsoleTheme.textMuted
    /// Shows the rail, with this as the step in progress.
    var stage: TVConsoleLaunchStage?
    @ViewBuilder let aside: Aside
    @ViewBuilder let actions: Actions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            header.padding(.leading, 120).padding(.top, 72)
            statusChip
                // A cover is offered the title-safe width; the chip sits at the canvas edge.
                .frame(width: 1800, alignment: .trailing)
                .padding(.top, 72)
            aside
                .frame(width: 800, height: 666, alignment: .topTrailing)
                .padding(.leading, 1000)
                .padding(.top, 214)
            VStack(alignment: .leading, spacing: 0) {
                if stage == nil {
                    // The action column starts at y 560 unless the copy runs longer.
                    copy.frame(minHeight: 318, alignment: .top)
                    VStack(alignment: .leading, spacing: 14) { actions }
                        .frame(width: 640, alignment: .leading)
                        .padding(.top, 28)
                        .focusSection()
                } else {
                    // The rail starts at y 636 unless the copy runs longer.
                    copy.frame(minHeight: 382, alignment: .top)
                    rail.padding(.top, 40)
                }
            }
            .padding(.leading, 120)
            .padding(.top, 214)
            if stage != nil {
                HStack(spacing: 14) { actions }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.leading, 120)
                    .padding(.bottom, 60)
                    .focusSection()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
    }

    private var backdrop: some View {
        TVConsoleTheme.shell
            .overlay(alignment: .trailing) {
                if let url = (game?.heroImageUrl ?? game?.detailsArtworkUrl).flatMap(URL.init(string:)) {
                    Color.clear
                        .overlay {
                            CachedRemoteImage(url: url, targetPixelSize: 1344, priority: .utility) { image in
                                image.resizable().scaledToFill().opacity(0.62)
                            } placeholder: {
                                Color.clear
                            } failure: {
                                Color.clear
                            }
                        }
                        .frame(width: 1344)
                        .clipped()
                }
            }
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: TVConsoleTheme.shell, location: 0),
                        .init(color: TVConsoleTheme.shell, location: 0.34),
                        .init(color: TVConsoleTheme.shell.opacity(0.66), location: 0.62),
                        .init(color: TVConsoleTheme.shell.opacity(0.34), location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                LinearGradient(colors: [.clear, TVConsoleTheme.shell],
                               startPoint: UnitPoint(x: 0.5, y: 0.7), endPoint: .bottom)
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let url = game?.catalogArtworkUrl.flatMap(URL.init(string:)) {
                CachedRemoteImage(url: url, targetPixelSize: 88) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    TVConsoleTheme.glassStrong
                } failure: {
                    TVConsoleTheme.glassStrong
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(TVConsoleTheme.seam, lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: -1) {
                Text(game?.title ?? "GeForce NOW")
                    .font(TVConsoleTheme.display(19))
                    .foregroundStyle(TVConsoleTheme.label)
                if let store = game.flatMap({ $0.ownedStorefronts.first ?? $0.consoleStores.first }) {
                    Text(gameStoreDisplayName(store))
                        .font(TVConsoleTheme.display(15, weight: 700))
                        .foregroundStyle(TVConsoleTheme.textMuted)
                }
            }
            .lineLimit(1)
        }
    }

    private var statusChip: some View {
        HStack(spacing: 10) {
            Circle().fill(tone).frame(width: 9, height: 9)
            Text(status.uppercased())
                .font(TVConsoleTheme.mono(14, bold: true))
                .tracking(1.4)
                .foregroundStyle(tone)
        }
        .padding(.horizontal, 19)
        .frame(height: 44)
        .background(Capsule().fill(tone.opacity(0.12)))
        .overlay(Capsule().strokeBorder(tone.opacity(0.5), lineWidth: 1))
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(eyebrow.uppercased())
                .font(TVConsoleTheme.mono(15))
                .tracking(2.1)
                .foregroundStyle(tone)
            Text(headline)
                .font(TVConsoleTheme.display(80))
                .tracking(-2.4)
                .foregroundStyle(TVConsoleTheme.label)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .padding(.top, 10)
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .font(TVConsoleTheme.display(22, weight: 600))
                .lineSpacing(5)
                .foregroundStyle(detailColor)
                .lineLimit(4)
                .frame(maxWidth: 880, alignment: .leading)
                .padding(.top, 12)
        }
        .frame(width: 860, alignment: .leading)
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let stage {
                ForEach(TVConsoleLaunchStage.Step.allCases, id: \.self) { step in
                    let done = step.rawValue < stage.step.rawValue
                    let current = step == stage.step
                    HStack(spacing: 18) {
                        marker(step, done: done, current: current)
                        Text(stage.label(for: step))
                            .font(TVConsoleTheme.display(current ? 24 : 21, weight: current ? 900 : 800))
                            .foregroundStyle(done || current ? TVConsoleTheme.label : TVConsoleTheme.textMuted)
                    }
                    .frame(height: 56)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(stage.label(for: step) + (done ? ", done" : current ? ", in progress" : ""))
                }
            }
        }
    }

    private func marker(_ step: TVConsoleLaunchStage.Step, done: Bool, current: Bool) -> some View {
        ZStack {
            if done {
                Circle().fill(TVConsoleTheme.mint)
                Image(systemName: "checkmark")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(TVConsoleTheme.faceText)
            } else if current {
                Circle().strokeBorder(tone.opacity(0.3), lineWidth: 2)
                TVConsoleSpinningArc(tone: tone, spinning: !reduceMotion)
                Circle().fill(tone).frame(width: 12, height: 12)
            } else {
                Circle().strokeBorder(TVConsoleTheme.seam, lineWidth: 2)
                Text("\(step.rawValue)")
                    .font(TVConsoleTheme.display(15, weight: 700))
                    .foregroundStyle(TVConsoleTheme.textMuted)
            }
        }
        .frame(width: 40, height: 40)
    }
}

/// The arc that circles the rail's step in progress.
private struct TVConsoleSpinningArc: View {
    let tone: Color
    let spinning: Bool

    @State private var turned = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.325)
            .stroke(tone, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .padding(2)
            .rotationEffect(.degrees(turned ? 270 : -90))
            .animation(spinning ? .linear(duration: 1.2).repeatForever(autoreverses: false) : nil, value: turned)
            .onAppear { turned = spinning }
    }
}

// MARK: - Queue

/// The screen shown while a session is requested, queued and set up (`InsertingScreen.qml`).
/// It takes the place of `StreamLoadingView` on tvOS and reads the same store state.
struct TVConsoleQueueView: View {
    @EnvironmentObject private var store: OpenNOWStore
    @Environment(\.openNowAccent) private var accent

    private enum Field { case keepBrowsing, leave }
    @FocusState private var focus: Field?

    var body: some View {
        let session = store.activeSession
        let stage = TVConsoleLaunchStage(
            sessionStatus: session?.status,
            isPastQueue: session.map(QueueSessionPhase.isPastQueue) ?? false,
            queuePosition: store.displayQueuePosition,
            queuePaused: store.isQueuePausedForAd
        )
        let error = store.sessionError.flatMap { $0.isEmpty ? nil : $0 }

        TVConsoleLaunchStageView(
            game: session?.game,
            status: stage.status, tone: accent.color,
            eyebrow: "Starting your session",
            headline: stage.headline,
            detail: error ?? stage.detail,
            detailColor: error == nil ? TVConsoleTheme.textMuted : TVConsoleTheme.coral,
            stage: stage
        ) {
            aside(stage: stage, session: session)
        } actions: {
            TVConsoleActionButton(title: "Keep browsing", glyph: .back) {
                store.minimizeQueueOverlay()
            }
            .focused($focus, equals: .keepBrowsing)
            TVConsoleActionButton(title: stage.step == .waitingForRig ? "Leave queue" : "Cancel session", danger: true) {
                Task { await store.endSession() }
            }
            .focused($focus, equals: .leave)
        }
        // The harmless choice takes focus: a stray Select must not cost a place in the queue.
        .defaultFocus($focus, .keepBrowsing)
        .onExitCommand { store.minimizeQueueOverlay() }
        .overlay(alignment: .bottomTrailing) { TVControllerNotice(message: TVControllerMonitor.queueMessage) }
    }

    @ViewBuilder
    private func aside(stage: TVConsoleLaunchStage, session: ActiveSession?) -> some View {
        if let ad = store.activeQueueAd {
            VStack(alignment: .trailing, spacing: 14) {
                QueueAdPlayerCard(ad: ad, compact: true)
                    .environmentObject(store)
                if store.isQueueAdRequired {
                    Text("Watch the advertisement to keep your place")
                        .font(TVConsoleTheme.display(17, weight: 700))
                        .foregroundStyle(TVConsoleTheme.yellow)
                }
            }
            .frame(width: 720)
            .padding(.trailing, 40)
        } else if let position = stage.queuePosition {
            queueRing(position)
        } else if let session, stage.step != .waitingForRig {
            TVConsoleRigCard(session: session)
        }
    }

    private func queueRing(_ position: Int) -> some View {
        VStack(spacing: 2) {
            Text("QUEUE POSITION")
                .font(TVConsoleTheme.mono(16, bold: true))
                .tracking(2.56)
                .foregroundStyle(TVConsoleTheme.textMuted)
            Text("\(position)")
                .font(TVConsoleTheme.display(position > 9999 ? 120 : 200))
                .tracking(-6)
                .foregroundStyle(TVConsoleTheme.label)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
            Text("Updates when GeForce NOW reports it")
                .font(TVConsoleTheme.display(19, weight: 700))
                .foregroundStyle(TVConsoleTheme.textMuted)
            QueueTrendStrip(trend: store.queueTrend).padding(.top, 10)
        }
        .padding(.horizontal, 48)
        .frame(width: 520, height: 520)
        .background(Circle().fill(TVConsoleTheme.glass))
        .overlay(Circle().strokeBorder(accent.color.opacity(0.5), lineWidth: 2))
        .padding(.top, 36)
        .padding(.trailing, 40)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Queue position \(position)")
    }
}

/// The rig a session runs on, beside the launch rail of the queue and the stream's Connecting
/// screen. Only what the session reports; a row without data is left out, never estimated.
struct TVConsoleRigCard: View {
    let session: ActiveSession

    var body: some View {
        let rows = [("GPU", session.gpuType ?? ""), ("Zone", session.zone)].filter { !$0.1.isEmpty }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                Text("YOUR RIG")
                    .font(TVConsoleTheme.mono(14, bold: true))
                    .tracking(1.96)
                    .foregroundStyle(TVConsoleTheme.textMuted)
                ForEach(rows, id: \.0) { row in
                    HStack {
                        Text(row.0)
                            .font(TVConsoleTheme.display(21, weight: 700))
                            .foregroundStyle(TVConsoleTheme.textMuted)
                        Spacer(minLength: 20)
                        Text(row.1)
                            .font(TVConsoleTheme.display(21))
                            .foregroundStyle(TVConsoleTheme.label)
                    }
                    .lineLimit(1)
                }
            }
            .padding(29)
            .frame(width: 520, alignment: .leading)
            .tvConsoleGlass(radius: 32, strong: true)
            .padding(.top, 50)
            .padding(.trailing, 40)
        }
    }
}

// MARK: - Running-game conflict

/// Asked when a launch would end a game that is still running (`ConsoleSessionConflict.qml`).
struct TVConsoleConflictView: View {
    let conflict: LaunchConflict

    @EnvironmentObject private var store: OpenNOWStore
    @Environment(\.openNowAccent) private var accent

    private enum Field { case resume, replace, cancel }
    @FocusState private var focus: Field?

    var body: some View {
        let running = conflict.runningGame.title
        let wanted = conflict.request.game.title
        TVConsoleLaunchStageView(
            game: conflict.request.game,
            status: "Needs a decision", tone: accent.color,
            eyebrow: "Your game is still running",
            headline: "Return to \(running)?",
            detail: conflict.message
        ) {
            runningCard
        } actions: {
            TVConsoleActionButton(title: "Return to \(running)", detail: "Resume the running session", primary: true) {
                store.cancelPendingLaunch()
                store.jumpBackToSession()
            }
            .focused($focus, equals: .resume)
            TVConsoleActionButton(title: "End \(running) and start \(wanted)", detail: "Closes the running game first",
                                  danger: true) {
                store.confirmPendingLaunch()
            }
            .focused($focus, equals: .replace)
            TVConsoleActionButton(title: "Cancel") {
                store.cancelPendingLaunch()
            }
            .focused($focus, equals: .cancel)
        }
        .defaultFocus($focus, .resume)
        .presentationBackground(TVConsoleTheme.shell)
    }

    private var runningCard: some View {
        let game = conflict.runningGame
        return VStack(alignment: .leading, spacing: 0) {
            TVConsoleTheme.storeColor(nil)
                .overlay {
                    if let url = (game.heroImageUrl ?? game.detailsArtworkUrl).flatMap(URL.init(string:)) {
                        CachedRemoteImage(url: url, targetPixelSize: 1040) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.clear
                        } failure: {
                            Color.clear
                        }
                    }
                }
                .overlay {
                    LinearGradient(colors: [.clear, TVConsoleTheme.shell.opacity(0.94)],
                                   startPoint: .center, endPoint: .bottom)
                }
                .frame(height: 300)
                .clipped()
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 8) {
                        Circle().fill(TVConsoleTheme.mint).frame(width: 9, height: 9)
                        Text("STILL RUNNING")
                            .font(TVConsoleTheme.mono(13, bold: true))
                            .tracking(1.3)
                            .foregroundStyle(TVConsoleTheme.label)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Capsule().fill(TVConsoleTheme.glassStrong))
                    .padding(24)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(game.title)
                    .font(TVConsoleTheme.display(32))
                    .foregroundStyle(TVConsoleTheme.label)
                Text("On your GeForce NOW account")
                    .font(TVConsoleTheme.display(17, weight: 700))
                    .foregroundStyle(TVConsoleTheme.textMuted)
            }
            .lineLimit(1)
            .padding(.horizontal, 32)
            .frame(maxHeight: .infinity)
        }
        .frame(width: 520, height: 410)
        .background(TVConsoleTheme.glassStrong)
        .clipShape(RoundedRectangle(cornerRadius: 32))
        .overlay(RoundedRectangle(cornerRadius: 32).strokeBorder(TVConsoleTheme.seam, lineWidth: 1))
        .padding(.trailing, 40)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Still running: \(game.title)")
    }
}
