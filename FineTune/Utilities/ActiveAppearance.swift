// FineTune/Utilities/ActiveAppearance.swift
import AppKit

extension NSWindow {
    /// Draws the window as an active one even while another app has the keyboard, as a panel or
    /// a HUD should: otherwise its Liquid Glass turns to gray frost and its controls go flat.
    /// AppKit has no public switch for it (NSVisualEffectView's `state = .active` only covers the
    /// older blur), so this calls AppKit's private one, and does nothing if it is gone.
    func keepActiveAppearance() {
        let selector = NSSelectorFromString("_setForceMainAppearance:")
        guard let method = class_getInstanceMethod(type(of: self), selector) else { return }
        typealias Setter = @convention(c) (NSWindow, Selector, ObjCBool) -> Void
        let setter = unsafeBitCast(method_getImplementation(method), to: Setter.self)
        setter(self, selector, ObjCBool(true))
    }
}
