import Foundation

/// What the sign-in screen offers and says, decided from the store's state (`SignInScreen.qml`).
struct TVConsoleSignIn: Equatable {
    enum Button: Equatable {
        case qrCode, signIn, provider, cancel
    }

    /// The provider's `code` (nil while the list has not loaded); only NVIDIA offers a device code.
    var providerCode: String?
    var providerName: String
    var hasCode: Bool
    var isAuthenticating: Bool
    var error: String?
    var phase: String?

    /// Buttons top to bottom; the first one is primary and takes the first focus.
    var buttons: [Button] {
        if hasCode { return [.cancel] }
        let isNVIDIA = (providerCode ?? "NVIDIA").uppercased() == "NVIDIA"
        return (isNVIDIA ? [.qrCode, .signIn] : [.signIn]) + [.provider]
    }

    func title(for button: Button) -> String {
        switch button {
        case .qrCode: return isAuthenticating ? "Connecting" : "Sign in with a QR code"
        case .signIn: return isAuthenticating && buttons.first == .signIn ? "Connecting" : "Sign In with \(providerName)"
        case .provider: return "Provider · \(providerName)"
        case .cancel: return "Cancel this sign-in"
        }
    }

    /// Only the cancel button works while a code is up; the rest wait for a running sign-in.
    func isEnabled(_ button: Button) -> Bool {
        button == .cancel || !isAuthenticating
    }

    var statusIsError: Bool { error != nil }

    var statusText: String { error ?? phase ?? "No password is entered in OpenNOW" }

    /// "m:ss" until `expiresAt`, rounded up like the Qt screen so it reads 0:00 only at expiry.
    static func countdown(until expiresAt: Date, now: Date) -> String {
        let seconds = max(0, Int(expiresAt.timeIntervalSince(now).rounded(.up)))
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }

    /// The verification address as shown under the code: host and path. The query repeats the
    /// code and would wrap the line.
    static func hostText(for url: URL) -> String {
        (url.host() ?? "") + url.path()
    }
}
