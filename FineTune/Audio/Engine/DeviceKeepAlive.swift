// FineTune/Audio/Engine/DeviceKeepAlive.swift
import AppKit
import AudioToolbox
import Foundation
import os

// MARK: - Stream

/// What `DeviceKeepAliveService` needs from one device's keep-alive stream. A protocol so the
/// service's supervision logic can be tested without the HAL.
@MainActor
protocol KeepAliveStreaming: AnyObject {
    var deviceID: AudioDeviceID { get }
    /// Number of IO cycles rendered so far. Stops advancing when the HAL stops calling us.
    var renderedCycles: UInt64 { get }
    func start() throws
    func stop()
}

/// Keeps one output device streaming: an IOProc on the device itself (not an aggregate) that
/// writes digital silence. The HAL mixes it with every other client, so it changes nothing
/// audible, but the device's IO never stops: no USB stream stop, no DAC standby, no relock
/// when playback starts again.
///
/// The IO callback only clears the output buffers (sized by the HAL for whatever format and
/// sample rate the device runs at, so a rate change needs no adjustment) and counts cycles.
/// It is real-time safe: no allocation, lock, ObjC or Swift runtime call.
@MainActor
final class KeepAliveStream: KeepAliveStreaming {
    let deviceID: AudioDeviceID
    private let uid: String
    private var procID: AudioDeviceIOProcID?
    private let queue: DispatchQueue
    /// Written by the IO thread only, read by the main thread (an aligned 64-bit load).
    private let cycles: CycleCounter
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "KeepAlive")

    init(deviceID: AudioDeviceID, uid: String) {
        self.deviceID = deviceID
        self.uid = uid
        self.queue = DispatchQueue(label: "FineTune.KeepAlive.\(uid)", qos: .userInteractive)
        self.cycles = CycleCounter()
    }

    var renderedCycles: UInt64 { cycles.value }

    func start() throws {
        guard procID == nil else { return }
        let counter = cycles
        var newProcID: AudioDeviceIOProcID?
        var err = AudioDeviceCreateIOProcIDWithBlock(&newProcID, deviceID, queue) { @Sendable _, _, _, outOutputData, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(outOutputData)
            for buffer in buffers {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }
            counter.increment()
        }
        guard err == noErr, let newProcID else {
            throw KeepAliveError.createIOProcFailed(err)
        }
        procID = newProcID

        // A DAC with a microphone must not have its input opened (no recording indicator,
        // no microphone permission): this IOProc only ever uses output streams.
        disableInputStreams(procID: newProcID)

        err = AudioDeviceStart(deviceID, newProcID)
        guard err == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, newProcID)
            procID = nil
            throw KeepAliveError.startFailed(err)
        }
        logger.info("Keep-alive started on \(self.uid, privacy: .public) (#\(self.deviceID))")
    }

    func stop() {
        guard let procID else { return }
        AudioDeviceStop(deviceID, procID)
        AudioDeviceDestroyIOProcID(deviceID, procID)
        self.procID = nil
        logger.info("Keep-alive stopped on \(self.uid, privacy: .public) (#\(self.deviceID))")
    }

    private func disableInputStreams(procID: AudioDeviceIOProcID) {
        let inputCount = deviceID.streamCount(scope: kAudioObjectPropertyScopeInput)
        guard inputCount > 0 else { return }

        // AudioHardwareIOProcStreamUsage: { void* mIOProc; UInt32 mNumberStreams; UInt32 mStreamIsOn[]; }
        let headerSize = MemoryLayout<UnsafeMutableRawPointer>.size + MemoryLayout<UInt32>.size
        let totalSize = headerSize + inputCount * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: totalSize,
            alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment
        )
        defer { raw.deallocate() }
        raw.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(inputCount), toByteOffset: MemoryLayout<UnsafeMutableRawPointer>.size, as: UInt32.self)
        for index in 0..<inputCount {
            raw.storeBytes(of: UInt32(0), toByteOffset: headerSize + index * MemoryLayout<UInt32>.size, as: UInt32.self)
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIOProcStreamUsage,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let err = AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(totalSize), raw)
        if err != noErr {
            logger.warning("Keep-alive could not disable \(inputCount) input stream(s) on \(self.uid, privacy: .public): \(err)")
        }
    }
}

enum KeepAliveError: Error {
    case createIOProcFailed(OSStatus)
    case startFailed(OSStatus)
}

/// The cycle counter shared with the IO callback. A class so the callback captures a stable
/// address instead of the stream itself.
///
/// The count lives behind a raw pointer rather than in a stored property: a class property
/// access goes through Swift's dynamic exclusivity check (a runtime call), which has no place
/// in an IO callback. One writer (the IO thread), one reader (the main thread).
private final class CycleCounter: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<UInt64>

    init() {
        storage = .allocate(capacity: 1)
        storage.initialize(to: 0)
    }

    deinit {
        storage.deallocate()
    }

    var value: UInt64 { storage.pointee }

    @inline(__always)
    func increment() { storage.pointee &+= 1 }
}

// MARK: - Service

/// Supervises the keep-alive streams of the output devices the user turned it on for, so that
/// such a device is never left without one while it is connected:
/// - starts a stream when the device appears, and a new one when it comes back with a new ID;
/// - a watchdog checks every second that each stream still renders, and rebuilds one whose IO
///   stopped (wake from sleep, USB reset, sample-rate change from FineTune or Audio MIDI Setup,
///   another app changing the format) for two checks in a row;
/// - failed starts are retried with a growing delay (1 s up to 30 s), forever;
/// - a device another app holds in exclusive (hog) mode is polled every second and taken back
///   as soon as it is released;
/// - streams are stopped before system sleep and rebuilt after wake.
///
/// All timing uses the monotonic `ContinuousClock`, so a wall-clock change (NTP, time zone,
/// manual) can neither delay a retry nor fake a stall.
@MainActor
@Observable
final class DeviceKeepAliveService {
    enum Status: Equatable {
        case starting
        case running
        /// Another process holds the device in exclusive (hog) mode.
        case blockedByHogMode(pid_t)
        case failed(OSStatus)
    }

    /// Per device UID, for the devices the keep-alive is on for and that are connected.
    private(set) var statuses: [String: Status] = [:]

    private let settingsManager: SettingsManager
    private let deviceProvider: any AudioDeviceProviding
    private let makeStream: @MainActor (AudioDeviceID, String) -> any KeepAliveStreaming
    private let isAlive: (AudioDeviceID) -> Bool
    private let hogModeOwner: (AudioDeviceID) -> pid_t

    @ObservationIgnored private var streams: [String: any KeepAliveStreaming] = [:]
    @ObservationIgnored private var lastCycles: [String: UInt64] = [:]
    @ObservationIgnored private var stalledChecks: [String: Int] = [:]
    @ObservationIgnored private var failures: [String: Int] = [:]
    @ObservationIgnored private var lastHeartbeat: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var nextAttempt: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var isSleeping = false
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "KeepAlive")

    /// Watchdog checks a stream must fail in a row before it is rebuilt. One check can land in
    /// a normal IO pause (format change), two cannot.
    static let stallChecksBeforeRestart = 2
    static let watchdogInterval: Duration = .seconds(1)
    /// Two heartbeat samples closer than this are not compared. `check()` also runs on events
    /// (device list change, toggle), possibly milliseconds after the watchdog: within less
    /// than one IO cycle the counter cannot have moved, and that must not count as a stall.
    static let minimumHeartbeatSpacing: Duration = .milliseconds(500)

    init(
        settingsManager: SettingsManager,
        deviceProvider: any AudioDeviceProviding,
        makeStream: (@MainActor (AudioDeviceID, String) -> any KeepAliveStreaming)? = nil,
        isAlive: ((AudioDeviceID) -> Bool)? = nil,
        hogModeOwner: ((AudioDeviceID) -> pid_t)? = nil
    ) {
        self.settingsManager = settingsManager
        self.deviceProvider = deviceProvider
        self.makeStream = makeStream ?? { KeepAliveStream(deviceID: $0, uid: $1) }
        self.isAlive = isAlive ?? { $0.isDeviceAlive() }
        self.hogModeOwner = hogModeOwner ?? { $0.readHogModeOwner() }
    }

    /// Starts supervision: the watchdog, sleep/wake handling and device-list observation.
    func start() {
        guard watchdog == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWillSleep() }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDidWake() }
        })
        // Safety net: should a wake notification ever be missed, the screens coming back on
        // also ends the sleep state, so the streams cannot stay parked.
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleScreensDidWake() }
        })
        observeDevices()
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.check()
                try? await Task.sleep(for: Self.watchdogInterval)
            }
        }
    }

    func isEnabled(for deviceUID: String) -> Bool {
        settingsManager.isKeepAliveEnabled(for: deviceUID)
    }

    func setEnabled(_ enabled: Bool, for deviceUID: String) {
        settingsManager.setKeepAliveEnabled(enabled, for: deviceUID)
        if enabled {
            // A fresh request deserves an immediate attempt, not the backoff of an old failure
            failures[deviceUID] = nil
            nextAttempt[deviceUID] = nil
        }
        check()
    }

    func status(for deviceUID: String) -> Status? {
        statuses[deviceUID]
    }

    // MARK: Supervision

    /// One supervision pass: reconcile the streams with the enabled, connected devices, and
    /// rebuild those whose IO stopped. Called by the watchdog, and on every relevant event.
    func check(now: ContinuousClock.Instant = .now) {
        guard !isSleeping else { return }
        let enabled = settingsManager.keepAliveDeviceUIDs
        let present = Dictionary(
            deviceProvider.outputDevices.map { ($0.uid, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )

        // Streams that must go: turned off, disconnected, or the device came back with a new ID
        for (uid, stream) in streams {
            let currentID = present[uid]
            if !enabled.contains(uid) || currentID == nil || currentID != stream.deviceID || !isAlive(stream.deviceID) {
                stopStream(uid)
            }
        }
        for uid in statuses.keys where !enabled.contains(uid) || present[uid] == nil {
            statuses[uid] = nil
            failures[uid] = nil
            nextAttempt[uid] = nil
        }

        for uid in enabled {
            guard let deviceID = present[uid] else { continue }
            if let stream = streams[uid] {
                checkHeartbeat(uid, stream: stream, now: now)
            } else {
                attemptStart(uid, deviceID: deviceID, now: now)
            }
        }
    }

    private func checkHeartbeat(_ uid: String, stream: any KeepAliveStreaming, now: ContinuousClock.Instant) {
        if let last = lastHeartbeat[uid], now - last < Self.minimumHeartbeatSpacing { return }
        lastHeartbeat[uid] = now
        let cycles = stream.renderedCycles
        defer { lastCycles[uid] = cycles }
        guard let previous = lastCycles[uid] else { return }
        if cycles != previous {
            stalledChecks[uid] = 0
            if statuses[uid] != .running {
                statuses[uid] = .running
                failures[uid] = nil
            }
            return
        }
        let stalled = (stalledChecks[uid] ?? 0) + 1
        stalledChecks[uid] = stalled
        if stalled >= Self.stallChecksBeforeRestart {
            // Rebuilt by the next passes; a stream that keeps stalling backs off like a failed start
            logger.warning("Keep-alive on \(uid, privacy: .public) stopped rendering; rebuilding it")
            stopStream(uid)
            statuses[uid] = .starting
            scheduleRetry(uid, now: now)
        }
    }

    private func attemptStart(_ uid: String, deviceID: AudioDeviceID, now: ContinuousClock.Instant) {
        if let next = nextAttempt[uid], now < next { return }
        guard isAlive(deviceID) else { return }

        let owner = hogModeOwner(deviceID)
        if owner != -1 && owner != getpid() {
            // No backoff: reading the owner is cheap, and the stream must come back as soon as
            // the other app lets go of the device
            if statuses[uid] != .blockedByHogMode(owner) {
                logger.info("Keep-alive on \(uid, privacy: .public) waits: device in exclusive use by pid \(owner)")
                statuses[uid] = .blockedByHogMode(owner)
            }
            return
        }

        let stream = makeStream(deviceID, uid)
        statuses[uid] = .starting
        do {
            try stream.start()
            streams[uid] = stream
            lastCycles[uid] = nil
            lastHeartbeat[uid] = nil
            stalledChecks[uid] = 0
            nextAttempt[uid] = nil
        } catch {
            let code: OSStatus
            switch error as? KeepAliveError {
            case .createIOProcFailed(let err), .startFailed(let err): code = err
            case nil: code = -1
            }
            logger.error("Keep-alive could not start on \(uid, privacy: .public): \(code)")
            statuses[uid] = .failed(code)
            scheduleRetry(uid, now: now)
        }
    }

    private func scheduleRetry(_ uid: String, now: ContinuousClock.Instant) {
        let count = (failures[uid] ?? 0) + 1
        failures[uid] = count
        // 1, 2, 4, 8, 16, then 30 s
        let delay = count > 5 ? 30 : 1 << (count - 1)
        nextAttempt[uid] = now.advanced(by: .seconds(delay))
    }

    private func stopStream(_ uid: String) {
        streams[uid]?.stop()
        streams[uid] = nil
        lastCycles[uid] = nil
        lastHeartbeat[uid] = nil
        stalledChecks[uid] = nil
    }

    // MARK: Events

    func handleWillSleep() {
        isSleeping = true
        for uid in Array(streams.keys) {
            stopStream(uid)
            if statuses[uid] != nil { statuses[uid] = .starting }
        }
    }

    func handleDidWake() {
        isSleeping = false
        failures.removeAll()
        nextAttempt.removeAll()
        check()
    }

    func handleScreensDidWake() {
        guard isSleeping else { return }
        logger.warning("Screens woke while keep-alive still considered the system asleep; resuming")
        handleDidWake()
    }

    private func observeDevices() {
        withObservationTracking {
            _ = deviceProvider.outputDevices
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.check()
                self.observeDevices()
            }
        }
    }
}
