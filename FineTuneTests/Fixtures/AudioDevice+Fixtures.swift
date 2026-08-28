// FineTuneTests/Fixtures/AudioDevice+Fixtures.swift
//
// Test fixtures for AudioDevice creation.

import Foundation
import AppKit
import AudioToolbox
@testable import FineTune

extension AudioDevice {
    /// Create a test AudioDevice with sensible defaults.
    static func fixture(
        id: AudioDeviceID = AudioDeviceID(99),
        uid: String = "uid-test-\(UUID().uuidString.prefix(8))",
        name: String = "Test Device",
        icon: NSImage? = nil,
        supportsAutoEQ: Bool = true
    ) -> AudioDevice {
        AudioDevice(
            id: id,
            uid: uid,
            name: name,
            icon: icon,
            supportsAutoEQ: supportsAutoEQ
        )
    }

    /// Create a Bluetooth test device.
    static func bluetoothFixture(
        id: AudioDeviceID = AudioDeviceID(100),
        uid: String = "uid-bt-\(UUID().uuidString.prefix(8))",
        name: String = "Bluetooth Device"
    ) -> AudioDevice {
        AudioDevice(
            id: id,
            uid: uid,
            name: name,
            icon: nil,
            supportsAutoEQ: false
        )
    }

    /// Create a USB test device.
    static func usbFixture(
        id: AudioDeviceID = AudioDeviceID(101),
        uid: String = "uid-usb-\(UUID().uuidString.prefix(8))",
        name: String = "USB Device"
    ) -> AudioDevice {
        AudioDevice(
            id: id,
            uid: uid,
            name: name,
            icon: nil,
            supportsAutoEQ: true
        )
    }
}
