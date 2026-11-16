import SwiftUI
import Combine
import GameController

/// The buttons the console shell draws hints for. `x` is also Play/Pause on the Siri Remote:
/// tvOS delivers a controller's X as that command, so one hint and one handler serve both.
enum TVConsoleButton: Hashable {
    case select, back, x, y, options, previousPage, nextPage
}

struct TVConsoleHint: Equatable, Identifiable {
    let button: TVConsoleButton
    let label: String

    var id: TVConsoleButton { button }
}

/// The controller in use while the console shell is on screen: which symbols its buttons carry,
/// its battery, and presses of the buttons tvOS does not turn into focus or Select/Back events.
///
/// State is polled rather than read through `pressedChangedHandler`: the stream sets and clears
/// those handlers on every button, so handlers installed here would be gone after the first game.
@MainActor
final class TVConsoleInput: ObservableObject {
    enum Press {
        case previousPage, nextPage, x, y, options
    }

    /// SF Symbol per button: the connected controller's own, or the Siri Remote's without one.
    @Published private(set) var symbols = TVConsoleInput.remoteSymbols
    @Published private(set) var hasGamepad = false
    @Published private(set) var batteryPercent: Int?

    let presses = PassthroughSubject<Press, Never>()

    private var timer: Timer?
    private weak var controller: GCController?
    private var held: Set<Press> = []

    func start() {
        guard timer == nil else { return }
        // A button still down from before (the one that closed a menu or ended a stream) is not a
        // new press.
        poll(reportingPresses: false)
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.poll(reportingPresses: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        held.removeAll()
    }

    private func poll(reportingPresses: Bool) {
        let current = GCController.current.flatMap { $0.extendedGamepad == nil ? nil : $0 }
            ?? GCController.controllers().first { $0.extendedGamepad != nil }
        if current !== controller {
            controller = current
            hasGamepad = current != nil
            symbols = current?.extendedGamepad.map(Self.symbols) ?? Self.remoteSymbols
            held.removeAll()
        }

        let battery = current?.battery.map { Int(($0.batteryLevel * 100).rounded()) }
        if battery != batteryPercent { batteryPercent = battery }

        guard let pad = current?.extendedGamepad else { return }
        let state: [(Press, Bool)] = [
            (.previousPage, pad.leftShoulder.isPressed),
            (.nextPage, pad.rightShoulder.isPressed),
            (.x, pad.buttonX.isPressed),
            (.y, pad.buttonY.isPressed),
            (.options, pad.buttonOptions?.isPressed ?? false),
        ]
        // While a sheet or alert is up, the buttons belong to it, not to the shell underneath.
        let report = reportingPresses && !TVConsoleWindow.isModalPresented
        for (press, isDown) in state {
            if !isDown {
                held.remove(press)
            } else if held.insert(press).inserted, report {
                presses.send(press)
            }
        }
    }

    private static let remoteSymbols: [TVConsoleButton: String] = [
        .select: "smallcircle.filled.circle.fill",
        .back: "chevron.backward.circle.fill",
        .x: "playpause.circle.fill",
    ]

    private static func symbols(for pad: GCExtendedGamepad) -> [TVConsoleButton: String] {
        [
            .select: filled(pad.buttonA, fallback: "a.circle"),
            .back: filled(pad.buttonB, fallback: "b.circle"),
            .x: filled(pad.buttonX, fallback: "x.circle"),
            .y: filled(pad.buttonY, fallback: "y.circle"),
            .options: filled(pad.buttonOptions ?? pad.buttonMenu, fallback: "line.3.horizontal.circle"),
            .previousPage: filled(pad.leftShoulder, fallback: "lb.rectangle.roundedbottom"),
            .nextPage: filled(pad.rightShoulder, fallback: "rb.rectangle.roundedbottom"),
        ]
    }

    /// The solid variant reads as the Qt client's white glyph with a dark letter.
    private static func filled(_ element: GCControllerElement, fallback: String) -> String {
        let name = element.sfSymbolsName ?? fallback
        return UIImage(systemName: name + ".fill") == nil ? name : name + ".fill"
    }
}

/// One controller button, drawn with the symbol of the controller in use. Draws nothing for a
/// button the current input device does not have.
struct TVConsoleGlyph: View {
    let button: TVConsoleButton
    var size: CGFloat = 30
    var color = TVConsoleTheme.face

    @EnvironmentObject private var input: TVConsoleInput

    var body: some View {
        if let symbol = input.symbols[button] {
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(color)
        }
    }
}
