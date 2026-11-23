// FineTune/Views/HUD/ZoomViewport.swift
import AppKit
import Darwin

/// The part of the screen macOS Zoom (Accessibility) shows while it magnifies the screen.
///
/// macOS has no API for it: this reads the window server's zoom parameters through
/// `CGSGetZoomParameters`, a private function looked up when first needed, so a macOS without it
/// leaves the HUD where it goes without Zoom. It only reads: it never changes Zoom.
@MainActor
enum ZoomViewport {
    /// What Zoom shows
    struct Area: Equatable {
        /// In AppKit screen coordinates, below the menu bar
        let visibleRect: NSRect
        /// How much Zoom magnifies, above 1
        let factor: CGFloat
    }

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias GetZoomParameters = @convention(c) (
        Int32, UnsafeMutablePointer<CGPoint>, UnsafeMutablePointer<Double>, UnsafeMutablePointer<Int8>
    ) -> Int32

    private struct Functions {
        let connection: MainConnection
        let getZoom: GetZoomParameters
    }

    private static let functions: Functions? = {
        // RTLD_DEFAULT: every image loaded in the process, CoreGraphics and SkyLight among them
        let loaded = UnsafeMutableRawPointer(bitPattern: -2)
        guard let connection = dlsym(loaded, "CGSMainConnectionID") ?? dlsym(loaded, "SLSMainConnectionID"),
              let getZoom = dlsym(loaded, "CGSGetZoomParameters") ?? dlsym(loaded, "SLSGetZoomParameters")
        else { return nil }
        return Functions(
            connection: unsafeBitCast(connection, to: MainConnection.self),
            getZoom: unsafeBitCast(getZoom, to: GetZoomParameters.self)
        )
    }()

    /// What Zoom shows now, nil while it doesn't magnify the screen
    static func current() -> Area? {
        guard let functions else { return nil }
        var center = CGPoint.zero
        var factor = 1.0
        var smoothed: Int8 = 0
        guard functions.getZoom(functions.connection(), &center, &factor, &smoothed) == 0,
              let mainHeight = NSScreen.screens.first?.frame.height else { return nil }
        // The window server counts from the top of the main display, AppKit from its bottom
        let point = NSPoint(x: center.x, y: mainHeight - center.y)
        return area(center: point, factor: factor, screens: NSScreen.screens.map { (frame: $0.frame, visibleFrame: $0.visibleFrame) })
    }

    /// What Zoom shows around `center` at `factor`: a part of the screen `center` lies on,
    /// smaller by `factor`, kept on that screen and below its menu bar. Nil without magnification.
    nonisolated static func area(
        center: NSPoint,
        factor: Double,
        screens: [(frame: NSRect, visibleFrame: NSRect)]
    ) -> Area? {
        guard factor.isFinite, factor > 1.001,
              let screen = screens.first(where: { $0.frame.contains(center) }) ?? screens.first
        else { return nil }
        let size = NSSize(width: screen.frame.width / factor, height: screen.frame.height / factor)
        let x = min(max(center.x - size.width / 2, screen.frame.minX), screen.frame.maxX - size.width)
        let y = min(max(center.y - size.height / 2, screen.frame.minY), screen.frame.maxY - size.height)
        let shown = NSRect(x: x, y: y, width: size.width, height: size.height)
        let belowMenuBar = shown.intersection(screen.visibleFrame)
        return Area(visibleRect: belowMenuBar.isEmpty ? shown : belowMenuBar, factor: CGFloat(factor))
    }
}
