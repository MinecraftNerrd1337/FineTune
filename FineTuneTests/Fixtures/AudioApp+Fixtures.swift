// FineTuneTests/Fixtures/AudioApp+Fixtures.swift
//
// Test fixtures for AudioApp creation.

import Foundation
import AppKit
@testable import FineTune

extension AudioApp {
    /// Create a test AudioApp with sensible defaults.
    static func fixture(
        id: pid_t = pid_t(Int32.random(in: 1000...99999)),
        name: String = "TestApp",
        bundleID: String? = "com.test.app"
    ) -> AudioApp {
        AudioApp(
            id: id,
            processObjectIDs: [],
            name: name,
            icon: NSImage(),
            bundleID: bundleID
        )
    }
}
