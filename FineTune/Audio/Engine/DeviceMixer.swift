// FineTune/Audio/Engine/DeviceMixer.swift
import AudioToolbox
import Foundation
import os

/// The per-DAC mix of one output device: one aggregate for every app that plays on it.
///
/// The aggregate is built once, with a fixed pool of `slotCount` process taps that capture no
/// process. An app arriving takes a free slot: the slot's tap is pointed at the app's processes
/// through `kAudioTapPropertyDescription` (same UUID, same mute behaviour). Leaving points it
/// back at none. Measured with `TapGroupSpike --retarget` on a MacBook Air (AirPods and wired
/// headphones): no gap, no sample-time jump and no added latency in the apps already playing.
/// Two operations would restart the aggregate's IO instead (a 40 to 100 ms gap in every app):
/// changing its tap list while it runs, and changing a tap's mute behaviour. The mixer does
/// neither; an app that finds no free slot plays through its own aggregate, as today.
///
/// The audio callback (`DeviceMixRenderer`) runs each app's chain on its tap's buffer, sums
/// them, and runs the device's AutoEQ and the limiter once on the sum.
///
/// A newly targeted tap delivers the app's audio after a short delay (about 50 ms wired,
/// 200 ms over Bluetooth in the spike), and macOS mutes the app from the start: an app taken
/// over while it plays loses that much. A device switch avoids it by capturing the app on the
/// new device before releasing it on the old one (`MixedTapController`).
@MainActor
final class DeviceMixer {

    /// Taps in the pool. More apps at once on one device play through their own aggregates.
    nonisolated static let slotCount = 8
    /// Largest IO buffer the slots are sized for, in frames.
    nonisolated static let maxFrames = 16_384
    /// Length of the fade of a device switch.
    nonisolated static let fadeSeconds = 0.05

    let deviceUID: String
    private(set) var sampleRate: Double = 48_000
    private let logger: Logger
    private weak var deviceMonitor: AudioDeviceMonitor?

    private let slots: [DeviceMixSlot]
    private var taps: [(id: AudioObjectID, uuid: UUID)] = []
    /// App processes each slot's tap captures (empty = free).
    private var slotProcesses: [[AudioObjectID]]
    private var aggregateID: AudioObjectID = .unknown
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "DeviceMixer", qos: .userInitiated)

    // MARK: RT-shared state (main writes, audio reads)

    private let state: DeviceMixRenderState


    private var autoEQPreampEnabled = false
    private var formatChangeFailSafe: Task<Void, Never>?
    /// Callers of `prepareForOutputFormatChange` not yet answered: the silence lifts when all are.
    private var formatChangeHolds = 0

    init(deviceUID: String, deviceMonitor: AudioDeviceMonitor?) {
        self.deviceUID = deviceUID
        self.deviceMonitor = deviceMonitor
        logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "DeviceMixer")
        slots = (0..<Self.slotCount).map { DeviceMixSlot(index: $0, maxFrames: Self.maxFrames) }
        slotProcesses = Array(repeating: [], count: Self.slotCount)
        state = DeviceMixRenderState()
    }

    var isRunning: Bool { aggregateID.isValid }
    /// Running, and its aggregate still alive (it dies with its device).
    var isAlive: Bool { aggregateID.isValid && aggregateID.isDeviceAlive() }
    var activeSlotCount: Int { slotProcesses.filter { !$0.isEmpty }.count }
    var hasFreeSlot: Bool { slotProcesses.contains { $0.isEmpty } }

    // MARK: - Eligibility

    /// Whether an app on these devices can play through a mixer: one plain stereo device.
    /// The rest keeps its own aggregate: several devices (each needs its own buffer), a user
    /// aggregate (flattened by ProcessTapController), more than two channels (those use a
    /// stream-specific tap), a virtual device.
    static func canMix(deviceUIDs: [String], deviceID: (String) -> AudioDeviceID?) -> Bool {
        guard deviceUIDs.count == 1, let id = deviceID(deviceUIDs[0]) else { return false }
        guard id.aggregateSubDeviceUIDs() == nil, !id.isVirtualDevice() else { return false }
        return id.outputChannelCount() == 2 && id.streamCount(scope: kAudioObjectPropertyScopeOutput) == 1
    }

    // MARK: - Lifecycle

    func start(initialAutoEQ profile: AutoEQProfile?, preampEnabled: Bool) throws {
        guard !isRunning else { return }
        guard let deviceID = audioDeviceID(for: deviceUID) else {
            throw mixerError("Output device \(deviceUID) not found")
        }

        if taps.isEmpty {
            for _ in 0..<Self.slotCount {
                taps.append(try makeTap(processes: []))
            }
        }

        // One device, its clock; sub-tap drift compensation as ProcessTapController sets it
        let isBluetooth = deviceID.isBluetoothDevice()
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "FineTune-Mix",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceClockDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: deviceUID, kAudioSubDeviceDriftCompensationKey: false]
            ],
            kAudioAggregateDeviceTapListKey: taps.map { tap in
                [kAudioSubTapUIDKey: tap.uuid.uuidString, kAudioSubTapDriftCompensationKey: !isBluetooth] as [String: Any]
            },
        ]
        var id: AudioObjectID = .unknown
        var err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard err == noErr else { throw mixerError("Failed to create the mix aggregate: \(err)") }
        aggregateID = id
        CrashGuard.trackDevice(id)
        guard id.waitUntilReady(timeout: 2.0) else {
            destroyAggregate()
            throw mixerError("Mix aggregate not ready within timeout")
        }

        sampleRate = (try? id.readNominalSampleRate()) ?? 48_000
        let rate = Float(sampleRate)
        state.rampCoefficient = 1 - exp(-1 / (rate * 0.030))
        state.gateRampSamples = rate * 0.040
        state.fadeStep = Float(1 / (sampleRate * Self.fadeSeconds))
        let preferred = deviceID.preferredStereoChannelIndices()
        state.preferredLeft = preferred.left
        state.preferredRight = preferred.right

        autoEQPreampEnabled = preampEnabled
        let autoEQ = AutoEQProcessor(sampleRate: sampleRate)
        autoEQ.setPreampEnabled(preampEnabled)
        if let profile { autoEQ.updateProfile(profile) }
        state.autoEQ = autoEQ

        let slots = slots
        let state = state
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, id, queue) { @Sendable _, inInputData, _, outOutputData, _ in
            let now = mach_absolute_time()
            let previous = state.lastRenderHostTime
            state.lastRenderHostTime = now
            let resumed = previous != 0 && DeviceMixer.nanoseconds(from: previous, to: now) > 100_000_000
            DeviceMixRenderer.render(
                inputs: UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData)),
                outputs: UnsafeMutableAudioBufferListPointer(outOutputData),
                slots: slots,
                mix: state.mix,
                maxFrames: DeviceMixer.maxFrames,
                autoEQ: state.autoEQ,
                forceSilence: state.forceSilence,
                preferredLeft: state.preferredLeft,
                preferredRight: state.preferredRight,
                rampCoefficient: state.rampCoefficient,
                gateRampSamples: state.gateRampSamples,
                fadeStep: state.fadeStep,
                resumed: resumed,
                hostTime: now
            )
        }
        guard err == noErr else {
            destroyAggregate()
            throw mixerError("Failed to create the mix IO proc: \(err)")
        }
        disableHardwareInputStreams()

        err = AudioDeviceStart(id, procID)
        guard err == noErr else {
            destroyAggregate()
            throw mixerError("Failed to start the mix aggregate: \(err)")
        }
        logger.info("Mixer started on \(self.deviceUID, privacy: .public) at \(self.sampleRate) Hz with \(Self.slotCount) taps")
    }

    /// Stops the mix and destroys the aggregate and its taps. Every app still in it plays
    /// directly again.
    func invalidate() {
        for slot in slots { slot.deactivate() }
        destroyAggregate()
        for tap in taps where tap.id.isValid {
            AudioHardwareDestroyProcessTap(tap.id)
        }
        taps = []
        slotProcesses = Array(repeating: [], count: Self.slotCount)
        formatChangeFailSafe?.cancel()
        formatChangeFailSafe = nil
        logger.info("Mixer stopped on \(self.deviceUID, privacy: .public)")
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
        state.lastRenderHostTime = 0
        let oldAutoEQ = state.autoEQ
        state.autoEQ = nil
        DeviceMixSlot.retire(oldAutoEQ)
    }

    // MARK: - Slots

    /// Captures `processes` in a free slot. Returns nil when the pool is full or the tap
    /// cannot be pointed at them.
    func acquireSlot(processes: [AudioObjectID], settings: DeviceMixSlot.Settings, fadedIn: Bool) -> DeviceMixSlot? {
        guard isRunning, !processes.isEmpty,
              let index = slotProcesses.firstIndex(where: { $0.isEmpty }) else { return nil }
        let slot = slots[index]
        slot.activate(settings: settings, sampleRate: sampleRate, fadedIn: fadedIn)
        let err = retarget(index, to: processes)
        guard err == noErr else {
            slot.deactivate()
            logger.error("Could not point tap \(index) at the app's processes: \(err)")
            return nil
        }
        slotProcesses[index] = processes
        return slot
    }

    /// Releases a slot: the mix drops it, then its tap stops capturing (the app plays directly).
    func releaseSlot(_ slot: DeviceMixSlot) {
        let index = slot.index
        guard index < slotProcesses.count else { return }
        slot.deactivate()
        if !slotProcesses[index].isEmpty {
            let err = retarget(index, to: [])
            if err != noErr { logger.error("Could not release tap \(index): \(err)") }
        }
        slotProcesses[index] = []
    }

    /// Points a slot's tap at other processes of the same app (a relaunch, a new helper).
    func updateProcesses(of slot: DeviceMixSlot, to processes: [AudioObjectID]) {
        let index = slot.index
        guard index < slotProcesses.count, !slotProcesses[index].isEmpty, !processes.isEmpty,
              processes != slotProcesses[index] else { return }
        if retarget(index, to: processes) == noErr {
            slotProcesses[index] = processes
        }
    }

    /// Processes the slot's tap captures, as the HAL reports them.
    func capturedProcesses(of slot: DeviceMixSlot) -> Set<AudioObjectID> {
        guard slot.index < taps.count, taps[slot.index].id.isValid else { return [] }
        return Set(taps[slot.index].id.readTapDescription()?.processes ?? [])
    }

    var lastRenderHostTime: UInt64 { state.lastRenderHostTime }

    // MARK: - Device settings

    func updateAutoEQProfile(_ profile: AutoEQProfile?) {
        guard let autoEQ = state.autoEQ, autoEQ.currentProfile != profile else { return }
        autoEQ.updateProfile(profile)
    }

    var autoEQProfile: AutoEQProfile? { state.autoEQ?.currentProfile }

    func setAutoEQPreampEnabled(_ enabled: Bool) {
        guard enabled != autoEQPreampEnabled else { return }
        autoEQPreampEnabled = enabled
        state.autoEQ?.setPreampEnabled(enabled)
    }

    // MARK: - Format changes

    /// Silences the mix until `cancelOutputFormatChangePreparation` or a rebuild, or one second.
    func prepareForOutputFormatChange() {
        formatChangeHolds += 1
        state.forceSilence = true
        OSMemoryBarrier()
        formatChangeFailSafe?.cancel()
        formatChangeFailSafe = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(ProcessTapController.formatChangeSilenceFailSafeMs))
            guard !Task.isCancelled, let self else { return }
            self.liftFormatChangeSilence()
            self.logger.warning("[RATE] Format-change silence fail-safe released for the mixer on \(self.deviceUID, privacy: .public)")
        }
    }

    func cancelOutputFormatChangePreparation() {
        formatChangeHolds = max(0, formatChangeHolds - 1)
        if formatChangeHolds == 0 { liftFormatChangeSilence() }
    }

    private func liftFormatChangeSilence() {
        formatChangeHolds = 0
        formatChangeFailSafe?.cancel()
        formatChangeFailSafe = nil
        state.forceSilence = false
        OSMemoryBarrier()
    }

    func hasOutputSampleRateMismatch() -> Bool {
        guard isRunning, let deviceID = audioDeviceID(for: deviceUID),
              let outputRate = try? deviceID.readNominalSampleRate(), outputRate > 0,
              let aggregateRate = try? aggregateID.readNominalSampleRate(), aggregateRate > 0 else { return false }
        return abs(outputRate - aggregateRate) > 0.5
    }

    /// Rebuilds the aggregate at the device's new rate (in-place re-rating silences a running
    /// IO proc, see ProcessTapController). The taps and their apps stay; each slot's chain is
    /// rebuilt for the new rate. Several apps of the device ask in turn: only the first rebuilds.
    func recreateForOutputRateChange() throws {
        guard isRunning else { return }
        guard hasOutputSampleRateMismatch() else {
            liftFormatChangeSilence()
            return
        }
        state.forceSilence = true
        OSMemoryBarrier()
        defer { liftFormatChangeSilence() }

        let profile = state.autoEQ?.currentProfile
        destroyAggregate()
        try start(initialAutoEQ: profile, preampEnabled: autoEQPreampEnabled)
        for slot in slots where slot.isActive {
            slot.rebuild(sampleRate: sampleRate)
        }
        logger.info("[RATE] Mixer on \(self.deviceUID, privacy: .public) rebuilt at \(self.sampleRate) Hz")
    }

    // MARK: - Helpers

    private func makeTap(processes: [AudioObjectID], uuid: UUID = UUID()) throws -> (id: AudioObjectID, uuid: UUID) {
        let description = Self.tapDescription(processes: processes, uuid: uuid)
        var tapID: AudioObjectID = .unknown
        let err = AudioHardwareCreateProcessTap(description, &tapID)
        guard err == noErr else { throw mixerError("Failed to create a pool tap: \(err)") }
        return (tapID, uuid)
    }

    /// Every pool tap has this shape; only `processes` ever changes (a change of mute
    /// behaviour restarts the aggregate's IO).
    private static func tapDescription(processes: [AudioObjectID], uuid: UUID) -> CATapDescription {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = uuid
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        return description
    }

    private func retarget(_ index: Int, to processes: [AudioObjectID]) -> OSStatus {
        guard index < taps.count else { return OSStatus(kAudioHardwareBadObjectError) }
        let tap = taps[index]
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var description = Self.tapDescription(processes: processes, uuid: tap.uuid)
        return withUnsafeMutablePointer(to: &description) { pointer in
            AudioObjectSetPropertyData(tap.id, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), pointer)
        }
    }

    /// Keeps the device's hardware inputs off (only the trailing tap streams are read), so a
    /// duplex interface does not count as microphone use. See ProcessTapController.
    private func disableHardwareInputStreams() {
        guard let procID else { return }
        let inputCount = aggregateID.streamCount(scope: kAudioObjectPropertyScopeInput)
        guard let flags = ProcessTapController.inputStreamUsageFlags(inputCount: inputCount, outputCount: taps.count) else { return }

        let headerSize = MemoryLayout<UnsafeMutableRawPointer>.size + MemoryLayout<UInt32>.size
        let totalSize = headerSize + inputCount * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: totalSize, alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment)
        defer { raw.deallocate() }
        raw.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(inputCount), toByteOffset: MemoryLayout<UnsafeMutableRawPointer>.size, as: UInt32.self)
        for (i, isUsed) in flags.enumerated() {
            raw.storeBytes(of: isUsed, toByteOffset: headerSize + i * MemoryLayout<UInt32>.size, as: UInt32.self)
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIOProcStreamUsage,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let err = AudioObjectSetPropertyData(aggregateID, &address, 0, nil, UInt32(totalSize), raw)
        if err != noErr {
            logger.warning("Could not disable hardware input streams (\(err)); microphone permission may be requested")
        }
    }

    private func audioDeviceID(for uid: String) -> AudioDeviceID? {
        Self.audioDeviceID(for: uid, monitor: deviceMonitor)
    }

    static func audioDeviceID(for uid: String, monitor: AudioDeviceMonitor?) -> AudioDeviceID? {
        if let monitored = monitor?.device(for: uid)?.id { return monitored }
        guard let ids = try? AudioObjectID.readDeviceList() else { return nil }
        return ids.first { (try? $0.readDeviceUID()) == uid }
    }

    private func mixerError(_ message: String) -> NSError {
        logger.error("\(message, privacy: .public)")
        return NSError(domain: "DeviceMixer", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    nonisolated private static let hostTimeScale: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info.denom == 0 ? 1 : Double(info.numer) / Double(info.denom)
    }()

    nonisolated static func nanoseconds(from a: UInt64, to b: UInt64) -> Double {
        Double(b &- a) * hostTimeScale
    }
}

/// What the audio callback reads, kept off the actor so the IO block captures no actor state.
final class DeviceMixRenderState: @unchecked Sendable {
    nonisolated(unsafe) var autoEQ: AutoEQProcessor?
    nonisolated(unsafe) var forceSilence = false
    nonisolated(unsafe) var preferredLeft = 0
    nonisolated(unsafe) var preferredRight = 1
    nonisolated(unsafe) var rampCoefficient: Float = 0.0007
    nonisolated(unsafe) var gateRampSamples: Float = 1920
    nonisolated(unsafe) var fadeStep: Float = 1.0 / 2400
    /// Audio thread: host time of the last callback (0 = none yet).
    nonisolated(unsafe) var lastRenderHostTime: UInt64 = 0
    let mix: UnsafeMutablePointer<Float>

    init() {
        mix = .allocate(capacity: DeviceMixer.maxFrames * 2)
        mix.initialize(repeating: 0, count: DeviceMixer.maxFrames * 2)
    }

    deinit { mix.deallocate() }
}
