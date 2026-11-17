// FineTune/Audio/Engine/StartGuard.swift
import AppKit
import AudioToolbox
import Foundation
import os

/// Keeps an app silent from its first sample until FineTune's tap carries it.
///
/// FineTune taps an app once it plays, and that takes a moment: Core Audio reports the start,
/// the process list is read again, then the tap and its aggregate are created and started.
/// Until then the app plays straight to the output, without FineTune's volume, at the device's
/// hardware level. The same happens to every app when all taps are rebuilt (switching
/// "Mix Apps per Device").
///
/// The guard is one global tap, muted while tapped, of every process except those excluded:
/// FineTune itself, the apps whose own tap already carries their audio, and the processes
/// FineTune leaves alone (system daemons, ignored apps, apps on a call). A new process is
/// covered as soon as it exists. The guard's aggregate runs all the time and plays nothing,
/// so what it holds is silent until FineTune excludes it. That aggregate has no device: it
/// runs on its own clock, plays nothing and keeps no output device busy.
///
/// Only the exclusion list ever changes (`kAudioTapPropertyDescription`, same UUID, same mute
/// behaviour). Measured with `StartGuardSpike` on a MacBook Air (PRO X 2 LIGHTSPEED, 48 kHz):
/// no gap and no sample-time jump, in the guard or in an app playing through its own tap.
/// An app the guard takes back is held about 30 ms later; one it lets go plays through its
/// own tap only, about 20 to 30 ms later. Same results with the device-less aggregate.
@MainActor
final class StartGuard {

    /// An app held while it plays, with no tap carrying it after this long, is let go: an app
    /// must never stay silent because FineTune could not tap it.
    nonisolated static let failSafeSeconds = 2.0
    /// Wait between taking every app back under the guard and destroying their taps: the
    /// spike measured about 30 ms before the guard holds an app again.
    nonisolated static let holdDelay: Duration = .milliseconds(100)

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "StartGuard")

    private var tapID: AudioObjectID = .unknown
    private var tapUUID = UUID()
    private var aggregateID: AudioObjectID = .unknown
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "FineTune.StartGuard", qos: .userInitiated)
    /// The exclusion list last given to the tap.
    private var written: [AudioObjectID] = []
    private var ownProcess: AudioObjectID = .unknown
    /// After a failure, the aggregate is not tried again before this date.
    private var retryAfter = Date.distantPast
    /// One log line per stop of the aggregate, not one per check.
    private var restartLogged = false
    /// Kept for the app's lifetime, like `DeviceKeepAlive`'s.
    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didWake() }
            })
        }
    }

    var isRunning: Bool { tapID.isValid && aggregateID.isValid }

    /// Holds `held` and lets every other process go. Starts the guard if needed, and rebuilds
    /// whatever no longer works: a tap or aggregate that Core Audio dropped (a restart of
    /// coreaudiod), and starts the aggregate again if Core Audio stopped it (sleep).
    ///
    /// The aggregate's IO itself is not watched: with no device, its IO pauses while nothing
    /// is captured, which is not a failure. Rebuilding it then only let held apps go.
    func update(held: Set<AudioObjectID>, allProcesses: [AudioObjectID]) {
        if tapID.isValid && tapID.readTapDescription() == nil {
            // Core Audio restarted: its process objects changed too, FineTune's included
            logger.warning("Start guard tap lost; rebuilding the guard")
            destroyAggregate()
            tapID = .unknown
            ownProcess = .unknown
            retryAfter = .distantPast
        }

        if !ownProcess.isValid { ownProcess = Self.processObject(for: getpid()) }
        let exclusions = StartGuardPolicy.exclusions(allProcesses: allProcesses, own: ownProcess, held: held)
        if !tapID.isValid {
            guard createTap(excluding: exclusions) else { return }
        } else if exclusions != written {
            setExclusions(exclusions)
        }

        if aggregateID.isValid {
            if !aggregateID.isDeviceAlive() {
                logger.warning("Start guard aggregate lost; rebuilding it")
                destroyAggregate()
            } else if !isAggregateStarted {
                // Started again in place: same aggregate, same tap, nothing rebuilt
                let err = AudioDeviceStart(aggregateID, procID)
                if err != noErr {
                    logger.warning("Start guard aggregate stopped and would not start (\(err)); rebuilding it")
                    destroyAggregate()
                } else if !restartLogged {
                    logger.info("Start guard aggregate was stopped; started it again")
                    restartLogged = true
                }
            } else {
                restartLogged = false
            }
        }
        if !aggregateID.isValid && Date() >= retryAfter {
            startAggregate()
        }

        // FineTune's own process object can appear only once it runs IO: exclude it at once,
        // or the guard would mute FineTune's own output
        if !ownProcess.isValid {
            ownProcess = Self.processObject(for: getpid())
            if ownProcess.isValid {
                setExclusions(StartGuardPolicy.exclusions(allProcesses: allProcesses, own: ownProcess, held: held))
            }
        }
    }

    /// Stops the guard: every app it held plays directly again.
    func invalidate() {
        destroyAggregate()
        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
        written = []
        retryAfter = .distantPast
        logger.info("Start guard stopped")
    }

    // MARK: - Watchdog

    /// Whether this process's IO is started on the aggregate (`AudioDeviceStart`), whether or
    /// not any audio flows through it.
    private var isAggregateStarted: Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &running)
        // Unreadable: leave it to the liveness check rather than restart blindly
        return err != noErr || running != 0
    }

    private func didWake() {
        // Checked again at the next update, with no wait for a failed start's back-off
        retryAfter = .distantPast
    }

    // MARK: - Tap

    private func description(excluding exclusions: [AudioObjectID]) -> CATapDescription {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: exclusions)
        description.uuid = tapUUID
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        return description
    }

    private func createTap(excluding exclusions: [AudioObjectID]) -> Bool {
        tapUUID = UUID()
        var id: AudioObjectID = .unknown
        let err = AudioHardwareCreateProcessTap(description(excluding: exclusions), &id)
        guard err == noErr, id.isValid else {
            logger.error("Could not create the start guard tap: \(err)")
            return false
        }
        tapID = id
        written = exclusions
        return true
    }

    private func setExclusions(_ exclusions: [AudioObjectID]) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var tapDescription = description(excluding: exclusions)
        let err = withUnsafeMutablePointer(to: &tapDescription) { pointer in
            AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), pointer)
        }
        if err == noErr {
            written = exclusions
        } else {
            logger.error("Could not update the start guard's exclusions: \(err)")
        }
    }

    // MARK: - Aggregate

    /// Runs the guard's tap in an aggregate of its own, with no device: nothing is played,
    /// and no output device is kept busy (a Bluetooth headset, a Mac with no speakers).
    /// Measured with `StartGuardSpike --guard-on=none`: it runs on its own clock and mutes.
    private func startAggregate() {
        retryAfter = Date().addingTimeInterval(10)
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "FineTune-Guard",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUUID.uuidString, kAudioSubTapDriftCompensationKey: false] as [String: Any]
            ],
        ]
        var id: AudioObjectID = .unknown
        var err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard err == noErr else {
            logger.error("Could not create the start guard aggregate: \(err)")
            return
        }
        aggregateID = id
        CrashGuard.trackDevice(id)
        guard id.waitUntilReady(timeout: 2.0) else {
            logger.error("Start guard aggregate not ready")
            destroyAggregate()
            return
        }

        // The tap's audio is never read: running the aggregate is what mutes
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, id, queue) { @Sendable _, _, _, outOutputData, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(outOutputData) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
        }
        guard err == noErr else {
            logger.error("Could not create the start guard IO proc: \(err)")
            destroyAggregate()
            return
        }
        err = AudioDeviceStart(id, procID)
        guard err == noErr else {
            logger.error("Could not start the start guard aggregate: \(err)")
            destroyAggregate()
            return
        }
        retryAfter = .distantPast
        logger.info("Start guard running")
    }

    private func destroyAggregate() {
        let id = aggregateID
        guard id.isValid else { return }
        if let procID {
            AudioDeviceStop(id, procID)
            AudioDeviceDestroyIOProcID(id, procID)
        }
        procID = nil
        CrashGuard.untrackDevice(id)
        AudioHardwareDestroyAggregateDevice(id)
        aggregateID = .unknown
    }

    private static func processObject(for pid: pid_t) -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = pid
        var object: AudioObjectID = .unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &object)
        return err == noErr ? object : .unknown
    }
}

// MARK: - Policy

/// Which processes the start guard holds. Pure, so it can be tested without the HAL.
nonisolated enum StartGuardPolicy {

    struct App: Equatable {
        var pid: pid_t
        var processes: [AudioObjectID]
        /// FineTune taps it when it plays: not ignored, not left alone during a call.
        var isEligible: Bool
        var isStreaming: Bool
        /// Host time of the last audible buffer its tap captured; 0 with no tap, or none yet.
        var lastCapturedHostTime: UInt64
    }

    struct State: Equatable {
        /// Apps held whatever their tap does, while their taps are rebuilt.
        var forced: Set<pid_t> = []
        /// Since when each held app has been playing.
        var heldStreamingSince: [pid_t: UInt64] = [:]
        /// Apps let go by the fail-safe, until they stop playing.
        var released: Set<pid_t> = []
    }

    struct Decision: Equatable {
        var held: Set<AudioObjectID>
        var state: State
        /// An app is held while it plays: worth checking again soon.
        var isPending: Bool
        /// Apps the fail-safe let go in this pass.
        var newlyReleased: [pid_t]
    }

    /// An app is held from the moment its processes exist until its tap carries audio, unless
    /// FineTune leaves it alone or it played for `failSafeTicks` without a tap carrying it.
    static func decide(apps: [App], state: State, now: UInt64, failSafeTicks: UInt64) -> Decision {
        var next = State()
        var held = Set<AudioObjectID>()
        var pending = false
        var newlyReleased: [pid_t] = []

        for app in apps where app.isEligible {
            let isForced = state.forced.contains(app.pid)
            if isForced { next.forced.insert(app.pid) }
            if !isForced && app.lastCapturedHostTime != 0 { continue }

            if app.isStreaming {
                if state.released.contains(app.pid) {
                    next.released.insert(app.pid)
                    continue
                }
                let since = state.heldStreamingSince[app.pid] ?? now
                if now >= since, now - since >= failSafeTicks {
                    next.released.insert(app.pid)
                    newlyReleased.append(app.pid)
                    continue
                }
                next.heldStreamingSince[app.pid] = since
                pending = true
            }
            held.formUnion(app.processes)
        }
        return Decision(held: held, state: next, isPending: pending, newlyReleased: newlyReleased)
    }

    /// The guard's exclusion list: every process but the held ones, and FineTune itself.
    static func exclusions(allProcesses: [AudioObjectID], own: AudioObjectID, held: Set<AudioObjectID>) -> [AudioObjectID] {
        var excluded = Set(allProcesses).subtracting(held)
        if own.isValid { excluded.insert(own) }
        return excluded.sorted()
    }

    /// Host-time ticks in `seconds`.
    static func ticks(seconds: Double) -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.numer != 0 else { return UInt64(seconds * 1e9) }
        return UInt64(seconds * 1e9 * Double(info.denom) / Double(info.numer))
    }
}
