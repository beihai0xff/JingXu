import AppKit
import JingXuCore
import SwiftUI

enum DarkroomPalette {
    /// `#141416` — Zero-hue-cast deep canvas for Loupe, Compare, Crop, and Darkroom Grid.
    static let canvasDeep = Color(.sRGB, red: 20.0 / 255.0, green: 20.0 / 255.0, blue: 22.0 / 255.0, opacity: 1.0)
    /// `#1C1C20` — Solid opaque panel surface for Sidebar, 40pt Toolbar, 64pt Filmstrip, and Inspector/Develop.
    static let panelSurface = Color(.sRGB, red: 28.0 / 255.0, green: 28.0 / 255.0, blue: 32.0 / 255.0, opacity: 1.0)
    /// `#26262B` — Elevated control tracks, segmented wells, value capsules, and metric cards.
    static let elevatedControl = Color(.sRGB, red: 38.0 / 255.0, green: 38.0 / 255.0, blue: 43.0 / 255.0, opacity: 1.0)
    /// `#121215` — Recessed optical well for interactive and reference histograms.
    static let histogramWell = Color(.sRGB, red: 18.0 / 255.0, green: 18.0 / 255.0, blue: 21.0 / 255.0, opacity: 1.0)
    /// `rgba(32, 32, 38, 0.90)` — Floating dock & Loupe HUD tint over ultra-thin material.
    static let floatingHUDFill = Color(.sRGB, red: 32.0 / 255.0, green: 32.0 / 255.0, blue: 38.0 / 255.0, opacity: 0.90)
    /// `#2E2E35` — 1pt neutral hairline divider.
    static let subtleDivider = Color(.sRGB, red: 46.0 / 255.0, green: 46.0 / 255.0, blue: 53.0 / 255.0, opacity: 1.0)
    /// `#0B0B0D` — 2pt seam between dual comparison canvases.
    static let comparisonSeam = Color(.sRGB, red: 11.0 / 255.0, green: 11.0 / 255.0, blue: 13.0 / 255.0, opacity: 1.0)

    static let textPrimary = Color(.sRGB, red: 242.0 / 255.0, green: 242.0 / 255.0, blue: 247.0 / 255.0, opacity: 1.0)
    static let textSecondary = Color(.sRGB, red: 152.0 / 255.0, green: 152.0 / 255.0, blue: 159.0 / 255.0, opacity: 1.0)
    static let textMuted = Color(.sRGB, red: 99.0 / 255.0, green: 99.0 / 255.0, blue: 104.0 / 255.0, opacity: 1.0)

    static let warningAmber = Color(.sRGB, red: 1.0, green: 159.0 / 255.0, blue: 10.0 / 255.0, opacity: 1.0)
    static let rejectCoral = Color(.sRGB, red: 1.0, green: 69.0 / 255.0, blue: 58.0 / 255.0, opacity: 1.0)
    static let readyGreen = Color(.sRGB, red: 48.0 / 255.0, green: 209.0 / 255.0, blue: 88.0 / 255.0, opacity: 1.0)

    static let lightGridSlotFill = Color(.sRGB, red: 242.0 / 255.0, green: 242.0 / 255.0, blue: 245.0 / 255.0, opacity: 1.0)
    static let lightGridSlotBorder = Color(.sRGB, red: 226.0 / 255.0, green: 226.0 / 255.0, blue: 232.0 / 255.0, opacity: 1.0)

    static func isDarkSurface(colorScheme: ColorScheme, appearance: AppAppearanceMode, stage: StudioStageMode = .grid) -> Bool {
        if appearance.forcesDarkStage(for: stage) { return true }
        return colorScheme == .dark
    }

    static func gridCanvasFill(colorScheme: ColorScheme, appearance: AppAppearanceMode) -> Color {
        isDarkSurface(colorScheme: colorScheme, appearance: appearance, stage: .grid)
            ? canvasDeep
            : Color(nsColor: .windowBackgroundColor)
    }

    static func gridSlotFill(colorScheme: ColorScheme, appearance: AppAppearanceMode) -> Color {
        isDarkSurface(colorScheme: colorScheme, appearance: appearance, stage: .grid)
            ? panelSurface
            : lightGridSlotFill
    }

    static func gridSlotBorder(colorScheme: ColorScheme, appearance: AppAppearanceMode) -> Color {
        isDarkSurface(colorScheme: colorScheme, appearance: appearance, stage: .grid)
            ? subtleDivider.opacity(0.65)
            : lightGridSlotBorder
    }

    static func chromeSurface(colorScheme: ColorScheme, appearance: AppAppearanceMode, stage: StudioStageMode) -> Color {
        isDarkSurface(colorScheme: colorScheme, appearance: appearance, stage: stage)
            ? panelSurface
            : Color(nsColor: .windowBackgroundColor)
    }

    static func hairline(colorScheme: ColorScheme, appearance: AppAppearanceMode, stage: StudioStageMode) -> Color {
        isDarkSurface(colorScheme: colorScheme, appearance: appearance, stage: stage)
            ? subtleDivider
            : lightGridSlotBorder
    }
}

private struct AppAppearanceModifier: ViewModifier {
    let mode: AppAppearanceMode

    func body(content: Content) -> some View {
        content.preferredColorScheme(mode == .darkroom ? .dark : nil)
    }
}

private struct DarkroomStageSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, .dark)
            .background(DarkroomPalette.canvasDeep)
    }
}

private struct DarkroomPanelSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, .dark)
            .background(DarkroomPalette.panelSurface)
    }
}

extension View {
    func appAppearance(_ mode: AppAppearanceMode) -> some View {
        modifier(AppAppearanceModifier(mode: mode))
    }

    func darkroomStageSurface() -> some View {
        modifier(DarkroomStageSurfaceModifier())
    }

    func darkroomPanelSurface() -> some View {
        modifier(DarkroomPanelSurfaceModifier())
    }
}
