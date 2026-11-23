// FineTune/Views/HUD/ClassicStyleHUD.swift
import SwiftUI

/// 200×200 pre-Tahoe-style volume HUD: 80 pt glyph, 16-tile segment row and the percentage.
/// As in macOS's own, the tiles are light on a dark strip and fill by quarters: a level between
/// two tiles lights part of the next one. Stateless.
struct ClassicStyleHUD: View {
    let sliderFraction: Float
    let mute: Bool

    // MARK: - Constants

    static let hasPercentageLabel: Bool = true

    private static let tileCount: Int = 16
    private static let frameSize: CGFloat = 200
    /// Also the corner of the blur AppKit draws behind it
    static let cornerRadius: CGFloat = 16
    private static let iconSize: CGFloat = 80
    private static let tileSize: CGFloat = 8.25
    /// The strip between the tiles and around them
    private static let tileGap: CGFloat = 1.5
    /// A tile lights by quarters, as in macOS's own HUD
    private static let tileSteps: Float = 4

    @Environment(\.hudOnGlass) private var onGlass
    @Environment(\.colorScheme) private var colorScheme

    private var palette: HUDPalette {
        HUDPalette(onGlass: onGlass, colorScheme: colorScheme)
    }

    // MARK: - Derived state

    private var displayValue: Float {
        mute ? 0 : max(0, min(1, sliderFraction))
    }

    private var displayedPercent: Int {
        Int((displayValue * 100).rounded())
    }

    /// How much of a tile is lit, from 0 to 1, by quarters.
    private func litFraction(ofTile index: Int) -> CGFloat {
        let quarters = (displayValue * Float(Self.tileCount) * Self.tileSteps).rounded()
        let lit = quarters / Self.tileSteps - Float(index)
        return CGFloat(max(0, min(1, lit)))
    }

    private var waveIconName: String {
        switch displayedPercent {
        case 0:        return "speaker.fill"
        case 1...33:   return "speaker.wave.1.fill"
        case 34...66:  return "speaker.wave.2.fill"
        default:       return "speaker.wave.3.fill"
        }
    }

    /// `speaker.slash.fill` sits 2pt high vs the rest of the `speaker.*` glyphs at 80pt.
    private var iconYOffset: CGFloat {
        (mute || displayedPercent == 0) ? 2 : 0
    }

    #if DEBUG
    var waveIconNameForTest: String { waveIconName }
    #endif

    private var accessibilityDescription: String {
        if mute { return "Muted" }
        return "Volume \(Int((displayValue * 100).rounded())) percent"
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            iconSection
            tileSection
        }
        .frame(width: Self.frameSize, height: Self.frameSize)
        .hudOutline(cornerRadius: Self.cornerRadius)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var iconSection: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 56)
            // Hard-swap — symbolEffect(.replace.*) cross-fades the whole wave glyph on every bin change.
            Image(systemName: mute ? "speaker.slash.fill" : waveIconName)
                .font(.system(size: Self.iconSize, weight: .medium))
                .foregroundStyle(palette.text)
                .offset(y: iconYOffset)
            Spacer()
        }
        .frame(height: 100)
    }

    private var tileSection: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 26)
            HStack(spacing: Self.tileGap) {
                ForEach(0..<Self.tileCount, id: \.self) { index in
                    Rectangle()
                        .fill(palette.litTile)
                        .frame(width: Self.tileSize * litFraction(ofTile: index), height: Self.tileSize)
                        .frame(width: Self.tileSize, alignment: .leading)
                }
            }
            .padding(Self.tileGap)
            .background(Rectangle().fill(palette.tileStrip))
            Text(mute ? "Muted" : "\(displayedPercent)%")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(palette.text)
                .padding(.top, 10)
            Spacer(minLength: 0)
        }
        .frame(height: 80)
    }
}

#Preview("Classic — mid volume") {
    ClassicStyleHUD(sliderFraction: 0.5, mute: false)
        .padding()
        .background(Color.black)
}

#Preview("Classic — muted") {
    ClassicStyleHUD(sliderFraction: 0.5, mute: true)
        .padding()
        .background(Color.black)
}

#Preview("Classic — max volume") {
    ClassicStyleHUD(sliderFraction: 1.0, mute: false)
        .padding()
        .background(Color.black)
}

#Preview("Classic — zero volume") {
    ClassicStyleHUD(sliderFraction: 0.0, mute: false)
        .padding()
        .background(Color.black)
}
