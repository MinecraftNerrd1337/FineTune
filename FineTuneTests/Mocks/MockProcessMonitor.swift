// FineTuneTests/Mocks/MockProcessMonitor.swift
//
// Mock implementation of AudioProcessMonitoring for testing.

import Foundation
@testable import FineTune

/// Mock implementation of AudioProcessMonitoring for testing.
@MainActor
final class MockProcessMonitor: AudioProcessMonitoring {
    var activeApps: [AudioApp] = []
    var onAppsChanged: (([AudioApp]) -> Void)?

    func start() {}
    func stop() {}

    /// Simulate an app becoming active.
    func simulateAppActive(_ app: AudioApp) {
        activeApps.append(app)
        onAppsChanged?(activeApps)
    }

    /// Simulate an app becoming inactive.
    func simulateAppInactive(appID: pid_t) {
        activeApps.removeAll { $0.id == appID }
        onAppsChanged?(activeApps)
    }
}
