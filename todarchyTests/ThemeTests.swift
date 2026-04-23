import XCTest
import SwiftUI

final class ThemeTests: XCTestCase {

    func testAllPalettesHaveUniqueIds() {
        let ids = ThemePalette.allPalettes.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testNamedReturnsKnownPalettes() {
        XCTAssertEqual(ThemePalette.named("tokyoNight").id, "tokyoNight")
        XCTAssertEqual(ThemePalette.named("catppuccin").id, "catppuccin")
        XCTAssertEqual(ThemePalette.named("gruvbox").id, "gruvbox")
        XCTAssertEqual(ThemePalette.named("ubuntu").id, "ubuntu")
    }

    func testNamedUnknownFallsBackToTokyoNight() {
        XCTAssertEqual(ThemePalette.named("not-a-theme").id, "tokyoNight")
    }

    func testThemeAccessorReturnsCurrentPalette() {
        let original = ThemePalette.current
        defer { ThemePalette.current = original }

        ThemePalette.current = .catppuccin
        XCTAssertEqual(Theme.bg, ThemePalette.catppuccin.bg)
        XCTAssertEqual(Theme.accent, ThemePalette.catppuccin.accent)

        ThemePalette.current = .gruvbox
        XCTAssertEqual(Theme.bg, ThemePalette.gruvbox.bg)
    }

    func testPalettesAreDistinct() {
        XCTAssertNotEqual(ThemePalette.tokyoNight, ThemePalette.ubuntu)
        XCTAssertNotEqual(ThemePalette.catppuccin, ThemePalette.gruvbox)
    }
}
