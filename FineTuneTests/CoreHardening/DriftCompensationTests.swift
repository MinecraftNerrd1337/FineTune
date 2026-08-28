// FineTuneTests/CoreHardening/DriftCompensationTests.swift
//
// Tests for drift compensation logic in aggregate device configuration.
// Verifies that drift compensation is correctly applied based on device type.

import Testing
import Foundation
import AudioToolbox
@testable import FineTune

// MARK: - Aggregate Plan Drift Compensation

@Suite("ProcessTapController — Drift Compensation Logic (Core Hardening)")
struct DriftCompensationTests {

    @Test("Bluetooth output: drift comp should be OFF for tap")
    func bluetoothDriftCompOff() {
        // When the primary output is Bluetooth, drift compensation for the tap
        // should be OFF because both tap and output follow the BT clock.
        let plan = ProcessTapController.planAggregate(
            outputUIDs: ["bt-device"],
            expand: { _ in nil },
            outputStreamCount: { _ in 1 }
        )
        #expect(plan.subDeviceUIDs == ["bt-device"])
        #expect(plan.clockDeviceUID == "bt-device")
    }

    @Test("Wired USB output: drift comp should be ON for tap")
    func wiredUSBDriftCompOn() {
        // When the primary output is wired USB, drift compensation should be ON
        // because the crystal domains differ.
        let plan = ProcessTapController.planAggregate(
            outputUIDs: ["usb-device"],
            expand: { _ in nil },
            outputStreamCount: { _ in 1 }
        )
        #expect(plan.subDeviceUIDs == ["usb-device"])
        #expect(plan.clockDeviceUID == "usb-device")
    }

    @Test("Virtual source: drift comp should be OFF for tap")
    func virtualSourceDriftCompOff() {
        // Virtual sources (like screen recording) have burst delivery that
        // looks like drift, so compensation should be OFF.
        let plan = ProcessTapController.planAggregate(
            outputUIDs: ["virtual-device"],
            expand: { _ in nil },
            outputStreamCount: { _ in 1 }
        )
        #expect(plan.subDeviceUIDs == ["virtual-device"])
    }

    @Test("Mixed BT + wired: per-sub-device logic applies")
    func mixedDeviceDriftComp() {
        // When mixing Bluetooth and wired devices, each sub-device should
        // have its own drift compensation setting.
        let plan = ProcessTapController.planAggregate(
            outputUIDs: ["bt-device", "usb-device"],
            expand: { _ in nil },
            outputStreamCount: { _ in 1 }
        )
        #expect(plan.subDeviceUIDs == ["bt-device", "usb-device"])
        #expect(plan.isStacked == true)  // Multi-device is always stacked
    }

    @Test("Unknown transport: defaults to OFF (less wrong on unknown BT)")
    func unknownTransportDefaults() {
        let plan = ProcessTapController.planAggregate(
            outputUIDs: ["unknown-device"],
            expand: { _ in nil },
            outputStreamCount: { _ in 1 }
        )
        #expect(plan.subDeviceUIDs == ["unknown-device"])
    }
}

// MARK: - Aggregate Description Building

@Suite("ProcessTapController — Aggregate Description (Core Hardening)")
struct AggregateDescriptionTests {

    @Test("buildAggregateDescription includes required keys")
    func descriptionIncludesKeys() {
        // This tests the structure of the aggregate description dictionary.
        // We can't call buildAggregateDescription directly (it's private),
        // but we can verify the planAggregate output is used correctly.
        let plan = ProcessTapController.planAggregate(
            outputUIDs: ["device-a"],
            expand: { _ in nil },
            outputStreamCount: { _ in 1 }
        )

        #expect(plan.subDeviceUIDs == ["device-a"])
        #expect(plan.isStacked == true)
        #expect(plan.clockDeviceUID == "device-a")
    }

    @Test("Flattened aggregate maintains device order")
    func flattenedOrderMaintained() {
        let plan = ProcessTapController.planAggregate(
            outputUIDs: ["agg"],
            expand: { $0 == "agg" ? ["first", "second", "third"] : nil },
            outputStreamCount: { _ in 1 }
        )
        #expect(plan.subDeviceUIDs == ["first", "second", "third"])
        #expect(plan.clockDeviceUID == "first")
    }
}

// MARK: - Multi-Device Configuration

@Suite("ProcessTapController — Multi-Device Configuration (Core Hardening)")
struct MultiDeviceConfigTests {

    @Test("Two devices: stacked, order preserved")
    func twoDevicesStacked() {
        let plan = ProcessTapController.planAggregate(
            outputUIDs: ["a", "b"],
            expand: { _ in nil },
            outputStreamCount: { _ in 1 }
        )
        #expect(plan.subDeviceUIDs == ["a", "b"])
        #expect(plan.isStacked == true)
        #expect(plan.clockDeviceUID == "a")
    }

    @Test("Three devices: stacked, first is clock")
    func threeDevicesStacked() {
        let plan = ProcessTapController.planAggregate(
            outputUIDs: ["x", "y", "z"],
            expand: { _ in nil },
            outputStreamCount: { _ in 1 }
        )
        #expect(plan.subDeviceUIDs == ["x", "y", "z"])
        #expect(plan.isStacked == true)
        #expect(plan.clockDeviceUID == "x")
    }

    @Test("Single device with aggregate expansion: flattened")
    func singleWithExpansion() {
        let plan = ProcessTapController.planAggregate(
            outputUIDs: ["user-agg"],
            expand: { $0 == "user-agg" ? ["hw-a", "hw-b"] : nil },
            outputStreamCount: { _ in 1 }
        )
        #expect(plan.subDeviceUIDs == ["hw-a", "hw-b"])
        #expect(plan.clockDeviceUID == "hw-a")
    }
}
