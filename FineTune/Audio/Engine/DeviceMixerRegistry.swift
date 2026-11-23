// FineTune/Audio/Engine/DeviceMixerRegistry.swift
import AudioToolbox
import Foundation
import os

/// The per-DAC mixers in use, one per output device, shared by every `MixedTapController`.
///
/// A mixer is created when the first app arrives on its device and stopped a few seconds
/// after the last one leaves, so an app that switches away and back, or relaunches, finds it
/// still running (starting one takes the aggregate's start-up time).
@MainActor
final class DeviceMixerRegistry {

    /// How long an empty mixer stays up.
    static let idleTeardownDelay: Duration = .seconds(5)

    private weak var deviceMonitor: AudioDeviceMonitor?
    private var mixers: [String: DeviceMixer] = [:]
    private var teardownTasks: [String: Task<Void, Never>] = [:]
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "DeviceMixerRegistry")

    init(deviceMonitor: AudioDeviceMonitor?) {
        self.deviceMonitor = deviceMonitor
    }

    /// Whether an app on these devices can go through a mixer.
    func canMix(deviceUIDs: [String]) -> Bool {
        DeviceMixer.canMix(deviceUIDs: deviceUIDs) { uid in
            DeviceMixer.audioDeviceID(for: uid, monitor: self.deviceMonitor)
        }
    }

    /// The running mixer of a device, started if needed.
    func mixer(for deviceUID: String, autoEQ profile: AutoEQProfile?, preampEnabled: Bool) throws -> DeviceMixer {
        teardownTasks.removeValue(forKey: deviceUID)?.cancel()
        if let existing = mixers[deviceUID] {
            if existing.isAlive { return existing }
            // Its device went away and came back: the old aggregate is gone with it
            existing.invalidate()
            mixers.removeValue(forKey: deviceUID)
        }
        let mixer = DeviceMixer(deviceUID: deviceUID, deviceMonitor: deviceMonitor)
        do {
            try mixer.start(initialAutoEQ: profile, preampEnabled: preampEnabled)
        } catch {
            mixer.invalidate()
            mixers.removeValue(forKey: deviceUID)
            throw error
        }
        mixers[deviceUID] = mixer
        return mixer
    }

    /// Called after a slot is released: stops the mixer later if it stays empty.
    func releaseIfIdle(_ deviceUID: String) {
        guard let mixer = mixers[deviceUID], mixer.activeSlotCount == 0 else { return }
        teardownTasks[deviceUID]?.cancel()
        teardownTasks[deviceUID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.idleTeardownDelay)
            guard !Task.isCancelled, let self else { return }
            self.teardownTasks.removeValue(forKey: deviceUID)
            guard let mixer = self.mixers[deviceUID], mixer.activeSlotCount == 0 else { return }
            mixer.invalidate()
            self.mixers.removeValue(forKey: deviceUID)
            self.logger.info("Stopped the idle mixer of \(deviceUID, privacy: .public)")
        }
    }

    /// Stops every mixer at once (engine stop, routing-mode change).
    func invalidateAll() {
        for task in teardownTasks.values { task.cancel() }
        teardownTasks.removeAll()
        for mixer in mixers.values { mixer.invalidate() }
        mixers.removeAll()
    }

    var runningDeviceUIDs: [String] { mixers.filter { $0.value.isRunning }.map(\.key) }
}
