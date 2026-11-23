// FineTuneTests/MenuBarPanelSizeTests.swift
import Testing
import Foundation
@testable import FineTune

@Suite("MenuBarPanelSize — Codable round-trip")
struct MenuBarPanelSizeCodableTests {

    @Test("All cases round-trip through JSON as their raw String value")
    func roundTripAllCases() throws {
        for size in MenuBarPanelSize.allCases {
            let data = try JSONEncoder().encode(size)
            let decoded = try JSONDecoder().decode(MenuBarPanelSize.self, from: data)
            #expect(decoded == size)
        }
    }

    @Test("compact encodes as \"compact\"")
    func compactRawEncoding() throws {
        let data = try JSONEncoder().encode(MenuBarPanelSize.compact)
        let s = String(data: data, encoding: .utf8)
        #expect(s == "\"compact\"")
    }

    @Test("comfortable encodes as \"comfortable\"")
    func comfortableRawEncoding() throws {
        let data = try JSONEncoder().encode(MenuBarPanelSize.comfortable)
        let s = String(data: data, encoding: .utf8)
        #expect(s == "\"comfortable\"")
    }

    @Test("spacious encodes as \"spacious\"")
    func spaciousRawEncoding() throws {
        let data = try JSONEncoder().encode(MenuBarPanelSize.spacious)
        let s = String(data: data, encoding: .utf8)
        #expect(s == "\"spacious\"")
    }

    @Test("AppSettings.panelSize defaults to .comfortable when key is missing")
    func defaultMissingKey() throws {
        let json = "{}"
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.panelSize == .comfortable)
    }

    @Test("AppSettings.panelSize round-trips through full JSON")
    func roundTripThroughAppSettings() throws {
        var settings = AppSettings()
        settings.panelSize = .spacious

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.panelSize == .spacious)
    }
}

@Suite("MenuBarPanelSize — Dimensions resolution")
struct MenuBarPanelSizeDimensionsTests {

    @Test("compact resolves to the narrow / tight preset")
    func compactDimensions() {
        let d = MenuBarPanelSize.compact.dimensions
        #expect(d.width == 470)
        #expect(d.contentPadding == 12)
        #expect(d.maxContentHeight == 560)
    }

    @Test("comfortable resolves to the middle preset")
    func comfortableDimensions() {
        let d = MenuBarPanelSize.comfortable.dimensions
        #expect(d.width == 510)
        #expect(d.contentPadding == 16)
        #expect(d.maxContentHeight == 660)
    }

    @Test("spacious resolves to the wider / roomier preset")
    func spaciousDimensions() {
        let d = MenuBarPanelSize.spacious.dimensions
        #expect(d.width == 560)
        #expect(d.contentPadding == 20)
        #expect(d.maxContentHeight == 760)
    }

    @Test("widths are strictly increasing across the three cases")
    func widthsMonotonic() {
        let widths = MenuBarPanelSize.allCases.map { $0.dimensions.width }
        #expect(widths == widths.sorted())
        #expect(Set(widths).count == widths.count)
    }

    @Test("maxContentHeight is strictly increasing across the three cases")
    func maxContentHeightMonotonic() {
        let heights = MenuBarPanelSize.allCases.map { $0.dimensions.maxContentHeight }
        #expect(heights == heights.sorted())
        #expect(Set(heights).count == heights.count)
    }

    @Test("maxContentHeight fits inside a 13\" MacBook usable height (~860pt)")
    func maxContentHeightFitsSmallestScreen() {
        for size in MenuBarPanelSize.allCases {
            #expect(size.dimensions.maxContentHeight <= 800)
        }
    }
}
