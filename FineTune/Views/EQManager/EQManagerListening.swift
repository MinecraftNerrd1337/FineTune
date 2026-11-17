// FineTune/Views/EQManager/EQManagerListening.swift
import Foundation

/// The output device the EQ Manager listens on, and what that device plays.
///
/// While a device is chosen, it plays the preset shown in the EQ Manager, unsaved changes
/// included, instead of its stored AutoEQ (`AudioEngine.previewAutoEQ`). Nothing is stored:
/// once the device is no longer listened on, or the window closes, it plays its own AutoEQ
/// again. "Use on" makes the shown preset its stored one.
@Observable
@MainActor
final class EQManagerListening {

    /// What the listened device plays, to compare by ear.
    enum Source: String, CaseIterable, Identifiable {
        /// The preset shown, with its unsaved changes.
        case shown
        /// The preset shown as saved, without its unsaved changes.
        case saved
        /// The device's own AutoEQ, as it plays without the EQ Manager.
        case inUse
        /// The shown preset with its correction off: preamp only, at the same level.
        case off

        var id: Self { self }
    }

    /// What the device is given.
    enum Target: Equatable {
        /// Its own AutoEQ.
        case stored
        /// This profile (nil: no correction).
        case profile(AutoEQProfile?)
    }

    var deviceUID: String?
    var source: Source = .shown
    /// Raised by `open(on:)`, so the window shows the preset that device uses.
    private(set) var openRequest = 0

    /// Updates while a band is dragged are sent at most this often: a FIR engine designs its
    /// filter on each one.
    private static let interval: Duration = .milliseconds(50)

    @ObservationIgnored private var appliedUID: String?
    @ObservationIgnored private var latest: Target = .stored
    @ObservationIgnored private var lastSend = ContinuousClock.now - .seconds(1)
    @ObservationIgnored private var pendingSend: Task<Void, Never>?

    /// Listen on a device and show its preset (the EQ Manager opened from its AutoEQ menu).
    func open(on deviceUID: String) {
        self.deviceUID = deviceUID
        source = .shown
        openRequest += 1
    }

    /// Gives the listened device `target`; the device listened on before goes back to its own
    /// AutoEQ.
    func update(_ target: Target, engine: AudioEngine) {
        latest = target
        if let old = appliedUID, old != deviceUID {
            engine.endAutoEQPreview(on: old)
            appliedUID = nil
        }
        guard deviceUID != nil else {
            pendingSend?.cancel()
            pendingSend = nil
            return
        }
        let wait = Self.interval - (ContinuousClock.now - lastSend)
        if wait <= .zero {
            send(engine)
        } else if pendingSend == nil {
            pendingSend = Task { @MainActor [weak self] in
                try? await Task.sleep(for: wait)
                guard let self, !Task.isCancelled else { return }
                self.pendingSend = nil
                self.send(engine)
            }
        }
    }

    /// Stop listening: the device plays its own AutoEQ again.
    func stop(engine: AudioEngine) {
        deviceUID = nil
        update(.stored, engine: engine)
    }

    private func send(_ engine: AudioEngine) {
        guard let uid = deviceUID else { return }
        lastSend = .now
        appliedUID = uid
        switch latest {
        case .stored: engine.endAutoEQPreview(on: uid)
        case .profile(let profile): engine.previewAutoEQ(profile, on: uid)
        }
    }
}
