// FineTuneTests/HUDThresholdTests.swift
// Verifies wave-icon glyph selection mirrors what the user sees on the bar/label
// (displayed integer percent), not internal float thresholds.

import Testing
import SwiftUI
@testable import FineTune

/// The Tahoe HUD's glyph for a slider fraction, through its static mapping: building the view
/// and reading its icon would read its @State outside a view hierarchy.
private func tahoeIcon(_ fraction: Float) -> String {
    TahoeStyleHUD.waveIconName(percent: TahoeStyleHUD.displayedPercent(fraction))
}

@Suite("HUD wave-icon thresholds use displayed-percent semantics")
struct HUDThresholdTests {
    @Test("Tahoe icon: 0% → speaker.fill (muted glyph)")
    func tahoeZeroPercent() {
        #expect(tahoeIcon(0) == "speaker.fill")
    }

    @Test("Tahoe icon: 33% → wave.1")
    func tahoeLow() {
        #expect(tahoeIcon(0.33) == "speaker.wave.1.fill")
    }

    @Test("Tahoe icon: 50% → wave.2")
    func tahoeMid() {
        #expect(tahoeIcon(0.50) == "speaker.wave.2.fill")
    }

    @Test("Tahoe icon: 67% → wave.3")
    func tahoeHigh() {
        #expect(tahoeIcon(0.67) == "speaker.wave.3.fill")
    }

    @Test("Tahoe icon: 100% → wave.3")
    func tahoeMax() {
        #expect(tahoeIcon(1.0) == "speaker.wave.3.fill")
    }

    @Test("Classic icon: 0% → speaker.fill")
    func classicZeroPercent() {
        let hud = ClassicStyleHUD(sliderFraction: 0, mute: false)
        #expect(hud.waveIconNameForTest == "speaker.fill")
    }

    @Test("Classic icon: 33% → wave.1")
    func classicLow() {
        let hud = ClassicStyleHUD(sliderFraction: 0.33, mute: false)
        #expect(hud.waveIconNameForTest == "speaker.wave.1.fill")
    }
}
