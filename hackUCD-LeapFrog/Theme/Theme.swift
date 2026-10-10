import SwiftUI
import UIKit

/// TFI-inspired palette: white surfaces with Transport for Ireland's dark green.
enum Theme {
    /// Primary TFI green, as used across transportforireland.ie.
    static let greenUI = UIColor(hex: 0x018555)
    /// The brighter green from the TFI roundel, used for "live" accents.
    static let brightGreenUI = UIColor(hex: 0x00B274)
    static let inkUI = UIColor(hex: 0x0E2A1F)

    static let green = Color(greenUI)
    static let brightGreen = Color(brightGreenUI)
    static let ink = Color(inkUI)
    static let secondaryInk = Color(UIColor(hex: 0x5B6B64))
    static let surface = Color.white
    static let canvas = Color(UIColor(hex: 0xF6F6F6))
    static let hairline = Color(UIColor(hex: 0xE3E8E5))

    static let luasRedUI = UIColor(hex: 0xE4002B)
    static let luasGreenUI = UIColor(hex: 0x00A651)

    static let cornerRadius: CGFloat = 22
}

extension TransportMode {
    var tintUI: UIColor {
        switch self {
        case .bus: Theme.greenUI
        case .luas: UIColor(hex: 0x5C2784)
        case .dart: UIColor(hex: 0x0F7C8A)
        }
    }

    var tint: Color { Color(tintUI) }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// White rounded card with a soft shadow, the base of all floating chrome.
struct CardBackground: ViewModifier {
    var radius: CGFloat = Theme.cornerRadius

    func body(content: Content) -> some View {
        content
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Theme.hairline, lineWidth: 0.5))
            .shadow(color: Theme.ink.opacity(0.12), radius: 14, y: 6)
    }
}

extension View {
    func card(radius: CGFloat = Theme.cornerRadius) -> some View {
        modifier(CardBackground(radius: radius))
    }
}
