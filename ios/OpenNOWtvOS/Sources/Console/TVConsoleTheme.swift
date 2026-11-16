import SwiftUI
import UIKit
import CoreText

/// Tokens of the Qt client's console shell (`opennow-qt/qml/theme/Theme.qml`, "Nocturne" pack).
/// That shell is laid out on a 1920x1080 canvas, which is the tvOS point space, so every size in
/// the console views is the Qt value unchanged.
enum TVConsoleTheme {
    static let shell = Color(hex: 0x0B0F1A)
    static let face = Color.white
    static let faceText = Color(hex: 0x111827)
    static let label = Color.white
    static let textMuted = Color.white.opacity(0.64)
    static let seam = Color.white.opacity(0.14)
    static let mint = Color(hex: 0x6EE7B7)
    static let violet = Color(hex: 0xA78BFA)
    static let coral = Color(hex: 0xFF8A80)
    static let yellow = Color(hex: 0xFFD166)
    static let glass = shell.opacity(0.72)
    static let glassStrong = shell.opacity(0.94)
    /// Sheet panels: the shell lifted by 3% white (`ConsoleSheetFrame.qml`).
    static let sheet = Color(hex: 0x12161F)
    static let scrim = Color(.sRGB, red: 0.02, green: 0.027, blue: 0.047, opacity: 0.58)

    static let focusDuration = 0.14
    static let enterDuration = 0.26

    /// Tile colour behind missing artwork, by store (`ConsoleStores.color`).
    static func storeColor(_ storeKey: String?) -> Color {
        switch storeKey {
        case "steam": return Color(hex: 0x26364A)
        case "epic": return Color(hex: 0x1B1B1F)
        case "ubisoft": return Color(hex: 0x3A5BD9)
        case "xbox": return Color(hex: 0x107C41)
        case "gog": return Color(hex: 0x7B3FE4)
        case "battlenet": return Color(hex: 0x2E7CB8)
        default: return Color(hex: 0x252A35)
        }
    }

    /// Stores the asset catalog has a logo for (`Console/store-<key>`).
    static let storeIconKeys: Set<String> = ["steam", "epic", "ubisoft", "xbox", "gog", "battlenet", "ea"]

    /// The Qt client's store key for a storefront name as the catalog reports it.
    static func storeKey(_ store: String) -> String? {
        switch normalizeGameStore(store) {
        case "STEAM": return "steam"
        case "EPIC", "EGS", "EPIC_GAMES_STORE": return "epic"
        case "UBISOFT", "UBISOFT_CONNECT", "UPLAY": return "ubisoft"
        case "XBOX", "XBOX_GAME_PASS", "GAME_PASS", "MICROSOFT", "MICROSOFT_STORE": return "xbox"
        case "GOG", "GOG_COM": return "gog"
        case "BATTLENET", "BATTLE_NET", "BLIZZARD": return "battlenet"
        case "EA", "EA_APP", "ORIGIN": return "ea"
        default: return nil
        }
    }

    // MARK: Fonts

    /// Nunito, the Qt client's display and body face. `weight` is the CSS-style value Qt uses
    /// (600 demi-bold, 700 bold, 800 extra-bold, 900 black).
    static func display(_ size: CGFloat, weight: CGFloat = 900) -> Font {
        let key = FontKey(size: size, weight: weight)
        if let cached = displayFonts[key] { return cached }
        // 'wght', the weight axis of the variable font.
        let weightAxis = 0x7767_6874
        let descriptor = UIFontDescriptor(fontAttributes: [
            .family: "Nunito",
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [weightAxis: weight],
        ])
        let font = Font(UIFont(descriptor: descriptor, size: size))
        displayFonts[key] = font
        return font
    }

    /// IBM Plex Mono, used for eyebrows, badges and the status pill.
    static func mono(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "IBMPlexMono-Bold" : "IBMPlexMono-Medium", fixedSize: size)
    }

    private struct FontKey: Hashable {
        let size: CGFloat
        let weight: CGFloat
    }

    /// Views are built on the main thread only.
    private static var displayFonts: [FontKey: Font] = [:]
}

// MARK: - Surfaces

extension View {
    /// `GlassPanel.qml`: a translucent shell-coloured panel with a hairline seam.
    func tvConsoleGlass(radius: CGFloat, strong: Bool = false, fill: Color? = nil) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius)
                .fill(fill ?? (strong ? TVConsoleTheme.glassStrong : TVConsoleTheme.glass))
                .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(TVConsoleTheme.seam, lineWidth: 1) }
        }
    }
}

/// `FocusFrame.qml`: a hairline at rest, a white border with an accent ring when focused, and a
/// thinner border while the item is "parked" (still current, but focus is in a menu above it).
struct TVConsoleFocusFrame: View {
    let focused: Bool
    var parked = false
    let radius: CGFloat

    @Environment(\.openNowAccent) private var accent

    var body: some View {
        ZStack {
            if focused && !parked {
                RoundedRectangle(cornerRadius: radius + 5)
                    .strokeBorder(accent.color.opacity(0.45), lineWidth: 5)
                    .padding(-5)
            }
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(
                    focused ? TVConsoleTheme.face.opacity(parked ? 0.7 : 1) : TVConsoleTheme.seam,
                    lineWidth: focused ? (parked ? 2 : 3) : 1
                )
        }
        .allowsHitTesting(false)
    }
}

/// A button whose whole appearance, including focus, comes from its label. Without this the
/// system draws its own lift-and-halo focus effect, which the console shell replaces.
struct TVConsolePlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.86 : 1)
    }
}
