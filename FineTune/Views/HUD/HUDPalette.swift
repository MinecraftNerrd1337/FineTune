// FineTune/Views/HUD/HUDPalette.swift
import SwiftUI

extension EnvironmentValues {
    /// Whether the volume HUD is drawn on Liquid Glass rather than on a blur
    @Entry var hudOnGlass = false
}

/// The colors of a volume HUD's text and glyphs. On the blur, FineTune's own, which follow its
/// appearance. On Liquid Glass, black or white with it, of fixed opacity: there, label colors
/// such as primary and secondary are drawn vibrant, letting the glass through, and small glyphs
/// like the square HUD's tiles came out pale and see-through.
struct HUDPalette {
    let onGlass: Bool
    let colorScheme: ColorScheme

    private var ink: Color {
        colorScheme == .dark ? .white : .black
    }

    /// The device or app name, and the square HUD's speaker and percentage
    var text: Color {
        onGlass ? ink : DesignTokens.Colors.textPrimary
    }

    /// The speaker next to a bar
    var glyph: Color {
        onGlass ? ink.opacity(0.85) : DesignTokens.Colors.hudTileActive
    }

    /// The percentage and other details next to a bar
    var detail: Color {
        onGlass ? ink.opacity(0.75) : DesignTokens.Colors.textSecondary
    }

    /// The square HUD's tiles, up to the level and past it
    var litTile: Color {
        onGlass ? ink : .primary
    }

    var unlitTile: Color {
        onGlass ? ink.opacity(0.25) : .primary.opacity(0.25)
    }
}
