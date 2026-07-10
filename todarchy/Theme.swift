import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import CoreText

// MARK: - Palette

/// Every color the app consumes. Add a new palette by defining a static
/// constant and registering it in `named(_:)`.
struct ThemePalette: Equatable {
    // Backgrounds
    let bg: Color
    let bgElev: Color
    let bgSoft: Color
    let panel: Color

    // Borders
    let border: Color
    let borderHi: Color

    // Foregrounds
    let fg: Color
    let fgDim: Color
    let fgMute: Color
    let fgFaint: Color

    // Accents + semantics
    let accent: Color
    let accent2: Color
    let success: Color
    let warn: Color
    let danger: Color
    let cyan: Color
    let orange: Color
    let blue: Color
    let purple: Color

    /// Name used to persist the selection in UserDefaults.
    let id: String

    /// Currently-active palette. Views read through the `Theme` accessors which
    /// tunnel here; changing this value will not automatically re-render SwiftUI
    /// — the root view pins `.id(ThemePalette.current.id)` to force a rebuild
    /// on change.
    static var current: ThemePalette = .tokyoNight

    static func named(_ id: String) -> ThemePalette {
        switch id {
        case ThemePalette.catppuccin.id: return .catppuccin
        case ThemePalette.gruvbox.id: return .gruvbox
        case ThemePalette.ubuntu.id: return .ubuntu
        case ThemePalette.osakaJade.id: return .osakaJade
        case ThemePalette.catppuccinLatte.id: return .catppuccinLatte
        case ThemePalette.pulsar.id: return .pulsar
        case ThemePalette.archwave.id: return .archwave
        default: return .tokyoNight
        }
    }

    static let allPalettes: [ThemePalette] = [
        .tokyoNight, .catppuccin, .gruvbox, .ubuntu,
        .osakaJade, .catppuccinLatte, .pulsar, .archwave,
    ]
}

// MARK: - Built-in palettes

extension ThemePalette {
    static let tokyoNight = ThemePalette(
        bg: Color(hex: 0x1A1B26),
        bgElev: Color(hex: 0x16171F),
        bgSoft: Color(hex: 0x1F2030),
        panel: Color(hex: 0x1F2335),
        border: Color(hex: 0x2A2E42),
        borderHi: Color(hex: 0x3B4261),
        fg: Color(hex: 0xC0CAF5),
        fgDim: Color(hex: 0x9AA5CE),
        fgMute: Color(hex: 0x565F89),
        fgFaint: Color(hex: 0x3B4261),
        accent: Color(hex: 0x7AA2F7),
        accent2: Color(hex: 0xBB9AF7),
        success: Color(hex: 0x9ECE6A),
        warn: Color(hex: 0xE0AF68),
        danger: Color(hex: 0xF7768E),
        cyan: Color(hex: 0x7DCFFF),
        orange: Color(hex: 0xFF9E64),
        blue: Color(hex: 0x7AA2F7),
        purple: Color(hex: 0xBB9AF7),
        id: "tokyoNight"
    )

    static let catppuccin = ThemePalette(
        bg: Color(hex: 0x1E1E2E),
        bgElev: Color(hex: 0x181825),
        bgSoft: Color(hex: 0x242437),
        panel: Color(hex: 0x282838),
        border: Color(hex: 0x313244),
        borderHi: Color(hex: 0x45475A),
        fg: Color(hex: 0xCDD6F4),
        fgDim: Color(hex: 0xBAC2DE),
        fgMute: Color(hex: 0x6C7086),
        fgFaint: Color(hex: 0x45475A),
        accent: Color(hex: 0x89B4FA),
        accent2: Color(hex: 0xCBA6F7),
        success: Color(hex: 0xA6E3A1),
        warn: Color(hex: 0xF9E2AF),
        danger: Color(hex: 0xF38BA8),
        cyan: Color(hex: 0x89DCEB),
        orange: Color(hex: 0xFAB387),
        blue: Color(hex: 0x89B4FA),
        purple: Color(hex: 0xCBA6F7),
        id: "catppuccin"
    )

    static let gruvbox = ThemePalette(
        bg: Color(hex: 0x1D2021),
        bgElev: Color(hex: 0x282828),
        bgSoft: Color(hex: 0x32302F),
        panel: Color(hex: 0x3C3836),
        border: Color(hex: 0x504945),
        borderHi: Color(hex: 0x665C54),
        fg: Color(hex: 0xEBDBB2),
        fgDim: Color(hex: 0xD5C4A1),
        fgMute: Color(hex: 0x928374),
        fgFaint: Color(hex: 0x504945),
        accent: Color(hex: 0xFABD2F),
        accent2: Color(hex: 0xD3869B),
        success: Color(hex: 0xB8BB26),
        warn: Color(hex: 0xFABD2F),
        danger: Color(hex: 0xFB4934),
        cyan: Color(hex: 0x83A598),
        orange: Color(hex: 0xFE8019),
        blue: Color(hex: 0x83A598),
        purple: Color(hex: 0xD3869B),
        id: "gruvbox"
    )

    static let ubuntu = ThemePalette(
        bg: Color(hex: 0x0A0A0F),
        bgElev: Color(hex: 0x14141C),
        bgSoft: Color(hex: 0x1C1C26),
        panel: Color(hex: 0x22222E),
        border: Color(hex: 0x26262F),
        borderHi: Color(hex: 0x34343F),
        fg: Color(hex: 0xECEAEA),
        fgDim: Color(hex: 0xD9D9D9),
        fgMute: Color(hex: 0xAEA79F),
        fgFaint: Color(hex: 0x6B5B6B),
        accent: Color(hex: 0xE95420),
        accent2: Color(hex: 0xDD4814),
        success: Color(hex: 0xA6D98E),
        warn: Color(hex: 0xF9C784),
        danger: Color(hex: 0xEF6C6C),
        cyan: Color(hex: 0x9CD3E3),
        orange: Color(hex: 0xE95420),
        blue: Color(hex: 0x7AA2F7),
        purple: Color(hex: 0xBB9AF7),
        id: "ubuntu"
    )

    // Colors sourced from the upstream Omarchy theme palettes
    // (basecamp/omarchy + community repos); backgrounds/greys derived to
    // fit todokase's bg/panel/border layering.
    static let osakaJade = ThemePalette(
        bg: Color(hex: 0x111C18),
        bgElev: Color(hex: 0x0D1712),
        bgSoft: Color(hex: 0x18251F),
        panel: Color(hex: 0x1B2A23),
        border: Color(hex: 0x23372B),
        borderHi: Color(hex: 0x53685B),
        fg: Color(hex: 0xC1C497),
        fgDim: Color(hex: 0xA7AA84),
        fgMute: Color(hex: 0x6E8377),
        fgFaint: Color(hex: 0x3E5046),
        accent: Color(hex: 0x509475),
        accent2: Color(hex: 0x75BBB3),
        success: Color(hex: 0x63B07A),
        warn: Color(hex: 0xE5C736),
        danger: Color(hex: 0xFF5345),
        cyan: Color(hex: 0x2DD5B7),
        orange: Color(hex: 0xDB9F9C),
        blue: Color(hex: 0x509475),
        purple: Color(hex: 0xD2689C),
        id: "osakaJade"
    )

    // Catppuccin Latte — the light theme. Standard Latte palette.
    static let catppuccinLatte = ThemePalette(
        bg: Color(hex: 0xEFF1F5),
        bgElev: Color(hex: 0xE6E9EF),
        bgSoft: Color(hex: 0xDCE0E8),
        panel: Color(hex: 0xE6E9EF),
        border: Color(hex: 0xCCD0DA),
        borderHi: Color(hex: 0xBCC0CC),
        fg: Color(hex: 0x4C4F69),
        fgDim: Color(hex: 0x5C5F77),
        fgMute: Color(hex: 0x6C6F85),
        fgFaint: Color(hex: 0x9CA0B0),
        accent: Color(hex: 0x1E66F5),
        accent2: Color(hex: 0x8839EF),
        success: Color(hex: 0x40A02B),
        warn: Color(hex: 0xDF8E1D),
        danger: Color(hex: 0xD20F39),
        cyan: Color(hex: 0x179299),
        orange: Color(hex: 0xFE640B),
        blue: Color(hex: 0x1E66F5),
        purple: Color(hex: 0x8839EF),
        id: "catppuccinLatte"
    )

    static let pulsar = ThemePalette(
        bg: Color(hex: 0x0A0314),
        bgElev: Color(hex: 0x070210),
        bgSoft: Color(hex: 0x160A26),
        panel: Color(hex: 0x1D0F30),
        border: Color(hex: 0x2E1A47),
        borderHi: Color(hex: 0x4A2E6B),
        fg: Color(hex: 0xE0E6FF),
        fgDim: Color(hex: 0xB8BFE0),
        fgMute: Color(hex: 0x8F86B5),
        fgFaint: Color(hex: 0x4E4470),
        accent: Color(hex: 0xB82AFF),
        accent2: Color(hex: 0x3298FA),
        success: Color(hex: 0x70D674),
        warn: Color(hex: 0xF2E42E),
        danger: Color(hex: 0xFF5779),
        cyan: Color(hex: 0x3DF2F2),
        orange: Color(hex: 0xFF7A59),
        blue: Color(hex: 0x3298FA),
        purple: Color(hex: 0xB82AFF),
        id: "pulsar"
    )

    static let archwave = ThemePalette(
        bg: Color(hex: 0x1A0D2E),
        bgElev: Color(hex: 0x140A24),
        bgSoft: Color(hex: 0x241640),
        panel: Color(hex: 0x2D1B4E),
        border: Color(hex: 0x3A2560),
        borderHi: Color(hex: 0x543A6E),
        fg: Color(hex: 0xD4A5FF),
        fgDim: Color(hex: 0xBE9BE6),
        fgMute: Color(hex: 0x8A6FB0),
        fgFaint: Color(hex: 0x543A6E),
        accent: Color(hex: 0xF4A5FF),
        accent2: Color(hex: 0x8B9AFF),
        success: Color(hex: 0x8FFEF4),
        warn: Color(hex: 0xF9F871),
        danger: Color(hex: 0xFF6EC7),
        cyan: Color(hex: 0x5FFBF1),
        orange: Color(hex: 0xFF9E7A),
        blue: Color(hex: 0x8B9AFF),
        purple: Color(hex: 0xF4A5FF),
        id: "archwave"
    )
}

// MARK: - Theme accessor

/// Thin shim over `ThemePalette.current` so callers can say `Theme.bg`.
enum Theme {
    static var bg: Color { ThemePalette.current.bg }
    static var bgElev: Color { ThemePalette.current.bgElev }
    static var bgSoft: Color { ThemePalette.current.bgSoft }
    static var panel: Color { ThemePalette.current.panel }
    static var border: Color { ThemePalette.current.border }
    static var borderHi: Color { ThemePalette.current.borderHi }
    static var fg: Color { ThemePalette.current.fg }
    static var fgDim: Color { ThemePalette.current.fgDim }
    static var fgMute: Color { ThemePalette.current.fgMute }
    static var fgFaint: Color { ThemePalette.current.fgFaint }
    static var accent: Color { ThemePalette.current.accent }
    static var accent2: Color { ThemePalette.current.accent2 }
    static var success: Color { ThemePalette.current.success }
    static var warn: Color { ThemePalette.current.warn }
    static var danger: Color { ThemePalette.current.danger }
    static var cyan: Color { ThemePalette.current.cyan }
    static var orange: Color { ThemePalette.current.orange }
    static var blue: Color { ThemePalette.current.blue }
    static var purple: Color { ThemePalette.current.purple }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    /// Round-trip the color to an RRGGBB integer for persistence.
    var argbHex: UInt32 {
        let c = components
        let r = UInt32(max(0, min(255, Int(c.r * 255))))
        let g = UInt32(max(0, min(255, Int(c.g * 255))))
        let b = UInt32(max(0, min(255, Int(c.b * 255))))
        return (r << 16) | (g << 8) | b
    }

    /// Mix `self` with `other` by amount (0…1).
    func mix(_ other: Color, by t: Double) -> Color {
        let a = self.components
        let b = other.components
        return Color(.sRGB,
                     red: a.r * (1 - t) + b.r * t,
                     green: a.g * (1 - t) + b.g * t,
                     blue: a.b * (1 - t) + b.b * t,
                     opacity: a.a * (1 - t) + b.a * t)
    }

    fileprivate var components: (r: Double, g: Double, b: Double, a: Double) {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
        #else
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        return (Double(ns.redComponent), Double(ns.greenComponent),
                Double(ns.blueComponent), Double(ns.alphaComponent))
        #endif
    }
}

// MARK: - Typography

enum Typo {
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .medium: name = "JetBrainsMono-Medium"
        case .semibold: name = "JetBrainsMono-SemiBold"
        case .bold, .heavy, .black: name = "JetBrainsMono-Bold"
        default: name = "JetBrainsMono-Regular"
        }
        return .custom(name, size: size, relativeTo: .body)
    }

    static func monoFallback(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Font registration

enum FontRegistrar {
    static let faces = [
        "JetBrainsMono-Regular",
        "JetBrainsMono-Medium",
        "JetBrainsMono-SemiBold",
        "JetBrainsMono-Bold",
    ]

    static func register() {
        for name in faces {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else {
                continue
            }
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        }
    }
}
