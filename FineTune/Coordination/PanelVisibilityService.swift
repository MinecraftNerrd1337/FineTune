// FineTune/Audio/Keys/PanelVisibilityService.swift
import Foundation

/// `true` while the menu-bar panel is visible. Read by the HUD to skip overlay display.
@Observable
@MainActor
final class PanelVisibilityService {
    var isVisible: Bool = false
}
