// FineTuneTests/TapSourceSelectionTests.swift
//
// Which device stream an app's tap captures: the default's own stream, or the mixdown.

import Testing
@testable import FineTune

@Suite("AudioEngine — tap source selection")
struct TapSourceSelectionTests {

    private func source(
        outputs: [String] = ["dac"],
        followsDefault: Bool = true,
        defaultUID: String? = "dac",
        bluetooth: Set<String> = []
    ) -> String? {
        AudioEngine.streamTapSourceUID(
            forOutputUIDs: outputs,
            isFollowsDefault: followsDefault,
            defaultUID: defaultUID,
            isBluetooth: { bluetooth.contains($0) }
        )
    }

    @Test("A follows-default app on a wired default captures that device's stream")
    func wiredDefaultUsesItsStream() {
        #expect(source() == "dac")
    }

    @Test("An explicitly routed app captures the mixdown")
    func explicitRoutingUsesMixdown() {
        #expect(source(followsDefault: false) == nil)
    }

    @Test("An app routed off the default captures the mixdown")
    func otherDeviceUsesMixdown() {
        #expect(source(outputs: ["speakers"]) == nil)
        #expect(source(defaultUID: nil) == nil)
    }

    @Test("A Bluetooth default captures the mixdown (AirPods Max on a cable play through a hidden USB device)")
    func bluetoothDefaultUsesMixdown() {
        #expect(source(outputs: ["airpods"], defaultUID: "airpods", bluetooth: ["airpods"]) == nil)
    }

    @Test("A Bluetooth device elsewhere in the list does not change a wired default")
    func bluetoothElsewhereKeepsWiredStream() {
        #expect(source(outputs: ["dac"], defaultUID: "dac", bluetooth: ["airpods"]) == "dac")
    }
}
