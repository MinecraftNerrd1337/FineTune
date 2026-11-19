// FineTuneTests/VolumePluginTests.swift
// Volume plugins: the plugin file, loading, device matching, and the script host driven
// through a recording stand-in for the DAC's HID interface.

import Testing
import Foundation
import IOKit.hid
@testable import FineTune

// MARK: - Stand-ins

/// Records the reports a session sends, in place of a HID interface
private nonisolated final class RecordingTransport: VolumePluginTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [(reportID: UInt8, bytes: [UInt8])] = []
    let featureReply: [UInt8]

    init(featureReply: [UInt8] = []) {
        self.featureReply = featureReply
    }

    var reports: [[UInt8]] {
        lock.lock()
        defer { lock.unlock() }
        return sent.map(\.bytes)
    }

    func setReport(_ type: IOHIDReportType, reportID: UInt8, bytes: [UInt8]) -> IOReturn {
        lock.lock()
        sent.append((reportID, bytes))
        lock.unlock()
        return kIOReturnSuccess
    }

    func getReport(_ type: IOHIDReportType, reportID: UInt8, length: Int) -> (result: IOReturn, bytes: [UInt8]) {
        (kIOReturnSuccess, Array(featureReply.prefix(length)))
    }
}

private nonisolated final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [VolumePluginEvent] = []

    func append(_ event: VolumePluginEvent) {
        lock.lock()
        stored.append(event)
        lock.unlock()
    }

    var failures: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored.compactMap { if case .failed(let message) = $0 { message } else { nil } }
    }

    var stops: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored.compactMap { if case .stopped(let message) = $0 { message } else { nil } }
    }

    var reportedVolumes: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return stored.compactMap { if case .volumeReported(let volume, _) = $0 { volume } else { nil } }
    }

    var reportedMutes: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return stored.compactMap { if case .muteReported(let muted, _) = $0 { muted } else { nil } }
    }

    /// Whether the HUD shows each report, volume and mute alike, in order
    var reportsShowingHUD: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return stored.compactMap {
            switch $0 {
            case .volumeReported(_, let showsHUD), .muteReported(_, let showsHUD): showsHUD
            default: nil
            }
        }
    }
}

private typealias Match = VolumePluginManifest.Match

private func makeManifest(length: Int? = 16) -> VolumePluginManifest {
    VolumePluginManifest(
        id: "com.example.test",
        name: "Test DAC",
        author: nil,
        version: nil,
        description: nil,
        match: [Match(vendorID: 0x1234, productIDs: [0x5678])],
        hid: VolumePluginManifest.HID(outputReportLength: length),
        minimumIntervalMS: 0
    )
}

private func makeSession(
    _ script: String, length: Int? = 16, callTimeLimit: Double = VolumePluginSession.defaultCallTimeLimit,
    transport: RecordingTransport, events: EventLog
) -> VolumePluginSession {
    VolumePluginSession(
        manifest: makeManifest(length: length),
        script: script,
        scriptURL: URL(fileURLWithPath: "/tmp/Test.finetuneplugin"),
        transport: transport,
        info: VolumePluginSession.DeviceInfo(
            name: "Test DAC", uid: "uid-test", vendorID: 0x1234, productID: 0x5678, productName: "Test DAC"),
        callTimeLimit: callTimeLimit,
        onEvent: { events.append($0) }
    )
}

/// `reports` reach the plugin after it started, as a device's answer comes after the question
private func start(
    _ session: VolumePluginSession, volume: Double, muted: Bool = false, thenReports reports: [[UInt8]] = []
) async -> VolumePluginSession.Attached? {
    await withCheckedContinuation { continuation in
        session.start(volume: volume, muted: muted) { attached in
            continuation.resume(returning: attached)
        }
        for bytes in reports {
            session.handleInputReport(reportID: 0, bytes: bytes)
        }
    }
}

private func idle(_ session: VolumePluginSession) async {
    await withCheckedContinuation { continuation in
        session.whenIdle { continuation.resume() }
    }
}

/// Sends the volume as a percentage in the third byte, and the mute as `[9, 0|1]`
private let percentScript = """
function setVolume(device, volume) {
  device.hid.sendOutputReport(0, [1, 0x11, Math.round(volume * 100)]);
}
"""

private let percentAndMuteScript = percentScript + """
function setMute(device, muted) {
  device.hid.sendOutputReport(0, [9, muted ? 1 : 0]);
}
"""

private func padded(_ bytes: [UInt8], to length: Int = 16) -> [UInt8] {
    bytes + [UInt8](repeating: 0, count: length - bytes.count)
}

/// A plugin file: a license comment, the manifest comment, then the script
private func pluginFile(manifest: String, script: String = percentScript) -> String {
    """
    // Test plugin. SPDX-License-Identifier: MIT

    /* @manifest
    \(manifest)
    */

    \(script)
    """
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

// MARK: - Manifest and loading

@Suite("Volume plugins — manifest and loading")
struct VolumePluginManifestTests {
    @Test("IDs can be numbers or hexadecimal strings")
    func decodesHexIDs() throws {
        let json = """
        {"id": "x", "name": "X", "match": {"vendorID": "0x262A", "productIDs": [16, "0x11"], "usagePage": "0xFF00"},
         "hid": {"outputReportLength": 16}}
        """
        let manifest = try JSONDecoder().decode(VolumePluginManifest.self, from: Data(json.utf8))
        #expect(manifest.match == [Match(vendorID: 0x262A, productIDs: [16, 17], usagePage: 0xFF00)])
        #expect(manifest.hid.outputReportLength == 16)
        #expect(VolumePluginLoader.validate(manifest) == nil)
    }

    @Test("match can be a list of rules, and hid can be left out")
    func decodesRuleList() throws {
        let json = """
        {"id": "x", "name": "X", "match": [
          {"vendorID": 1},
          {"vendorID": "0x2FC6", "productNames": ["DAC One"], "excludedProductIDs": ["0x0002"]}
        ]}
        """
        let manifest = try JSONDecoder().decode(VolumePluginManifest.self, from: Data(json.utf8))
        #expect(manifest.match == [
            Match(vendorID: 1),
            Match(vendorID: 0x2FC6, excludedProductIDs: [2], productNames: ["DAC One"]),
        ])
        #expect(manifest.hid == VolumePluginManifest.HID())
        #expect(VolumePluginLoader.validate(manifest) == nil)
    }

    @Test("A rule with a key it doesn't take is refused, rather than matching more than meant")
    func refusesUnknownRuleKeys() {
        let json = """
        {"id": "x", "name": "X", "match": {"vendorID": "0x262A", "productName": "iBasso-DC06-Pro"}}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(VolumePluginManifest.self, from: Data(json.utf8))
        }
    }

    @Test("A malformed ID is refused")
    func refusesBadID() {
        let json = """
        {"id": "x", "name": "X", "match": {"vendorID": "zz"}, "hid": {"outputReportLength": 16}}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(VolumePluginManifest.self, from: Data(json.utf8))
        }
    }

    @Test("A manifest keeps its IDs, names and reports in range")
    func validation() {
        var manifest = makeManifest()
        #expect(VolumePluginLoader.validate(manifest) == nil)

        // A whole vendor is allowed, an empty list of products is not
        manifest.match[0].productIDs = nil
        #expect(VolumePluginLoader.validate(manifest) == nil)
        manifest.match[0].productIDs = []
        #expect(VolumePluginLoader.validate(manifest) != nil)
        manifest.match[0].productIDs = nil

        manifest.match[0].excludedProductIDs = [0x10000]
        #expect(VolumePluginLoader.validate(manifest) != nil)
        manifest.match[0].excludedProductIDs = nil
        manifest.match[0].productNames = [" - "]
        #expect(VolumePluginLoader.validate(manifest) != nil)
        manifest.match[0].productNames = ["iBasso-DC06-Pro"]
        #expect(VolumePluginLoader.validate(manifest) == nil)

        manifest.hid.outputReportLength = 0
        #expect(VolumePluginLoader.validate(manifest) != nil)
        manifest.hid.outputReportLength = nil
        #expect(VolumePluginLoader.validate(manifest) == nil)
        manifest.match[0].vendorID = 0x10000
        #expect(VolumePluginLoader.validate(manifest) != nil)
        manifest.match = []
        #expect(VolumePluginLoader.validate(manifest) != nil)
    }

    @Test("The manifest is the comment that opens with @manifest, wherever it is")
    func findsManifestComment() {
        let source = pluginFile(manifest: #"{"id": "x"}"#)
        #expect(VolumePluginLoader.manifestJSON(in: source)?.trimmingCharacters(in: .whitespacesAndNewlines) == #"{"id": "x"}"#)
        #expect(VolumePluginLoader.manifestJSON(in: "/*@manifest {} */")?.trimmingCharacters(in: .whitespaces) == "{}")
        #expect(VolumePluginLoader.manifestJSON(in: "/* manifest {} */") == nil)
        #expect(VolumePluginLoader.manifestJSON(in: "/* @manifestation {} */") == nil)
        #expect(VolumePluginLoader.manifestJSON(in: "/* @manifest {} ") == nil)
    }

    @Test("Plugin files load, and broken ones say why instead of stopping the others")
    func loadsFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        func write(_ name: String, _ text: String) throws {
            try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let good = """
        {"id": "good", "name": "Good", "match": {"vendorID": 1, "productIDs": [2]}, "hid": {"outputReportLength": 8}}
        """
        try write("A Good.finetuneplugin", pluginFile(manifest: good))
        try write("B Copy.finetuneplugin", pluginFile(manifest: good))
        try write("C NoVendor.finetuneplugin", pluginFile(manifest: """
        {"id": "nv", "name": "NV", "match": [{"productIDs": [2]}], "hid": {"outputReportLength": 8}}
        """))
        try write("D NoManifest.finetuneplugin", percentScript)
        try write("E BadJSON.finetuneplugin", pluginFile(manifest: #"{"id": "bad", "name": }"#))
        try Data([0xFF, 0xFE, 0x00, 0xC3]).write(to: directory.appendingPathComponent("F Binary.finetuneplugin"))
        try Data(repeating: 0x20, count: VolumePluginLoader.maximumFileSize + 1)
            .write(to: directory.appendingPathComponent("G Huge.finetuneplugin"))
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("H Folder.finetuneplugin"), withIntermediateDirectories: true)
        try write("Not a plugin.js", pluginFile(manifest: good))

        let files = VolumePluginLoader.loadAll(from: directory)
        try #require(files.count == 8)
        #expect(files[0].id == "good")
        #expect(files[0].isUsable)
        #expect(files[0].script?.contains("function setVolume") == true)
        #expect(files[1].loadError?.contains("already uses") == true)
        #expect(files[2].loadError?.contains("vendorID") == true)
        #expect(files[3].loadError?.contains("@manifest") == true)
        #expect(files[4].loadError?.contains("not valid JSON") == true)
        #expect(files[5].loadError?.contains("UTF-8") == true)
        #expect(files[6].loadError?.contains("larger") == true)
        #expect(files[7].loadError?.contains("folder") == true)
        #expect(files.dropFirst().allSatisfy { !$0.isUsable })
        // Every entry keeps an id of its own, for the plugins list
        #expect(Set(files.map(\.id)).count == files.count)
        #expect(files[3].name == "D NoManifest")
    }

    @Test("A missing plugins folder has no plugins")
    func missingFolder() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(VolumePluginLoader.loadAll(from: directory).isEmpty)
    }
}

// MARK: - Matching

@Suite("Volume plugins — device matching")
struct VolumePluginMatchingTests {
    private let match = Match(vendorID: 0x262A, productNames: ["iBasso-DC06-Pro"], usagePage: 0xFF00)

    @Test("Names compare without case, spaces or punctuation")
    func normalizesNames() {
        #expect(VolumePluginMatching.normalized("iBasso-DC06-Pro") == "ibassodc06pro")
        #expect(VolumePluginMatching.normalized("  iBasso DC06 Pro ") == "ibassodc06pro")
    }

    @Test("A HID interface matches on vendor, name and usage page")
    func matchesHID() {
        #expect(VolumePluginMatching.hidMatches(
            match, vendorID: 0x262A, productID: 7, productName: "iBasso DC06 Pro", usagePairs: [(0xFF00, 1)]))
        #expect(!VolumePluginMatching.hidMatches(
            match, vendorID: 0x262B, productID: 7, productName: "iBasso DC06 Pro", usagePairs: [(0xFF00, 1)]))
        #expect(!VolumePluginMatching.hidMatches(
            match, vendorID: 0x262A, productID: 7, productName: "iBasso DC03 Pro", usagePairs: [(0xFF00, 1)]))
        // A name is the whole name, not part of it
        #expect(!VolumePluginMatching.hidMatches(
            Match(vendorID: 0x262A, productNames: ["iBasso-DC06"]),
            vendorID: 0x262A, productID: 7, productName: "iBasso-DC06-Pro", usagePairs: []))
        // The consumer-control interface of the same DAC is left alone
        #expect(!VolumePluginMatching.hidMatches(
            match, vendorID: 0x262A, productID: 7, productName: "iBasso DC06 Pro", usagePairs: [(0x0C, 1)]))
    }

    @Test("A rule takes a whole vendor, only some products, or all but some")
    func productRules() {
        func matches(_ rule: Match, vendor: Int = 0x262A, product: Int) -> Bool {
            VolumePluginMatching.hidMatches(rule, vendorID: vendor, productID: product, productName: nil, usagePairs: [])
        }
        let vendor = Match(vendorID: 0x262A)
        #expect(matches(vendor, product: 1))
        #expect(!matches(vendor, vendor: 0x2FC6, product: 1))

        let listed = Match(vendorID: 0x262A, productIDs: [1, 2])
        #expect(matches(listed, product: 2))
        #expect(!matches(listed, product: 3))

        let allBut = Match(vendorID: 0x262A, excludedProductIDs: [2])
        #expect(matches(allBut, product: 1))
        #expect(!matches(allBut, product: 2))

        // A plugin's rules: any one of them is enough
        #expect(VolumePluginMatching.hidMatches(
            anyOf: [listed, Match(vendorID: 0x2FC6)], vendorID: 0x2FC6, productID: 9, productName: nil, usagePairs: []))
        #expect(VolumePluginMatching.hidMatches(
            anyOf: [allBut, listed], vendorID: 0x262A, productID: 2, productName: nil, usagePairs: []))
        #expect(!VolumePluginMatching.hidMatches(
            anyOf: [allBut], vendorID: 0x262A, productID: 2, productName: nil, usagePairs: []))
    }

    @Test("The HID manager looks for each listed product, or for the whole vendor")
    func matchingDictionaries() {
        let vendor = VolumePluginController.matchingDictionaries(for: Match(vendorID: 0x262A, usagePage: 0xFF00))
        #expect(vendor.count == 1)
        #expect(vendor.first?[kIOHIDVendorIDKey] as? Int == 0x262A)
        #expect(vendor.first?[kIOHIDProductIDKey] == nil)
        #expect(vendor.first?[kIOHIDDeviceUsagePageKey] as? Int == 0xFF00)

        let listed = VolumePluginController.matchingDictionaries(for: Match(vendorID: 0x262A, productIDs: [1, 2]))
        #expect(listed.compactMap { $0[kIOHIDProductIDKey] as? Int } == [1, 2])
    }

    @Test("An audio device belongs to a HID interface by USB IDs, else by name")
    func matchesAudio() {
        let usb = USBIdentity(vendorID: 0x262A, productID: 7, locationID: 0x0110_0000)
        #expect(VolumePluginMatching.audioMatches(
            hidVendorID: 0x262A, hidProductID: 7, hidProductName: "iBasso-DC06-Pro",
            usb: usb, name: "USB Audio", uid: "x"))
        #expect(!VolumePluginMatching.audioMatches(
            hidVendorID: 0x262A, hidProductID: 8, hidProductName: "iBasso-DC06-Pro",
            usb: usb, name: "iBasso-DC06-Pro", uid: "x"))
        // Without USB IDs, the name or UID must carry the interface's product name
        #expect(VolumePluginMatching.audioMatches(
            hidVendorID: 0x262A, hidProductID: 7, hidProductName: "iBasso-DC06-Pro",
            usb: nil, name: "USB Audio", uid: "AppleUSBAudioEngine:iBasso:iBasso-DC06-Pro:5000000001:2"))
        #expect(!VolumePluginMatching.audioMatches(
            hidVendorID: 0x262A, hidProductID: 7, hidProductName: "iBasso-DC06-Pro",
            usb: nil, name: "MacBook Pro Speakers", uid: "BuiltInSpeakerDevice"))
        #expect(!VolumePluginMatching.audioMatches(
            hidVendorID: 0x262A, hidProductID: 7, hidProductName: nil,
            usb: nil, name: "iBasso-DC06-Pro", uid: "x"))
        // A device that isn't on USB (HDMI, Bluetooth) has no USB IDs, and its name isn't the interface's
        #expect(!VolumePluginMatching.audioMatches(
            hidVendorID: 0x262A, hidProductID: 7, hidProductName: "iBasso-DC06-Pro",
            usb: nil, name: "LG HDR 4K", uid: "AppleGFXHDAEngineOutputDP:10001:0:{AC10-2577-01010101}"))
    }

    @Test("A new device gets the first plugin written for it that takes new DACs, and only that one")
    func choiceForNewDevice() {
        #expect(VolumePluginController.choiceForNewDevice(
            compatiblePluginIDs: ["a", "b"], automaticPluginIDs: ["a", "b"]) == .plugin("a"))
        #expect(VolumePluginController.choiceForNewDevice(
            compatiblePluginIDs: ["a", "b"], automaticPluginIDs: ["b"]) == .plugin("b"))
        #expect(VolumePluginController.choiceForNewDevice(
            compatiblePluginIDs: ["a"], automaticPluginIDs: ["b"]) == nil)
        #expect(VolumePluginController.choiceForNewDevice(
            compatiblePluginIDs: [], automaticPluginIDs: ["a"]) == nil)
    }
}

// MARK: - Script host

@Suite("Volume plugins — script host")
struct VolumePluginSessionTests {
    @Test("Reports are padded to the declared length")
    func padsReports() async {
        let transport = RecordingTransport()
        let session = makeSession(percentScript, transport: transport, events: EventLog())
        let attached = await start(session, volume: 0.5)
        #expect(attached?.volume == 0.5)
        #expect(transport.reports == [padded([1, 0x11, 50])])
        session.close()
    }

    @Test("Without a declared length, reports go as the plugin gives them")
    func unpaddedReports() async {
        let transport = RecordingTransport()
        let session = makeSession(percentScript, length: nil, transport: transport, events: EventLog())
        _ = await start(session, volume: 0.5)
        #expect(transport.reports == [[1, 0x11, 50]])
        session.close()
    }

    @Test("A report longer than declared is refused, and the plugin fails")
    func refusesLongReports() async {
        let transport = RecordingTransport()
        let events = EventLog()
        let session = makeSession(percentScript, length: 2, transport: transport, events: events)
        let attached = await start(session, volume: 0.5)
        #expect(attached == nil)
        #expect(transport.reports.isEmpty)
        #expect(events.failures.count == 1)
    }

    @Test("A huge or malformed report is refused without being copied")
    func refusesHugeReports() async {
        for body in ["new Array(100000).fill(1)", "{length: 3}", "\"abc\""] {
            let transport = RecordingTransport()
            let events = EventLog()
            let script = "function setVolume(device, volume) { device.hid.sendOutputReport(0, \(body)); }"
            let session = makeSession(script, length: nil, transport: transport, events: events)
            #expect(await start(session, volume: 0.5) == nil)
            #expect(transport.reports.isEmpty)
            #expect(events.failures.count == 1)
        }
    }

    @Test("A report ID other than 0 goes before the data")
    func prefixesReportID() async {
        let transport = RecordingTransport()
        let script = "function setVolume(device, volume) { device.hid.sendOutputReport(5, [1]); }"
        let session = makeSession(script, length: 4, transport: transport, events: EventLog())
        _ = await start(session, volume: 1)
        #expect(transport.reports == [[5, 1, 0, 0, 0]])
        #expect(VolumePluginSession.framedReport([1, 2, 3], reportID: 0, length: 2) == nil)
        #expect(VolumePluginSession.bytes(fromNumbers: [1, 256]) == nil)
        #expect(VolumePluginSession.bytes(fromNumbers: [1.5]) == nil)
        #expect(VolumePluginSession.bytes(fromNumbers: [0, 255]) == [0, 255])
    }

    @Test("Fast changes are merged and the last one wins")
    func mergesChanges() async {
        let transport = RecordingTransport()
        let session = makeSession(percentScript, transport: transport, events: EventLog())
        _ = await start(session, volume: 0.5)
        for step in 1...20 {
            session.request(volume: Double(step) / 100)
        }
        await idle(session)
        let reports = transport.reports
        #expect(reports.last == padded([1, 0x11, 20]))
        #expect(reports.count <= 21)
        session.close()
    }

    @Test("Without setMute, muting sends 0 and unmuting the level")
    func muteFallback() async {
        let transport = RecordingTransport()
        let session = makeSession(percentScript, transport: transport, events: EventLog())
        _ = await start(session, volume: 0.5)
        session.request(muted: true)
        await idle(session)
        #expect(transport.reports.last == padded([1, 0x11, 0]))
        session.request(muted: false)
        await idle(session)
        #expect(transport.reports.last == padded([1, 0x11, 50]))
        session.close()
    }

    @Test("While muted, a new level waits for the unmute")
    func levelWaitsForUnmute() async {
        let transport = RecordingTransport()
        let session = makeSession(percentAndMuteScript, transport: transport, events: EventLog())
        let attached = await start(session, volume: 0.5, muted: true)
        #expect(attached?.muted == true)
        #expect(transport.reports == [padded([9, 1])])
        session.request(volume: 0.8)
        await idle(session)
        #expect(transport.reports.count == 1)
        session.request(muted: false)
        await idle(session)
        #expect(Array(transport.reports.suffix(2)) == [padded([9, 0]), padded([1, 0x11, 80])])
        session.close()
    }

    @Test("A level the plugin reads in onAttach wins, and nothing is sent")
    func attachReadingWins() async {
        let transport = RecordingTransport(featureReply: [3, 25])
        let script = percentScript + """
        function onAttach(device) {
          const reply = device.hid.getFeatureReport(3, 1);
          device.reportVolume(reply[1] / 100);
        }
        """
        let session = makeSession(script, transport: transport, events: EventLog())
        let attached = await start(session, volume: 0.9)
        #expect(attached?.volume == 0.25)
        #expect(transport.reports.isEmpty)
        session.close()
    }

    @Test("A level the device sends back while FineTune waits for it wins, and nothing more is sent")
    func waitsForTheDevicesLevel() async {
        let transport = RecordingTransport()
        let script = percentScript + """
        function onAttach(device) {
          device.hid.sendOutputReport(0, [0x15, 0x12]);
          device.waitForLevel(1000);
        }
        function onInputReport(device, reportID, bytes) {
          if (bytes[0] === 0x15) device.reportVolume(bytes[1] / 100);
        }
        """
        let session = makeSession(script, transport: transport, events: EventLog())
        let attached = await start(session, volume: 0.9, thenReports: [[0x02, 99], [0x15, 30]])
        #expect(attached?.volume == 0.3)
        #expect(transport.reports == [padded([0x15, 0x12])])
        session.close()
    }

    @Test("A device that doesn't answer in time gets FineTune's level")
    func levelWaitTimesOut() async {
        let transport = RecordingTransport()
        let script = percentScript + """
        function onAttach(device) { device.waitForLevel(50); }
        function onInputReport(device, reportID, bytes) { device.reportVolume(bytes[0] / 100); }
        """
        let session = makeSession(script, transport: transport, events: EventLog())
        let attached = await start(session, volume: 0.4)
        #expect(attached?.volume == 0.4)
        #expect(transport.reports == [padded([1, 0x11, 40])])
        session.close()
    }

    @Test("waitForLevel only works in onAttach")
    func levelWaitOutsideAttach() async {
        let events = EventLog()
        let script = percentScript + """
        function onInputReport(device, reportID, bytes) { device.waitForLevel(100); }
        """
        let session = makeSession(script, transport: RecordingTransport(), events: events)
        _ = await start(session, volume: 0.5)
        session.handleInputReport(reportID: 0, bytes: [1])
        await idle(session)
        #expect(events.failures.count == 1)
        session.close()
    }

    @Test("The DAC's own buttons reach FineTune through onInputReport")
    func inputReports() async {
        let events = EventLog()
        let script = percentScript + """
        function onAttach(device) { device.reportVolume(0.5); }
        function onInputReport(device, reportID, bytes) { device.reportVolume(bytes[0] / 100); }
        """
        let session = makeSession(script, transport: RecordingTransport(), events: events)
        _ = await start(session, volume: 0.5)
        session.handleInputReport(reportID: 0, bytes: [40, 0, 0])
        await idle(session)
        #expect(events.reportedVolumes == [0.4])
        session.close()
    }

    @Test("A plugin can keep a report from showing the HUD")
    func reportsWithoutTheHUD() async {
        let events = EventLog()
        let script = percentScript + """
        function onInputReport(device, reportID, bytes) {
            if (bytes[1] === 1) device.reportVolume(bytes[0] / 100, { hud: false });
            else if (bytes[1] === 2) device.reportMute(true, { hud: false });
            else device.reportVolume(bytes[0] / 100);
        }
        """
        let session = makeSession(script, transport: RecordingTransport(), events: events)
        _ = await start(session, volume: 0.5)
        session.handleInputReport(reportID: 0, bytes: [40, 1, 0])
        session.handleInputReport(reportID: 0, bytes: [0, 2, 0])
        session.handleInputReport(reportID: 0, bytes: [45, 0, 0])
        await idle(session)
        #expect(events.reportedVolumes == [0.4, 0.45])
        #expect(events.reportedMutes == [true])
        #expect(events.reportsShowingHUD == [false, false, true])
        #expect(events.failures.isEmpty)
        session.close()
    }

    @Test("Report options other than { hud: true or false } are the script's error")
    func badReportOptions() async {
        let events = EventLog()
        let script = percentScript + """
        function onInputReport(device, reportID, bytes) {
            if (bytes[0] === 1) device.reportVolume(0.4, { hud: "no" });
            else device.reportMute(true, 3);
        }
        """
        let session = makeSession(script, transport: RecordingTransport(), events: events)
        _ = await start(session, volume: 0.5)
        session.handleInputReport(reportID: 0, bytes: [1])
        await idle(session)
        session.handleInputReport(reportID: 0, bytes: [2])
        await idle(session)
        #expect(events.reportedVolumes.isEmpty)
        #expect(events.reportedMutes.isEmpty)
        #expect(events.failures.count >= 1)
        session.close()
    }

    @Test("A level the DAC reports right after a change in FineTune counts once it can't be an echo")
    func reportsRightAfterAChange() async throws {
        let events = EventLog()
        let script = percentScript + """
        function onInputReport(device, reportID, bytes) { device.reportVolume(bytes[0] / 100); }
        """
        let session = makeSession(script, transport: RecordingTransport(), events: events)
        _ = await start(session, volume: 0.5)
        let echoWindow = Duration.milliseconds(VolumePluginSession.echoWindowMS + 150)

        // The DAC echoes the level FineTune sent, then its volume button raises it
        session.request(volume: 0.6)
        session.handleInputReport(reportID: 0, bytes: [60, 0, 0])
        session.handleInputReport(reportID: 0, bytes: [61, 0, 0])
        await idle(session)
        #expect(events.reportedVolumes.isEmpty)
        try await Task.sleep(for: echoWindow)
        await idle(session)
        #expect(events.reportedVolumes == [0.61])

        // An echo of FineTune's own level changes nothing
        session.request(volume: 0.7)
        session.handleInputReport(reportID: 0, bytes: [70, 0, 0])
        try await Task.sleep(for: echoWindow)
        await idle(session)
        #expect(events.reportedVolumes == [0.61])

        // A level reported before FineTune's next change is out of date
        session.request(volume: 0.8)
        session.handleInputReport(reportID: 0, bytes: [75, 0, 0])
        await idle(session)
        session.request(volume: 0.9)
        try await Task.sleep(for: echoWindow)
        await idle(session)
        #expect(events.reportedVolumes == [0.61])
        session.close()
    }

    @Test("A script without setVolume, that doesn't parse, or that throws, fails")
    func brokenScripts() async {
        let scripts = [
            "function setMute(device, muted) {}",
            "function setVolume(device, volume) {",
            "throw new Error('broken'); function setVolume(device, volume) {}",
            "function setVolume(device, volume) { undefinedFunction(); }",
            "function onAttach(device) { null.x; } function setVolume(device, volume) {}",
            "function setVolume(device, volume) { setVolume(device, volume); }",
        ]
        for script in scripts {
            let events = EventLog()
            let session = makeSession(script, transport: RecordingTransport(), events: events)
            #expect(await start(session, volume: 0.5) == nil)
            #expect(events.failures.count == 1)
        }
    }

    @Test("A script that keeps the device waiting is stopped, and gets no more calls")
    func stopsSlowScripts() async {
        let transport = RecordingTransport()
        let events = EventLog()
        let script = """
        let calls = 0;
        function setVolume(device, volume) {
          calls += 1;
          device.hid.sendOutputReport(0, [calls]);
          if (calls > 1) { for (let i = 0; i < 4; i++) sleep(100); }
        }
        """
        let session = makeSession(script, length: nil, callTimeLimit: 0.3, transport: transport, events: events)
        _ = await start(session, volume: 0.5)
        session.request(volume: 0.6)
        await idle(session)
        session.request(volume: 0.7)
        await idle(session)
        #expect(events.stops.count == 1)
        // The slow call's report went before it stalled, then nothing more
        #expect(transport.reports == [[1], [2]])
        session.close()
    }

    @Test("A script stuck in a loop is stopped", .enabled(if: VolumePluginSession.canLimitExecutionTime))
    func stopsLoopingScripts() async {
        let events = EventLog()
        let script = "function setVolume(device, volume) { while (true) {} }"
        let session = makeSession(script, callTimeLimit: 0.3, transport: RecordingTransport(), events: events)
        #expect(await start(session, volume: 0.5) == nil)
        #expect(events.stops.count == 1)
        session.close()
    }
}

// MARK: - Tier

@Suite("Volume plugins — the plugin tier")
struct VolumePluginTierTests {
    @Test("A plugin tier is linear and attenuates in the device")
    func linearTier() {
        #expect(VolumeMapping.sliderFraction(forSystemGain: 0.5, tier: .plugin) == 0.5)
        #expect(VolumeMapping.systemGain(forSliderFraction: 0.5, tier: .plugin) == 0.5)
        #expect(VolumeFeedback.gain(tier: .plugin, sliderFraction: 0.3) == 1.0)
        #expect(DeviceVolumeMonitor.storedVolume(0.005, tier: .plugin) == 0)
        #expect(DeviceDetailSheet.tierDisplayName(.plugin) == "Plugin")
        #expect(DeviceDetailSheet.canChooseSoftware(autoTier: .plugin))
    }

    @Test("A device's first plugin level is the software slider's, at most half way")
    func firstVolume() {
        #expect(VolumePluginController.firstVolume(softwareVolume: nil) == 0.5)
        #expect(VolumePluginController.firstVolume(softwareVolume: 1.0) == 0.5)
        #expect(abs(VolumePluginController.firstVolume(softwareVolume: 0.04) - 0.2) < 0.0001)
    }
}

// MARK: - Choices

@Suite("Volume plugins — choices")
struct VolumePluginChoiceTests {
    @Test("Each device's plugin, and the plugins that take new DACs, are kept until a settings reset")
    func remembersChoices() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsManager(directory: directory)
        #expect(settings.volumePluginChoice(for: "dac") == nil)
        #expect(!settings.isVolumePluginAutomatic("plugin"))

        settings.setVolumePluginChoice(.plugin("plugin"), for: "dac")
        settings.setVolumePluginChoice(.noPlugin, for: "other")
        settings.setVolumePluginAutomatic("plugin", true)
        #expect(settings.volumePluginChoice(for: "dac") == .plugin("plugin"))
        #expect(settings.volumePluginChoice(for: "other") == .noPlugin)
        #expect(settings.isVolumePluginAutomatic("plugin"))

        settings.setVolumePluginChoice(nil, for: "other")
        #expect(settings.volumePluginChoice(for: "other") == nil)

        settings.resetAllSettings()
        #expect(settings.volumePluginChoice(for: "dac") == nil)
        #expect(!settings.isVolumePluginAutomatic("plugin"))
    }
}

// MARK: - Settings

@Suite("Volume plugins — Settings")
struct VolumePluginSettingsTests {
    private func makeFile(_ manifest: VolumePluginManifest) -> VolumePluginFile {
        VolumePluginFile(
            id: manifest.id, fileURL: URL(fileURLWithPath: "/tmp/Test.finetuneplugin"),
            manifest: manifest, script: percentScript, loadError: nil)
    }

    @Test("A plugin's row says what it's doing, then who made it")
    func describesPlugins() {
        var manifest = makeManifest()
        manifest.author = "Someone"
        manifest.version = "1.0"
        manifest.description = "Hardware volume for the Test DAC"
        let plugin = makeFile(manifest)

        #expect(AudioTab.volumePluginDescription(plugin, status: .unused)
            == "Not in use\nHardware volume for the Test DAC\nBy Someone, version 1.0")
        #expect(AudioTab.volumePluginDescription(plugin, status: .active(deviceNames: ["DAC A", "DAC B"]))
            .hasPrefix("Sets the volume of DAC A, DAC B\n"))

        let broken = VolumePluginFile(
            id: "Broken.finetuneplugin", fileURL: URL(fileURLWithPath: "/tmp/Broken.finetuneplugin"),
            manifest: nil, script: nil, loadError: "The file has no /* @manifest … */ comment.")
        #expect(broken.name == "Broken")
        #expect(AudioTab.volumePluginDescription(broken, status: .invalid("The file has no /* @manifest … */ comment."))
            == "Can't be loaded: The file has no /* @manifest … */ comment.")
    }

    @Test("The Audio tab's row sums the plugins up, so the tab stays short")
    func summarizesPlugins() {
        #expect(AudioTab.volumePluginsSummary([]).hasSuffix(". None installed"))
        #expect(AudioTab.volumePluginsSummary([.unused]).hasSuffix(". 1 installed"))
        #expect(AudioTab.volumePluginsSummary([.active(deviceNames: ["DAC B"]), .active(deviceNames: ["DAC A"]), .invalid("x")])
            .hasSuffix(". 3 installed, in use on DAC A, DAC B, 1 with a problem"))
    }
}

// MARK: - Device menu

@Suite("Volume plugins — a device's menu")
struct VolumePluginMenuTests {
    private typealias Menu = DeviceDetailSheet.PluginMenu
    private let plugins = [(id: "a", name: "Plugin A"), (id: "b", name: "Plugin B"), (id: "c", name: "Plugin C")]

    private func menu(
        compatible: [String], choice: VolumePluginChoice?, active: String? = nil, problem: String? = nil
    ) -> Menu {
        Menu.make(
            plugins: plugins, compatibleIDs: compatible, choice: choice,
            activePluginID: active, problem: problem, onSelect: { _ in })
    }

    @Test("None, then the plugins written for the device; the others wait for ⌥, paler")
    func listsPlugins() {
        let menu = menu(compatible: ["b"], choice: nil)
        #expect(menu.options.map(\.id) == [Menu.noPluginID, "b"])
        #expect(menu.options.allSatisfy(\.isCompatible))
        #expect(menu.otherOptions.map(\.id) == ["a", "c"])
        #expect(menu.otherOptions.allSatisfy { !$0.isCompatible })
        #expect(menu.selectedID == Menu.noPluginID)
        #expect(menu.caption == "A plugin can set this DAC's own volume.")
    }

    @Test("A device with no plugin written for it says ⌥ lists the others")
    func hintsAtOptionKey() {
        let menu = menu(compatible: [], choice: .noPlugin)
        #expect(menu.options.map(\.id) == [Menu.noPluginID])
        #expect(menu.caption?.contains("⌥") == true)
        #expect(!menu.captionIsWarning)
    }

    @Test("A plugin chosen though it isn't written for the device stays in view, with a warning")
    func keepsForcedChoice() {
        let menu = menu(compatible: ["b"], choice: .plugin("c"), active: "c")
        #expect(menu.options.map(\.id) == [Menu.noPluginID, "b", "c"])
        #expect(menu.options.last?.isCompatible == false)
        #expect(menu.otherOptions.map(\.id) == ["a"])
        #expect(menu.selectedID == "c")
        #expect(menu.captionIsWarning)
    }

    @Test("A chosen plugin that is gone from the folder is still shown, and its problem said")
    func keepsMissingChoice() {
        let menu = menu(compatible: [], choice: .plugin("gone"), problem: "The plugin is no longer in the plugins folder.")
        #expect(menu.options.last?.id == "gone")
        #expect(menu.options.last?.title == "gone (missing)")
        #expect(menu.caption == "The plugin is no longer in the plugins folder.")
        #expect(menu.captionIsWarning)
    }

    @Test("A plugin that drives the device says so, one still starting says that")
    func describesActivePlugin() {
        #expect(menu(compatible: ["a"], choice: .plugin("a"), active: "a").caption?.hasPrefix("Sets the DAC's own volume") == true)
        #expect(menu(compatible: ["a"], choice: .plugin("a")).caption == "Starting the plugin…")
    }
}

// MARK: - Bundled iBasso plugin

@Suite("Volume plugins — iBasso DC plugin")
struct IBassoPluginTests {
    private static let file = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("plugins/iBasso DC.finetuneplugin")

    private func makeIBassoSession(
        productName: String, vendorID: Int = 0x262A, productID: Int = 0,
        transport: RecordingTransport, events: EventLog
    ) throws -> VolumePluginSession {
        let file = VolumePluginLoader.load(Self.file)
        #expect(file.loadError == nil)
        let manifest = try #require(file.manifest)
        let script = try #require(file.script)
        return VolumePluginSession(
            manifest: manifest,
            script: script,
            scriptURL: file.fileURL,
            transport: transport,
            info: VolumePluginSession.DeviceInfo(
                name: productName, uid: "uid-\(productName)",
                vendorID: vendorID, productID: productID, productName: productName),
            onEvent: { events.append($0) }
        )
    }

    /// The DC06's register writes: both registers of the left chip, then of the right one
    private static func chipWrites(_ value: UInt8) -> [[UInt8]] {
        [
            padded([1, 0x11, 0x98, 0x90, 0x10, 0x00, 0x01, value]),
            padded([2, 0x11, 0x98, 0x90, 0x0F, 0x00, 0x01, value]),
            padded([3, 0x11, 0x98, 0x92, 0x10, 0x00, 0x01, value]),
            padded([4, 0x11, 0x98, 0x92, 0x0F, 0x00, 0x01, value]),
        ]
    }

    /// The level given to the controller: two-byte offset writes to 0xA2, left then right
    private static func controllerWrites(_ value: UInt8) -> [[UInt8]] {
        [
            padded([19, 0x11, 0xA0, 0xA2, 0x00, 0x10, 0x01, value]),
            padded([20, 0x11, 0xA0, 0xA2, 0x00, 0x11, 0x01, value]),
        ]
    }

    /// The reads of the controller's level, left then right, that the models with one start with
    private static let levelReads: [[UInt8]] = [
        padded([0x15, 0x12, 0xE4, 0xA2, 0x00, 0x10, 0x01]),
        padded([0x16, 0x12, 0xE4, 0xA2, 0x00, 0x11, 0x01]),
    ]

    @Test("It is one file, and matches iBasso's models by name, and the DC03 Pro by product ID")
    func matching() throws {
        let file = VolumePluginLoader.load(Self.file)
        #expect(file.loadError == nil)
        #expect(file.id == "finetune.ibasso-dc")
        let manifest = try #require(file.manifest)
        #expect(manifest.hid.outputReportLength == nil)
        func matches(_ vendorID: Int, _ productID: Int, _ name: String?) -> Bool {
            VolumePluginMatching.hidMatches(
                anyOf: manifest.match, vendorID: vendorID, productID: productID, productName: name, usagePairs: [])
        }
        #expect(matches(0x262A, 0x1234, "iBasso-DC06-Pro"))
        #expect(matches(0x262A, 0x1234, "iBasso-DC06"))
        #expect(matches(0x262A, 0x187E, nil))
        #expect(matches(0x2FC6, 0x1234, "iBasso DC07 Pro"))
        #expect(matches(0x0661, 0x1234, "DC04U"))
        #expect(!matches(0x2FC6, 0x1234, "iBasso DC-Elite"))
        #expect(!matches(0x2FC6, 0x1234, "Another DAC"))
        #expect(!matches(0x1234, 0x1234, "iBasso-DC06-Pro"))
    }

    @Test("DC06 Pro: the level the controller answers with when the plugin starts wins")
    func readsTheLevel() async throws {
        let transport = RecordingTransport()
        let events = EventLog()
        let session = try makeIBassoSession(productName: "iBasso-DC06-Pro", transport: transport, events: events)
        // Each answer starts with its read's command number, with the attenuation in byte 4: the
        // left channel at step 50, the right one at step 60
        let attached = await start(session, volume: 0.9, thenReports: [
            [0x16, 0x12, 0x00, 0x00, 40, 0x00, 0x00, 0x00],
            [0x15, 0x12, 0x00, 0x00, 50, 0x00, 0x00, 0x00],
        ])
        #expect(attached?.volume == 0.6)
        #expect(transport.reports == Self.levelReads)
        #expect(events.failures.isEmpty)
        session.close()
    }

    @Test("DC06 Pro: without an answer, the chips, then the controller, which a mute leaves at the level")
    func dc06Pro() async throws {
        let transport = RecordingTransport()
        let session = try makeIBassoSession(productName: "iBasso-DC06-Pro", transport: transport, events: EventLog())
        _ = await start(session, volume: 1.0)
        #expect(transport.reports == Self.levelReads + Self.chipWrites(0) + Self.controllerWrites(0))

        session.request(volume: 0.5)
        await idle(session)
        #expect(Array(transport.reports.suffix(6)) == Self.chipWrites(50) + Self.controllerWrites(50))

        let before = transport.reports.count
        session.request(muted: true)
        await idle(session)
        #expect(Array(transport.reports.dropFirst(before)) == Self.chipWrites(255))

        session.request(muted: false)
        await idle(session)
        #expect(Array(transport.reports.suffix(6)) == Self.chipWrites(50) + Self.controllerWrites(50))
        session.close()
    }

    @Test("DC06: the chips alone, with no controller to read the level of")
    func dc06() async throws {
        let transport = RecordingTransport()
        let session = try makeIBassoSession(productName: "iBasso-DC06", transport: transport, events: EventLog())
        _ = await start(session, volume: 0.01)
        #expect(transport.reports == Self.chipWrites(155))
        session.close()
    }

    @Test("DC03 Pro: four-byte offset writes, with the controller's copy of each channel")
    func dc03Pro() async throws {
        let transport = RecordingTransport()
        // Known by its product ID when its name is empty
        let session = try makeIBassoSession(productName: "", productID: 0x187E, transport: transport, events: EventLog())
        _ = await start(session, volume: 0.5)
        let reports = transport.reports
        try #require(reports.count == 12)
        #expect(Array(reports.prefix(2)) == Self.levelReads)
        #expect(reports[2] == padded([1, 0x11, 0x88, 0x60, 0x00, 0x00, 0x05, 0x09, 0x00, 0x01, 0x00, 50]))
        #expect(reports[8] == Self.controllerWrites(50)[0])
        #expect(reports[11] == Self.controllerWrites(50)[1])
        #expect(reports.allSatisfy { $0.count == 16 })
        session.close()
    }

    @Test("DC07 Pro and DC04U: one frame holding the step")
    func frames() async throws {
        let eightByte = RecordingTransport()
        let dc07 = try makeIBassoSession(productName: "iBasso DC07 Pro", vendorID: 0x2FC6, transport: eightByte, events: EventLog())
        _ = await start(dc07, volume: 0.3)
        #expect(eightByte.reports == [[0x01, 0x10, 0xEF, 30, 30, 0, 0, 0]])
        dc07.close()

        let sixtyFourByte = RecordingTransport()
        let dc04u = try makeIBassoSession(productName: "DC04U", vendorID: 0x0661, transport: sixtyFourByte, events: EventLog())
        _ = await start(dc04u, volume: 0.3)
        #expect(sixtyFourByte.reports == [padded([0x4B, 0x01, 0x3F, 0x08, 0x01, 0x10, 30, 30], to: 64)])
        dc04u.close()
    }

    @Test("A level set with the DAC's buttons reaches FineTune, and ends a mute")
    func levelsFromTheDAC() async throws {
        let dc06Events = EventLog()
        let tonfaEvents = EventLog()
        let macchiatoEvents = EventLog()
        let dc06 = try makeIBassoSession(
            productName: "iBasso-DC06-Pro", transport: RecordingTransport(), events: dc06Events)
        let tonfa = try makeIBassoSession(
            productName: "iBasso DC-Tonfa", vendorID: 0x2FC6, transport: RecordingTransport(), events: tonfaEvents)
        let macchiato = try makeIBassoSession(
            productName: "Macchiato", vendorID: 0x0661, transport: RecordingTransport(), events: macchiatoEvents)
        _ = await start(dc06, volume: 0.5, muted: true)
        _ = await start(tonfa, volume: 0.5)
        _ = await start(macchiato, volume: 0.5)
        // Past the window in which a report is taken as the DAC echoing FineTune
        try await Task.sleep(for: .milliseconds(VolumePluginSession.echoWindowMS + 100))

        dc06.handleInputReport(reportID: 0, bytes: [0, 0, 0, 0, 0xFE, 0x01, 0, 0, 20, 20, 0, 0, 0, 0, 0, 0])
        tonfa.handleInputReport(reportID: 0, bytes: [0, 0x12, 0, 0, 30, 0, 0, 0])
        macchiato.handleInputReport(reportID: 0, bytes: padded([0, 0, 0, 0, 0, 0x10, 42], to: 64))
        await idle(dc06)
        await idle(tonfa)
        await idle(macchiato)

        #expect(dc06Events.reportedMutes == [false])
        #expect(dc06Events.reportedVolumes == [0.8])
        #expect(tonfaEvents.reportedVolumes == [0.3])
        #expect(macchiatoEvents.reportedVolumes == [0.42])
        dc06.close()
        tonfa.close()
        macchiato.close()
    }

    @Test("A model the plugin doesn't know fails instead of getting commands")
    func unknownModel() async throws {
        let transport = RecordingTransport()
        let events = EventLog()
        let session = try makeIBassoSession(
            productName: "iBasso DC-Elite", vendorID: 0x2FC6, transport: transport, events: events)
        #expect(await start(session, volume: 0.5) == nil)
        #expect(transport.reports.isEmpty)
        #expect(events.failures.count == 1)
    }
}
