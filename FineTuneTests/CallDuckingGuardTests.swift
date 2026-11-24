// FineTuneTests/CallDuckingGuardTests.swift

import Testing
import AudioToolbox
import Foundation
@testable import FineTune

@MainActor
private final class DuckLog {
    var calls: [(device: AudioObjectID, level: Float32)] = []
    var status: OSStatus = noErr

    var function: CallDuckingGuard.DuckFunction {
        { device, level in
            self.calls.append((device, level))
            return self.status
        }
    }

    func levels(for device: AudioObjectID) -> [Float32] {
        calls.filter { $0.device == device }.map(\.level)
    }
}

@Suite("CallDuckingGuard")
@MainActor
struct CallDuckingGuardTests {

    @Test("Holds one request per output device, once")
    func holdsEachDeviceOnce() {
        let log = DuckLog()
        let guardian = CallDuckingGuard(isEnabled: true, duck: log.function)
        guardian.update(outputDeviceIDs: [10, 11])
        guardian.update(outputDeviceIDs: [10, 11])
        #expect(log.levels(for: 10) == [CallDuckingGuard.holdLevel])
        #expect(log.levels(for: 11) == [CallDuckingGuard.holdLevel])
        #expect(guardian.heldDeviceIDs == [10, 11])
    }

    @Test("Withdraws the request of a device that left, with exactly 1.0")
    func releasesGoneDevice() {
        let log = DuckLog()
        let guardian = CallDuckingGuard(isEnabled: true, duck: log.function)
        guardian.update(outputDeviceIDs: [10, 11])
        guardian.update(outputDeviceIDs: [11])
        #expect(log.levels(for: 10) == [CallDuckingGuard.holdLevel, 1.0])
        #expect(guardian.heldDeviceIDs == [11])
    }

    @Test("Turned off, it withdraws every request and holds no new one")
    func disableReleasesAll() {
        let log = DuckLog()
        let guardian = CallDuckingGuard(isEnabled: true, duck: log.function)
        guardian.update(outputDeviceIDs: [10])
        guardian.setEnabled(false)
        guardian.update(outputDeviceIDs: [10, 12])
        #expect(log.levels(for: 10) == [CallDuckingGuard.holdLevel, 1.0])
        #expect(log.levels(for: 12).isEmpty)
        #expect(guardian.heldDeviceIDs.isEmpty)
    }

    @Test("A refused request is retried on the next update")
    func retriesAfterFailure() {
        let log = DuckLog()
        log.status = -1
        let guardian = CallDuckingGuard(isEnabled: true, duck: log.function)
        guardian.update(outputDeviceIDs: [10])
        #expect(guardian.heldDeviceIDs.isEmpty)
        log.status = noErr
        guardian.update(outputDeviceIDs: [10])
        #expect(guardian.heldDeviceIDs == [10])
    }

    @Test("Without AudioDeviceDuck it does nothing")
    func noFunctionIsNoOp() {
        let guardian = CallDuckingGuard(isEnabled: true, duck: nil)
        guardian.update(outputDeviceIDs: [10])
        #expect(guardian.heldDeviceIDs.isEmpty)
    }

    @Test("The setting defaults to on, also in settings saved before it existed")
    func settingDefaultsOn() throws {
        #expect(AppSettings().keepVolumeDuringCalls)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(decoded.keepVolumeDuringCalls)
    }
}
