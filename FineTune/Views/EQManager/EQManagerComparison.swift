// FineTune/Views/EQManager/EQManagerComparison.swift
import Foundation

/// What the devices that use the preset shown play, to compare versions by ear: the preset as
/// saved, its unsaved edits, or another preset it is compared with, as saved or with its own
/// edits. Nothing is stored: a version other than the saved one goes to the devices through
/// `AudioEngine.previewAutoEQ`, and once the window closes they play their own AutoEQ again.
///
/// The compared preset gets an extra gain (`AutoEQProfile.comparisonGainDB`, which the Preamp
/// switch does not bypass), so both play at the same perceived level: it follows the level
/// match (`matchingTrimDB`) until set by hand (`manualTrimDB`). The match is worked out from
/// what each device plays: its Correction switch, the Preamp switch, the preamps and the curves
/// as they are now.
@Observable
@MainActor
final class EQManagerComparison {

    enum Version: String, CaseIterable, Identifiable {
        /// The preset shown, as saved: the devices play their own AutoEQ.
        case saved
        /// The preset shown, with its unsaved changes.
        case edited
        /// The preset it is compared with, as saved.
        case compared
        /// The compared preset with its unsaved changes.
        case comparedEdited

        var id: Self { self }
    }

    /// One of the two presets compared: the preset shown in the top bar, or the one compared
    /// with it.
    enum Side {
        case base, compared
    }

    /// The preset the window shows and edits while comparing, whatever is heard.
    var displayed: Side = .base

    /// The version chosen. It may not be available any more (editing ended): see `current(in:)`.
    private(set) var version: Version = .edited
    /// The version heard before, which ⌘B goes back to.
    private(set) var previous: Version?

    /// The preset compared with the one shown, with its unsaved edits when it was edited before
    /// trading places with the preset shown (`swap`). The library may hold a newer version of it
    /// when it is not edited.
    private(set) var comparedEditor: EQManagerEditor?
    /// The extra gain of the compared preset set by hand, in dB. Nil: it follows the level match.
    var manualTrimDB: Double?

    /// Range of the extra gain.
    static let trimRange: ClosedRange<Double> = -24...24

    /// Updates while a band is dragged are sent at most this often: a FIR engine designs its
    /// filter on each one.
    private static let interval: Duration = .milliseconds(50)

    /// What each device plays instead of its own AutoEQ, as last asked for.
    @ObservationIgnored private var latest: [String: AutoEQProfile] = [:]
    /// What each device was last given.
    @ObservationIgnored private var sent: [String: AutoEQProfile] = [:]
    /// The window is closed: nothing is played until it shows again.
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private var lastSend = ContinuousClock.now - .seconds(1)
    @ObservationIgnored private var pendingSend: Task<Void, Never>?

    // MARK: - Versions

    /// The versions that can be heard: the saved preset, its edits while editing, and while
    /// comparing the compared preset, with its edits while it is edited.
    static func versions(isEditing: Bool, isComparing: Bool, comparedIsEditing: Bool = false) -> [Version] {
        var versions: [Version] = [.saved]
        if isEditing { versions.append(.edited) }
        if isComparing {
            versions.append(.compared)
            if comparedIsEditing { versions.append(.comparedEdited) }
        }
        return versions
    }

    /// The version heard among `available`: the one chosen, or when it is gone, the same preset
    /// as saved, or the preset shown (its edits if any).
    func current(in available: [Version]) -> Version {
        if available.contains(version) { return version }
        if version == .comparedEdited, available.contains(.compared) { return .compared }
        return available.contains(.edited) ? .edited : .saved
    }

    func select(_ newVersion: Version, in available: [Version]) {
        let now = current(in: available)
        guard newVersion != now, available.contains(newVersion) else { return }
        previous = now
        version = newVersion
    }

    /// Goes back to the version heard before (⌘B), or to the next one when that is gone.
    func toggle(in available: [Version]) {
        let now = current(in: available)
        if let previous, previous != now, available.contains(previous) {
            select(previous, in: available)
        } else if let index = available.firstIndex(of: now) {
            select(available[(index + 1) % available.count], in: available)
        }
    }

    /// One of the presets starts being edited: hearing it, as saved, goes on with its edits.
    /// Hearing the other preset goes on.
    func beginEditing(_ side: Side = .base) {
        switch side {
        case .base:
            guard version == .saved || version == .edited else { return }
            if version == .saved { previous = .saved }
            version = .edited
        case .compared:
            guard version == .compared else { return }
            previous = .compared
            version = .comparedEdited
        }
    }

    // MARK: - Compared Preset

    /// Whether the compared preset has edits not saved yet: it cannot be dropped then.
    var comparedHasChanges: Bool { comparedEditor?.hasChanges == true }

    /// Whether the compared preset is edited: its edits can be heard.
    var comparedIsEditing: Bool { comparedEditor?.isEditing == true }

    /// Starts comparing the preset shown with `preset`, still hearing the preset shown (with its
    /// edits while editing): ⌘B switches to `preset`.
    func compare(with preset: AutoEQProfile, isEditing: Bool) {
        comparedEditor = EQManagerEditor(profile: preset)
        manualTrimDB = nil
        displayed = .base
        version = isEditing ? .edited : .saved
        previous = .compared
    }

    /// The compared preset was saved as a new preset: it is compared from now on.
    func replaceCompared(with editor: EQManagerEditor) {
        comparedEditor = editor
    }

    func stopComparing() {
        comparedEditor = nil
        manualTrimDB = nil
        displayed = .base
        if version == .compared || version == .comparedEdited { version = .saved }
        if previous == .compared || previous == .comparedEdited { previous = nil }
    }

    /// The level a profile, as handed to the processor (`AudioEngine.activeAutoEQProfile`, so
    /// following a device's Correction switch), plays at, in dB: its perceived level change
    /// (`AutoEQResponse.perceivedLevelChangeDB`, 0 without a curve), plus its preamp and level
    /// match when the Preamp switch is on.
    static func playedLevelDB(_ active: AutoEQProfile, preampOn: Bool) -> Double {
        let curve = AutoEQResponse.perceivedLevelChangeDB(active) ?? 0
        return curve + (preampOn ? Double(active.preampDB + active.levelMatchDB) : 0)
    }

    /// The extra gain, in dB, that gives `compared` the level `reference` plays at, both as
    /// handed to the processor (`playedLevelDB`), to 0.1 dB.
    static func matchingTrimDB(reference: AutoEQProfile, compared: AutoEQProfile, preampOn: Bool = true) -> Double {
        let difference = playedLevelDB(reference, preampOn: preampOn) - playedLevelDB(compared, preampOn: preampOn)
        let trim = (difference * 10).rounded() / 10
        return min(max(trim, trimRange.lowerBound), trimRange.upperBound)
    }

    // MARK: - Playback

    /// Makes each device in `profiles` play its profile, and every other device it was given
    /// one play its own AutoEQ again.
    func update(_ profiles: [String: AutoEQProfile], engine: AudioEngine) {
        latest = profiles
        guard !isSuspended else { return }
        // Going back to the saved preset is never held back
        let wait = profiles.isEmpty ? .zero : Self.interval - (ContinuousClock.now - lastSend)
        if wait <= .zero {
            pendingSend?.cancel()
            pendingSend = nil
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

    /// The window closed: every device plays its own AutoEQ.
    func suspend(engine: AudioEngine) {
        isSuspended = true
        pendingSend?.cancel()
        pendingSend = nil
        for uid in sent.keys { engine.endAutoEQPreview(on: uid) }
        sent = [:]
    }

    /// The window shows again: the devices play what they played before it closed.
    func resume(engine: AudioEngine) {
        guard isSuspended else { return }
        isSuspended = false
        send(engine)
    }

    private func send(_ engine: AudioEngine) {
        lastSend = .now
        for uid in sent.keys where latest[uid] == nil {
            engine.endAutoEQPreview(on: uid)
        }
        for (uid, profile) in latest where sent[uid] != profile {
            engine.previewAutoEQ(profile, on: uid)
        }
        sent = latest
    }
}
