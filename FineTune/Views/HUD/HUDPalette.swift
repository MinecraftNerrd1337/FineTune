// FineTune/Views/HUD/HUDPalette.swift
import AppKit
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

    /// The square HUD's tiles up to the level, light on a dark strip as in macOS's own HUD: the
    /// strip outlines them, and past the level it shows alone. Opaque, so they read on any
    /// background, on the glass as on the blur.
    var litTile: Color {
        colorScheme == .dark ? Color(white: 0.93) : .white
    }

    var tileStrip: Color {
        colorScheme == .dark ? Color(white: 0.16) : Color(white: 0.42)
    }

    /// The corner HUD's bar, up to the level and past it. On Liquid Glass, on a track of the
    /// ink: the faint track of the blur hardly showed on the glass, and an empty bar not at all.
    /// The fill is the accent color, which sets FineTune's HUD apart from macOS's.
    var barFill: Color {
        DesignTokens.Colors.accentPrimary
    }

    var barTrack: Color {
        onGlass ? ink.opacity(0.3) : DesignTokens.Colors.sliderTrack
    }

    /// As thin as the panel's sliders
    var barHeight: CGFloat {
        4
    }
}
