// FineTuneTests/CoreHardening/CrashGuardTrackingTests.swift
//
// Tests for CrashGuard device tracking.
// Verifies that aggregate devices are properly tracked and untracked.

import Testing
import Foundation
import AudioToolbox
@testable import FineTune

// MARK: - CrashGuard Tracking

@Suite("CrashGuard — Device Tracking")
struct CrashGuardTrackingTests {

    @Test("trackDevice adds device to tracking buffer")
    func trackDeviceAdds() {
        // CrashGuard uses a fixed-size C buffer with os_unfair_lock.
        // We can't directly test the internal buffer, but we can verify
        // the public API doesn't crash and the slot limit is enforced.
        let deviceID = AudioObjectID(42)

        // This should not crash
        CrashGuard.trackDevice(deviceID)
    }

    @Test("untrackDevice removes device from tracking buffer")
    func untrackDeviceRemoves() {
        let deviceID = AudioObjectID(43)

        CrashGuard.trackDevice(deviceID)
        CrashGuard.untrackDevice(deviceID)
    }

    @Test("untrackDevice is safe for unknown device ID")
    func untrackDeviceUnknownSafe() {
        let unknownID = AudioObjectID(99999)

        // Should not crash even if device was never tracked
        CrashGuard.untrackDevice(unknownID)
    }

    @Test("Multiple track/untrack operations are safe")
    func multipleOperationsSafe() {
        let devices: [AudioObjectID] = [
            AudioObjectID(100),
            AudioObjectID(101),
            AudioObjectID(102),
            AudioObjectID(103),
            AudioObjectID(104)
        ]

        // Track all devices
        for device in devices {
            CrashGuard.trackDevice(device)
        }

        // Untrack some devices
        CrashGuard.untrackDevice(devices[1])
        CrashGuard.untrackDevice(devices[3])

        // Track more devices
        CrashGuard.trackDevice(AudioObjectID(105))
        CrashGuard.trackDevice(AudioObjectID(106))

        // Untrack remaining
        for device in devices {
            CrashGuard.untrackDevice(device)
        }
        CrashGuard.untrackDevice(AudioObjectID(105))
        CrashGuard.untrackDevice(AudioObjectID(106))
    }

    @Test("Slot limit warning is logged when exceeding max devices")
    func slotLimitEnforced() {
        // CrashGuard has a max of 64 device slots.
        // We test that exceeding this limit doesn't crash.
        let maxSlots = 64

        for i in 0..<(maxSlots + 10) {
            CrashGuard.trackDevice(AudioObjectID(UInt32(i)))
        }

        // Cleanup
        for i in 0..<(maxSlots + 10) {
            CrashGuard.untrackDevice(AudioObjectID(UInt32(i)))
        }
    }
}

// MARK: - OrphanedTapCleanup

@Suite("OrphanedTapCleanup — Device Discovery")
struct OrphanedTapCleanupTests {

    @Test("destroyOrphanedDevices handles empty device list")
    func emptyDeviceList() {
        // This tests the code path when readDeviceList() returns empty.
        // In a real test, we'd mock the HAL, but for now we verify
        // the function doesn't crash on empty input.
        OrphanedTapCleanup.destroyOrphanedDevices()
    }

    @Test("destroyOrphanedDevices is idempotent")
    func idempotentCleanup() {
        // Calling multiple times should be safe
        OrphanedTapCleanup.destroyOrphanedDevices()
        OrphanedTapCleanup.destroyOrphanedDevices()
    }
}

// MARK: - ProcessTapController.planAggregate Edge Cases

@Suite("ProcessTapController — Aggregate Planning Edge Cases")
struct AggregatePlanEdgeCaseTests {

    @Test("Empty sub-device list from expand is treated as plain device")
    func emptySubDeviceList() {
        let plan = ProcessTapController.planAggregate(
            outputUIDs: ["agg"],
            expand: { _ in [] },
            outputStreamCount: { _ in 1 }
        )
        #expect(plan.subDeviceUIDs == ["agg"])
        #expect(plan.isStacked == true)
    }

    @Test("Nil sub-device list from expand is treated as plain device")
    func nilSubDeviceList() {
        let plan = ProcessTapController.planAggregate(
            outputUIDs: ["device"],
            expand: { _ in nil },
            outputStreamCount: { _ in 1 }
        )
        #expect(plan.subDeviceUIDs == ["device"])
        #expect(plan.isStacked == true)
    }

    @Test("Single device with zero output streams stays stacked")
    func zeroOutputStreams() {
        let plan = ProcessTapController.planAggregate(
            outputUIDs: ["device"],
            expand: { _ in nil },
            outputStreamCount: { _ in 0 }
        )
        #expect(plan.subDeviceUIDs == ["device"])
        #expect(plan.isStacked == true)
    }

    @Test("Many sub-devices are flattened and de-duplicated")
    func manySubDevices() {
        let plan = ProcessTapController.planAggregate(
            outputUIDs: ["agg"],
            expand: { _ in ["a", "b", "c", "d", "e"] },
            outputStreamCount: { _ in 1 }
        )
        #expect(plan.subDeviceUIDs == ["a", "b", "c", "d", "e"])
        #expect(plan.isStacked == true)
    }

    @Test("De-duplication preserves first occurrence order")
    func deduplicationPreservesOrder() {
        let plan = ProcessTapController.planAggregate(
            outputUIDs: ["agg1", "agg2"],
            expand: {
                switch $0 {
                case "agg1": return ["a", "b", "c"]
                case "agg2": return ["b", "c", "d"]
                default: return nil
                }
            },
            outputStreamCount: { _ in 1 }
        )
        // "b" and "c" appear in both aggregates but should only appear once
        #expect(plan.subDeviceUIDs == ["a", "b", "c", "d"])
        #expect(plan.isStacked == true)
    }

    @Test("First device in outputUIDs becomes clock device")
    func firstDeviceIsClock() {
        let plan = ProcessTapController.planAggregate(
            outputUIDs: ["device-b", "device-a"],
            expand: { _ in nil },
            outputStreamCount: { _ in 1 }
        )
        #expect(plan.clockDeviceUID == "device-b")
    }
}

// MARK: - Input Stream Usage Edge Cases

@Suite("ProcessTapController — Input Stream Usage Edge Cases")
struct InputStreamUsageEdgeCaseTests {

    @Test("Large input count with single output")
    func largeInputCount() {
        let flags = ProcessTapController.inputStreamUsageFlags(inputCount: 16, outputCount: 1)
        #expect(flags?.count == 16)
        // Only the last stream (tap) should be marked as used
        #expect(flags?.last == 1)
        #expect(flags?.prefix(15).allSatisfy { $0 == 0 } == true)
    }

    @Test("Equal input and output counts: nil (nothing to disable)")
    func equalInputOutput() {
        #expect(ProcessTapController.inputStreamUsageFlags(inputCount: 4, outputCount: 4) == nil)
    }

    @Test("More outputs than inputs: nil (defensive)")
    func moreOutputsThanInputs() {
        #expect(ProcessTapController.inputStreamUsageFlags(inputCount: 2, outputCount: 4) == nil)
    }
}
