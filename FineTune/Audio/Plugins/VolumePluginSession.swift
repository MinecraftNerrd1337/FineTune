// FineTune/Audio/Plugins/VolumePluginSession.swift
// One volume plugin driving one device: the plugin's script in JavaScriptCore, talking to the device's HID interface

#if !APP_STORE

import Darwin
import Foundation
import IOKit.hid
import JavaScriptCore
import os

/// What a session tells its controller
nonisolated enum VolumePluginEvent: Sendable {
    /// The device changed level by itself (its own buttons), as the plugin read it: 0…1
    case volumeReported(Float)
    case muteReported(Bool)
    /// The script threw, or the device refused a report
    case failed(String)
    /// The plugin works again after a failure
    case recovered
    /// The script ran too long and was stopped for good: the session sends nothing more
    case stopped(String)
}

/// Where a session's reports go: the device's HID interface, or a stand-in in tests
protocol VolumePluginTransport: Sendable {
    /// Sends `bytes` as they are, report ID byte included when the ID isn't 0
    func setReport(_ type: IOHIDReportType, reportID: UInt8, bytes: [UInt8]) -> IOReturn
    /// Reads up to `length` bytes, report ID byte included when the ID isn't 0
    func getReport(_ type: IOHIDReportType, reportID: UInt8, length: Int) -> (result: IOReturn, bytes: [UInt8])
}

/// A HID device handed across threads. The IOHIDDevice calls used on it are thread-safe.
nonisolated struct HIDDeviceHandle: VolumePluginTransport, @unchecked Sendable {
    let device: IOHIDDevice

    func setReport(_ type: IOHIDReportType, reportID: UInt8, bytes: [UInt8]) -> IOReturn {
        bytes.withUnsafeBufferPointer { buffer in
            IOHIDDeviceSetReport(device, type, CFIndex(reportID), buffer.baseAddress!, buffer.count)
        }
    }

    func getReport(_ type: IOHIDReportType, reportID: UInt8, length: Int) -> (result: IOReturn, bytes: [UInt8]) {
        var buffer = [UInt8](repeating: 0, count: max(length, 1))
        if reportID != 0 { buffer[0] = reportID }
        var size = CFIndex(buffer.count)
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            IOHIDDeviceGetReport(device, type, CFIndex(reportID), pointer.baseAddress!, &size)
        }
        return (result, Array(buffer.prefix(max(0, min(size, buffer.count)))))
    }
}

/// One plugin driving one device. The plugin's script runs in a JavaScript context of its own,
/// on the session's serial queue: never on the main thread, never in the audio callback.
///
/// The script defines `setVolume(device, volume)` and may define `setMute(device, muted)`,
/// `onAttach(device)` and `onInputReport(device, reportID, bytes)`. Through `device` it can only
/// send reports to this one HID interface and tell FineTune about level changes; it has no access
/// to files, the network or other devices.
nonisolated final class VolumePluginSession: @unchecked Sendable {
    struct DeviceInfo: Sendable {
        let name: String
        let uid: String
        let vendorID: Int
        let productID: Int
        let productName: String
    }

    /// The level and mute state a device is at once the plugin has taken it over
    struct Attached: Sendable {
        let volume: Double
        let muted: Bool
    }

    let manifest: VolumePluginManifest
    private let script: String
    private let scriptURL: URL
    private let transport: any VolumePluginTransport
    private let info: DeviceInfo
    private let queue: DispatchQueue
    private let onEvent: @Sendable (VolumePluginEvent) -> Void
    /// Seconds
    private let callTimeLimit: Double
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "VolumePlugin")

    // Confined to `queue`
    private var context: JSContext?
    private var deviceObject: JSValue?
    private var hasSetMute = false
    private var hasInputHandler = false
    private var isClosed = false
    private var isAttaching = false
    private var attachReportedVolume: Double?
    private var attachReportedMute: Bool?
    /// How long the plugin asked, in onAttach, to wait for the level the device sends back
    private var levelWaitMS: Int?
    /// A start waiting for the device's level, finished by its report or after `levelWaitMS`
    private var pendingAttach: PendingAttach?

    private struct PendingAttach {
        let volume: Double
        let muted: Bool
        let finish: (Attached?) -> Void
    }
    private var lastVolume: Double = 0
    private var lastMuted = false
    private var lastSendTime: DispatchTime?
    /// What the device reported while it could still be echoing FineTune's last change: taken
    /// once that time is over, unless FineTune changes the device again first
    private var heldVolume: Double?
    private var heldMute: Bool?
    private var isHeldCheckScheduled = false
    private var didFail = false
    private var lastFailure: String?
    /// The script ran too long once: it is never called again
    private var isStopped = false

    // Shared with the main thread, behind `lock`
    private struct Pending {
        var volume: Double?
        var muted: Bool?
        var drainQueued = false
    }
    private let lock = NSLock()
    private var pending = Pending()

    /// Level reports this soon after FineTune sent something may be the device echoing it: they
    /// wait until then, and only the last one counts
    static let echoWindowMS = 400
    /// Longest a plugin may pause with `sleep(ms)`
    static let maximumSleepMS = 200
    /// Longest a plugin may have FineTune wait, with `device.waitForLevel(ms)`, for the level a
    /// device sends back after onAttach asked for it
    static let maximumLevelWaitMS = 1000
    /// Longest one call into the script may run, unless a test sets another limit. A script stuck
    /// in a loop is stopped there, and the session gives up on it.
    static let defaultCallTimeLimit = 5.0
    /// kIOReturnNotPermitted, which Swift doesn't import: macOS (Input Monitoring) refused the device
    private static let notPermitted = IOReturn(bitPattern: 0xE000_02E2)

    init(
        manifest: VolumePluginManifest,
        script: String,
        scriptURL: URL,
        transport: any VolumePluginTransport,
        info: DeviceInfo,
        callTimeLimit: Double = VolumePluginSession.defaultCallTimeLimit,
        onEvent: @escaping @Sendable (VolumePluginEvent) -> Void
    ) {
        self.callTimeLimit = callTimeLimit
        self.manifest = manifest
        self.script = script
        self.scriptURL = scriptURL
        self.transport = transport
        self.info = info
        self.onEvent = onEvent
        self.queue = DispatchQueue(label: "com.finetune.volume-plugin.\(manifest.id)", qos: .userInitiated)
    }

    // MARK: - Lifecycle

    /// Runs the script, then brings the device to `volume` and `muted`, unless the plugin read the
    /// device's own level in `onAttach`, or reported it while FineTune waited for it.
    /// `completion` runs on the main actor with where the device stands, or nil when the plugin
    /// failed.
    func start(volume: Double, muted: Bool, completion: @escaping @Sendable @MainActor (Attached?) -> Void) {
        queue.async { [self] in
            attach(volume: volume, muted: muted) { attached in
                Task { @MainActor in completion(attached) }
            }
        }
    }

    /// Stops the script. Changes still queued are dropped.
    func close() {
        queue.async { [self] in
            isClosed = true
            context?.exceptionHandler = nil
            deviceObject = nil
            context = nil
        }
    }

    /// Calls `finish` on the queue, at once or once the level the plugin waits for came back
    private func attach(volume: Double, muted: Bool, finish: @escaping (Attached?) -> Void) {
        guard !isClosed, let context = JSContext() else {
            finish(nil)
            return
        }
        context.name = "FineTune plugin: \(manifest.name)"
        Self.limitExecutionTime(of: context, to: callTimeLimit)
        context.exceptionHandler = { [weak self] _, exception in
            self?.fail("Script error: \(VolumePluginSession.describe(exception))")
        }
        self.context = context
        installGlobals(in: context)
        deviceObject = makeDeviceObject(in: context)

        didFail = false
        let started = DispatchTime.now()
        context.evaluateScript(script, withSourceURL: scriptURL)
        stopIfTooLong(since: started, in: "script")
        guard !didFail, !isStopped else {
            finish(nil)
            return
        }
        guard isFunction("setVolume") else {
            fail("The script has no setVolume(device, volume) function.")
            finish(nil)
            return
        }
        hasSetMute = isFunction("setMute")
        hasInputHandler = isFunction("onInputReport")

        if isFunction("onAttach") {
            isAttaching = true
            call("onAttach")
            guard !didFail, !isStopped else {
                isAttaching = false
                finish(nil)
                return
            }
        }

        // The plugin asked the device for its level: its answer comes through onInputReport,
        // which runs on this queue meanwhile, and ends the wait
        if let wait = levelWaitMS, attachReportedVolume == nil, hasInputHandler {
            pendingAttach = PendingAttach(volume: volume, muted: muted, finish: finish)
            queue.asyncAfter(deadline: .now() + .milliseconds(wait)) { [weak self] in
                self?.finishAttach()
            }
            return
        }
        isAttaching = false
        finish(settle(volume: volume, muted: muted))
    }

    /// Ends a start that waited for the device's level, whether it came or not
    private func finishAttach() {
        guard let pending = pendingAttach else { return }
        pendingAttach = nil
        isAttaching = false
        guard !isClosed, !isStopped else {
            pending.finish(nil)
            return
        }
        // A report the plugin choked on meanwhile doesn't fail the start
        didFail = false
        pending.finish(settle(volume: pending.volume, muted: pending.muted))
    }

    /// Brings the device to FineTune's level, unless the plugin read the device's own
    private func settle(volume: Double, muted: Bool) -> Attached? {
        // The device's own reading wins over FineTune's; a mute from either side is kept
        lastVolume = attachReportedVolume ?? volume
        let deviceMuted = attachReportedMute ?? false
        lastMuted = muted || deviceMuted
        if muted && !deviceMuted {
            if hasSetMute { call("setMute", true) } else { call("setVolume", 0.0) }
        } else if !lastMuted && attachReportedVolume == nil {
            call("setVolume", lastVolume)
        }
        return didFail || isStopped ? nil : Attached(volume: lastVolume, muted: lastMuted)
    }

    // MARK: - Requests from FineTune

    /// Sets the device's level (0…1, the slider's position). Changes that arrive while the device
    /// is busy are merged: only the latest one is sent.
    func request(volume: Double) {
        lock.lock()
        pending.volume = volume
        let schedule = claimDrain()
        lock.unlock()
        if schedule { queue.async { [self] in drain() } }
    }

    func request(muted: Bool) {
        lock.lock()
        pending.muted = muted
        let schedule = claimDrain()
        lock.unlock()
        if schedule { queue.async { [self] in drain() } }
    }

    /// Passes an input report from the device to the plugin's `onInputReport`
    func handleInputReport(reportID: UInt32, bytes: [UInt8]) {
        queue.async { [self] in
            guard !isClosed, !isStopped, hasInputHandler else { return }
            didFail = false
            call("onInputReport", Int(reportID), bytes)
            noteRecovery()
        }
    }

    /// Calls `done` once everything queued so far has run (for tests)
    func whenIdle(_ done: @escaping @Sendable () -> Void) {
        queue.async(execute: done)
    }

    /// Call with `lock` held. True when the caller must queue a drain.
    private func claimDrain() -> Bool {
        guard !pending.drainQueued else { return false }
        pending.drainQueued = true
        return true
    }

    /// `setVolume` is only called while unmuted: a level set while muted is sent on unmute.
    /// Without `setMute`, muting sets the level to 0.
    private func drain() {
        lock.lock()
        let next = pending
        pending = Pending()
        lock.unlock()
        guard !isClosed, !isStopped, context != nil else { return }

        didFail = false
        var sentVolume = false
        if let volume = next.volume { lastVolume = volume }
        if let muted = next.muted, muted != lastMuted {
            lastMuted = muted
            forgetHeldReports()
            if muted {
                if hasSetMute { call("setMute", true) } else { call("setVolume", 0.0) }
            } else {
                if hasSetMute { call("setMute", false) }
                call("setVolume", lastVolume)
                sentVolume = true
            }
        }
        if next.volume != nil && !lastMuted && !sentVolume {
            forgetHeldReports()
            call("setVolume", lastVolume)
        }
        noteRecovery()

        // Give the device a moment before the next change
        let gap = manifest.minimumIntervalMS ?? VolumePluginManifest.defaultMinimumIntervalMS
        if gap > 0 { Thread.sleep(forTimeInterval: Double(gap) / 1000) }
    }

    // MARK: - Script

    private func isFunction(_ name: String) -> Bool {
        context?.evaluateScript("typeof \(name)")?.toString() == "function"
    }

    /// Calls a function of the script with `device` as its first argument
    @discardableResult
    private func call(_ name: String, _ arguments: Any...) -> JSValue? {
        guard !isClosed, !isStopped, let context, let deviceObject, let function = context.objectForKeyedSubscript(name) else {
            return nil
        }
        var all: [Any] = [deviceObject]
        all.append(contentsOf: arguments)
        let started = DispatchTime.now()
        let result = function.call(withArguments: all)
        stopIfTooLong(since: started, in: "\(name)()")
        return result
    }

    /// Gives up on a script whose call ran too long: JavaScriptCore stopped it in a loop, or it
    /// kept the device waiting
    private func stopIfTooLong(since started: DispatchTime, in place: String) {
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000
        guard seconds >= callTimeLimit, !isStopped else { return }
        isStopped = true
        didFail = true
        let message = "The plugin's \(place) ran for more than \(callTimeLimit.formatted()) seconds, and was stopped. Reload the plugin once it is fixed."
        logger.error("\(self.manifest.name, privacy: .public): \(message, privacy: .public)")
        lastFailure = message
        onEvent(.stopped(message))
    }

    /// JavaScriptCore stops a script that runs past a time limit, such as one stuck in a loop.
    /// The call that sets the limit is not public API, so it is looked up when the app runs, and
    /// skipped where it isn't there.
    private static func limitExecutionTime(of context: JSContext, to seconds: Double) {
        guard let setLimit = setExecutionTimeLimit, let group = JSContextGetGroup(context.jsGlobalContextRef) else { return }
        setLimit(group, seconds, nil, nil)
    }

    /// Whether JavaScriptCore can stop a script stuck in a loop (for tests)
    static var canLimitExecutionTime: Bool { setExecutionTimeLimit != nil }

    private typealias ShouldTerminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetExecutionTimeLimit = @convention(c) (JSContextGroupRef?, Double, ShouldTerminate?, UnsafeMutableRawPointer?) -> Void

    private static let setExecutionTimeLimit: SetExecutionTimeLimit? = {
        // RTLD_DEFAULT: every image loaded in the process, JavaScriptCore included
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else {
            return nil
        }
        return unsafeBitCast(symbol, to: SetExecutionTimeLimit.self)
    }()

    private func fail(_ message: String) {
        didFail = true
        logger.error("\(self.manifest.name, privacy: .public): \(message, privacy: .public)")
        // Report each problem once, not on every volume change
        guard message != lastFailure else { return }
        lastFailure = message
        onEvent(.failed(message))
    }

    private func noteRecovery() {
        guard !didFail, !isStopped, lastFailure != nil else { return }
        lastFailure = nil
        onEvent(.recovered)
    }

    /// Throws a JavaScript error from inside a callback
    private func throwError(_ message: String) {
        guard let context = JSContext.current() else { return }
        context.exception = JSValue(newErrorFromMessage: message, in: context)
    }

    private static func describe(_ exception: JSValue?) -> String {
        guard let exception, let message = exception.toString() else { return "unknown error" }
        if let line = exception.forProperty("line"), line.isNumber {
            return "\(message) (line \(line.toInt32()))"
        }
        return message
    }

    private func installGlobals(in context: JSContext) {
        let pluginName = manifest.name
        let logger = self.logger
        let log: @convention(block) () -> Void = {
            let parts = (JSContext.currentArguments() as? [JSValue] ?? []).map { $0.toString() ?? "" }
            logger.info("\(pluginName, privacy: .public): \(parts.joined(separator: " "), privacy: .public)")
        }
        let console = JSValue(newObjectIn: context)
        for level in ["log", "info", "warn", "error", "debug"] {
            console?.setObject(unsafeBitCast(log, to: AnyObject.self), forKeyedSubscript: level as NSString)
        }
        context.setObject(console, forKeyedSubscript: "console" as NSString)
        context.setObject(unsafeBitCast(log, to: AnyObject.self), forKeyedSubscript: "log" as NSString)

        // For devices that need a pause between two reports
        let sleep: @convention(block) (JSValue) -> Void = { milliseconds in
            let value = milliseconds.isNumber ? milliseconds.toDouble() : 0
            guard value.isFinite, value > 0 else { return }
            Thread.sleep(forTimeInterval: min(value, Double(VolumePluginSession.maximumSleepMS)) / 1000)
        }
        context.setObject(unsafeBitCast(sleep, to: AnyObject.self), forKeyedSubscript: "sleep" as NSString)
    }

    private func makeDeviceObject(in context: JSContext) -> JSValue? {
        guard let device = JSValue(newObjectIn: context), let hidObject = JSValue(newObjectIn: context) else { return nil }
        device.setValue(info.name, forProperty: "name")
        device.setValue(info.uid, forProperty: "uid")
        device.setValue(info.vendorID, forProperty: "vendorID")
        device.setValue(info.productID, forProperty: "productID")
        device.setValue(info.productName, forProperty: "productName")

        let sendOutput: @convention(block) (JSValue, JSValue) -> Bool = { [weak self] reportID, bytes in
            self?.send(kIOHIDReportTypeOutput, reportID: reportID, bytes: bytes) ?? false
        }
        let sendFeature: @convention(block) (JSValue, JSValue) -> Bool = { [weak self] reportID, bytes in
            self?.send(kIOHIDReportTypeFeature, reportID: reportID, bytes: bytes) ?? false
        }
        let getFeature: @convention(block) (JSValue, JSValue) -> JSValue? = { [weak self] reportID, length in
            self?.getFeatureReport(reportID: reportID, length: length)
        }
        hidObject.setObject(unsafeBitCast(sendOutput, to: AnyObject.self), forKeyedSubscript: "sendOutputReport" as NSString)
        hidObject.setObject(unsafeBitCast(sendFeature, to: AnyObject.self), forKeyedSubscript: "sendFeatureReport" as NSString)
        hidObject.setObject(unsafeBitCast(getFeature, to: AnyObject.self), forKeyedSubscript: "getFeatureReport" as NSString)
        device.setObject(hidObject, forKeyedSubscript: "hid" as NSString)

        let reportVolume: @convention(block) (JSValue) -> Void = { [weak self] value in
            self?.reportVolume(value)
        }
        let reportMute: @convention(block) (JSValue) -> Void = { [weak self] value in
            self?.reportMute(value)
        }
        device.setObject(unsafeBitCast(reportVolume, to: AnyObject.self), forKeyedSubscript: "reportVolume" as NSString)
        device.setObject(unsafeBitCast(reportMute, to: AnyObject.self), forKeyedSubscript: "reportMute" as NSString)
        let waitForLevel: @convention(block) (JSValue) -> Void = { [weak self] milliseconds in
            self?.waitForLevel(milliseconds)
        }
        device.setObject(unsafeBitCast(waitForLevel, to: AnyObject.self), forKeyedSubscript: "waitForLevel" as NSString)
        return device
    }

    // MARK: - Device access for the script

    private func send(_ type: IOHIDReportType, reportID: JSValue, bytes: JSValue) -> Bool {
        guard let id = Self.byte(reportID) else {
            throwError("reportID must be an integer from 0 to 255")
            return false
        }
        // The length first, so a huge array isn't copied before it is refused
        let count = bytes.isArray ? bytes.forProperty("length")?.toDouble() ?? .nan : .nan
        guard count.isFinite, count <= Double(VolumePluginManifest.maximumReportLength) else {
            throwError(bytes.isArray
                       ? "a report can't be longer than \(VolumePluginManifest.maximumReportLength) bytes"
                       : "a report must be an array of integers from 0 to 255")
            return false
        }
        guard let data = Self.bytes(fromNumbers: bytes.toArray() ?? []) else {
            throwError("a report must be an array of integers from 0 to 255")
            return false
        }
        let declared = type == kIOHIDReportTypeFeature ? manifest.hid.featureReportLength : manifest.hid.outputReportLength
        let length = declared ?? data.count
        guard data.count <= length else {
            throwError("the report has \(data.count) bytes, more than the \(length) the manifest declares")
            return false
        }
        guard length > 0, let report = Self.framedReport(data, reportID: id, length: length) else {
            throwError("a report can't be empty")
            return false
        }
        let result = transport.setReport(type, reportID: id, bytes: report)
        lastSendTime = .now()
        guard result == kIOReturnSuccess else {
            fail(result == Self.notPermitted
                 ? "macOS doesn't let FineTune use this device. Allow FineTune in System Settings > Privacy & Security > Input Monitoring."
                 : "The device refused a report (IOReturn \(Self.hex(result))).")
            return false
        }
        return true
    }

    private func getFeatureReport(reportID: JSValue, length: JSValue) -> JSValue? {
        guard let context = JSContext.current() else { return nil }
        guard let id = Self.byte(reportID) else {
            throwError("reportID must be an integer from 0 to 255")
            return JSValue(nullIn: context)
        }
        let requested = length.isNumber ? Int(exactly: length.toDouble().rounded()) : manifest.hid.featureReportLength
        guard let requested, (1...VolumePluginManifest.maximumReportLength).contains(requested) else {
            throwError("the length must be an integer from 1 to \(VolumePluginManifest.maximumReportLength)")
            return JSValue(nullIn: context)
        }
        let read = transport.getReport(kIOHIDReportTypeFeature, reportID: id, length: requested + (id == 0 ? 0 : 1))
        guard read.result == kIOReturnSuccess else {
            logger.debug("\(self.manifest.name, privacy: .public): feature report \(id) not read (IOReturn \(Self.hex(read.result), privacy: .public))")
            return JSValue(nullIn: context)
        }
        return JSValue(object: read.bytes.map { NSNumber(value: $0) }, in: context)
    }

    private func reportVolume(_ value: JSValue) {
        let level = value.isNumber ? value.toDouble() : .nan
        guard level.isFinite else {
            throwError("reportVolume expects a number from 0 to 1")
            return
        }
        let clamped = min(max(level, 0), 1)
        if isAttaching {
            attachReportedVolume = clamped
            if pendingAttach != nil {
                // After the plugin's call returns, so it can report the mute too
                queue.async { [weak self] in self?.finishAttach() }
            }
            return
        }
        if isEcho {
            heldVolume = clamped
            scheduleHeldCheck()
            return
        }
        lastVolume = clamped
        onEvent(.volumeReported(Float(clamped)))
    }

    /// In onAttach, after asking the device for its level: FineTune waits up to `milliseconds`
    /// for the plugin to report it from onInputReport, before sending its own level
    private func waitForLevel(_ milliseconds: JSValue) {
        guard isAttaching, pendingAttach == nil else {
            throwError("waitForLevel can only be called in onAttach")
            return
        }
        let value = milliseconds.isNumber ? milliseconds.toDouble() : .nan
        guard value.isFinite, value > 0 else {
            throwError("waitForLevel expects a number of milliseconds")
            return
        }
        levelWaitMS = Int(min(value, Double(Self.maximumLevelWaitMS)).rounded(.up))
    }

    private func reportMute(_ value: JSValue) {
        guard value.isBoolean else {
            throwError("reportMute expects true or false")
            return
        }
        let muted = value.toBool()
        if isAttaching {
            attachReportedMute = muted
            return
        }
        if isEcho {
            heldMute = muted
            scheduleHeldCheck()
            return
        }
        lastMuted = muted
        onEvent(.muteReported(muted))
    }

    private var isEcho: Bool {
        guard let lastSendTime else { return false }
        return DispatchTime.now() < lastSendTime + .milliseconds(Self.echoWindowMS)
    }

    /// FineTune is changing the device: what it reported before is out of date
    private func forgetHeldReports() {
        heldVolume = nil
        heldMute = nil
    }

    private func scheduleHeldCheck() {
        guard !isHeldCheckScheduled, let lastSendTime else { return }
        isHeldCheckScheduled = true
        queue.asyncAfter(deadline: lastSendTime + .milliseconds(Self.echoWindowMS)) { [weak self] in
            self?.takeHeldReports()
        }
    }

    /// Once the device can no longer be echoing FineTune, its last report is where it stands. A
    /// button pressed right after a change in FineTune moves the slider this way. An echo matching
    /// what FineTune sent changes nothing.
    private func takeHeldReports() {
        isHeldCheckScheduled = false
        guard !isClosed, !isStopped, heldVolume != nil || heldMute != nil else { return }
        guard !isEcho else {
            // FineTune sent something since: wait for that too
            scheduleHeldCheck()
            return
        }
        // A change FineTune is about to send wins over what the device said before it
        lock.lock()
        let requested = pending
        lock.unlock()
        let muted = requested.muted == nil ? heldMute : nil
        let volume = requested.volume == nil ? heldVolume : nil
        forgetHeldReports()
        if let muted, muted != lastMuted {
            lastMuted = muted
            onEvent(.muteReported(muted))
        }
        if let volume, volume != lastVolume {
            lastVolume = volume
            onEvent(.volumeReported(Float(volume)))
        }
    }

    // MARK: - Helpers

    /// An integer from 0 to 255
    static func byte(_ value: JSValue) -> UInt8? {
        guard value.isNumber else { return nil }
        return byte(value.toDouble())
    }

    static func byte(_ number: Double) -> UInt8? {
        guard number.isFinite, number == number.rounded(), (0...255).contains(number) else { return nil }
        return UInt8(number)
    }

    /// The bytes of a JavaScript array, or nil if one isn't an integer from 0 to 255
    static func bytes(fromNumbers items: [Any]) -> [UInt8]? {
        var result: [UInt8] = []
        result.reserveCapacity(items.count)
        for item in items {
            guard let number = item as? NSNumber, let value = byte(number.doubleValue) else { return nil }
            result.append(value)
        }
        return result
    }

    /// The bytes as they go to the device: `data` padded with zeros to `length`, after the report
    /// ID byte when the ID isn't 0. Nil when `data` is longer than `length`.
    static func framedReport(_ data: [UInt8], reportID: UInt8, length: Int) -> [UInt8]? {
        guard data.count <= length else { return nil }
        let body = data + [UInt8](repeating: 0, count: length - data.count)
        return reportID == 0 ? body : [reportID] + body
    }

    private static func hex(_ result: IOReturn) -> String {
        String(format: "0x%08X", UInt32(bitPattern: result))
    }
}

#endif
