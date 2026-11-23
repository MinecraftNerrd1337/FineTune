// FineTuneTests/ZoomViewportTests.swift
import AppKit
import Foundation
import Testing
@testable import FineTune

@Suite("ZoomViewport — the part of the screen macOS Zoom shows")
@MainActor
struct ZoomViewportTests {
    /// A 1440 × 900 main display with a 24-point menu bar
    private let main = (frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
                        visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 876))

    @Test("Without magnification there is no zoomed area")
    func unzoomed() {
        #expect(ZoomViewport.area(center: NSPoint(x: 720, y: 450), factor: 1, screens: [main]) == nil)
    }

    @Test("At 2×, a quarter of the screen around the center shows")
    func centered() {
        let area = ZoomViewport.area(center: NSPoint(x: 720, y: 450), factor: 2, screens: [main])
        #expect(area?.visibleRect == NSRect(x: 360, y: 225, width: 720, height: 450))
        #expect(area?.factor == 2)
    }

    @Test("In a corner, the area stays on the screen and below the menu bar")
    func corner() {
        let area = ZoomViewport.area(center: NSPoint(x: 1439, y: 899), factor: 2, screens: [main])
        #expect(area?.visibleRect == NSRect(x: 720, y: 450, width: 720, height: 426))
    }

    @Test("On a second display, the area is taken from that display")
    func secondDisplay() {
        let second = (frame: NSRect(x: 1440, y: 0, width: 1920, height: 1080),
                      visibleFrame: NSRect(x: 1440, y: 0, width: 1920, height: 1080))
        let area = ZoomViewport.area(center: NSPoint(x: 2400, y: 540), factor: 4, screens: [main, second])
        #expect(area?.visibleRect == NSRect(x: 2160, y: 405, width: 480, height: 270))
    }

    @Test("Under Zoom, the corner HUD's margin shrinks by the magnification")
    func marginScale() {
        let rect = NSRect(x: 360, y: 225, width: 720, height: 450)
        let size = NSSize(width: 300, height: 72)
        let point = HUDWindowController.computePosition(
            style: .tahoe, size: size, visibleFrame: rect, suppressionDegraded: false, marginScale: 2
        )
        #expect(point == NSPoint(x: rect.maxX - size.width - 4, y: rect.maxY - size.height - 4))
    }

    @Test("Absolute Position defaults to off, and a settings file without it reads off")
    func absolutePositionDefault() throws {
        #expect(AppSettings().hudAbsolutePosition == false)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(decoded.hudAbsolutePosition == false)
    }
}
