//
//  FluidMenuBarExtraBehavior.swift
//  FluidMenuBarExtra
//
//  Added for FineTune; not part of upstream FluidMenuBarExtra 1.5.1.
//

import AppKit

/// App-wide switches for the menu bar window, set by the host app.
@MainActor
public enum FluidMenuBarExtraBehavior {
    /// Asked each time the window loses focus (click in another app or window).
    /// Return false to keep the window open; a click on the status item still closes it.
    public static var dismissesOnFocusLossProvider: @MainActor () -> Bool = { true }

    public static var dismissesOnFocusLoss: Bool { dismissesOnFocusLossProvider() }

    /// Called on every click of the status item, before the window opens or closes.
    /// The argument is true when the click is about to open the window.
    public static var onStatusItemPress: (@MainActor (_ willOpen: Bool) -> Void)?

    /// Close the menu bar window if it is open, whatever `dismissesOnFocusLoss` says.
    public static func dismiss() {
        current?.dismissWindowIfVisible()
    }

    static weak var current: FluidMenuBarExtraStatusItem?
}
