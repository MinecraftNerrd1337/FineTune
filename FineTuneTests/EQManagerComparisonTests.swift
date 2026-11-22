// FineTuneTests/EQManagerComparisonTests.swift
//
// What the EQ Manager lets the devices hear (EQManagerComparison): the versions offered, ⌘B
// going back to the version heard before, and the extra gain that matches the compared
// preset's level to the preset shown.

import Testing
@testable import FineTune

private func profile(_ id: String, gainDB: Float = 0, preampDB: Float = 0) -> AutoEQProfile {
    let filters = gainDB == 0 ? [] : [AutoEQFilter(type: .peaking, frequency: 1000, gainDB: gainDB, q: 1)]
    return AutoEQProfile(id: id, name: id, source: .created, preampDB: preampDB, filters: filters)
}

@Suite("EQ Manager comparison")
struct EQManagerComparisonTests {

    @Test("The edits and the compared preset are offered only while editing and comparing")
    func versions() {
        #expect(EQManagerComparison.versions(isEditing: false, isComparing: false) == [.saved])
        #expect(EQManagerComparison.versions(isEditing: true, isComparing: false) == [.saved, .edited])
        #expect(EQManagerComparison.versions(isEditing: false, isComparing: true) == [.saved, .compared])
        #expect(EQManagerComparison.versions(isEditing: true, isComparing: true) == [.saved, .edited, .compared])
    }

    @Test("Comparing starts on the preset shown, and ⌘B goes to the compared one and back")
    func compareThenToggle() {
        let comparison = EQManagerComparison()
        let all = EQManagerComparison.versions(isEditing: true, isComparing: true)
        comparison.compare(with: profile("b"), isEditing: true)
        #expect(comparison.current(in: all) == .edited)
        comparison.toggle(in: all)
        #expect(comparison.current(in: all) == .compared)
        comparison.toggle(in: all)
        #expect(comparison.current(in: all) == .edited)
    }

    @Test("⌘B goes back to the version heard just before, among three")
    func toggleGoesBack() {
        let comparison = EQManagerComparison()
        let all = EQManagerComparison.versions(isEditing: true, isComparing: true)
        comparison.compare(with: profile("b"), isEditing: true)
        comparison.select(.saved, in: all)
        comparison.toggle(in: all)
        #expect(comparison.current(in: all) == .edited)
        comparison.toggle(in: all)
        #expect(comparison.current(in: all) == .saved)
    }

    @Test("Once editing ends, the edits are heard as the saved preset")
    func editingEnds() {
        let comparison = EQManagerComparison()
        comparison.beginEditing()
        let notEditing = EQManagerComparison.versions(isEditing: false, isComparing: true)
        #expect(comparison.current(in: notEditing) == .saved)
        comparison.toggle(in: notEditing)
        #expect(comparison.current(in: notEditing) == .compared)
    }

    @Test("Starting an edit hears the edits of the preset heard, and ⌘B goes back to it as saved")
    func beginEditing() {
        let comparison = EQManagerComparison()
        comparison.compare(with: profile("b"), isEditing: false)
        let notEditing = EQManagerComparison.versions(isEditing: false, isComparing: true)
        #expect(comparison.current(in: notEditing) == .saved)
        comparison.beginEditing(.base)
        let editing = EQManagerComparison.versions(isEditing: true, isComparing: true)
        #expect(comparison.current(in: editing) == .edited)
        comparison.toggle(in: editing)
        #expect(comparison.current(in: editing) == .saved)
    }

    @Test("Editing one preset while hearing the other keeps hearing the other")
    func editingDoesNotChangeWhatIsHeard() {
        let comparison = EQManagerComparison()
        comparison.compare(with: profile("b"), isEditing: false)
        let notEditing = EQManagerComparison.versions(isEditing: false, isComparing: true)
        comparison.select(.compared, in: notEditing)
        comparison.beginEditing(.base)
        #expect(comparison.current(in: EQManagerComparison.versions(isEditing: true, isComparing: true)) == .compared)

        let other = EQManagerComparison()
        other.compare(with: profile("b"), isEditing: false)
        other.beginEditing(.compared)
        let comparedEditing = EQManagerComparison.versions(isEditing: false, isComparing: true, comparedIsEditing: true)
        #expect(other.current(in: comparedEditing) == .saved)
    }

    @Test("The compared preset can be edited alone, and each version of both can be heard")
    func bothEdited() throws {
        let comparison = EQManagerComparison()
        comparison.compare(with: profile("b"), isEditing: false)
        let b = try #require(comparison.comparedEditor)
        let start = EQManagerComparison.versions(isEditing: false, isComparing: true)
        comparison.select(.compared, in: start)
        // Only the compared preset is edited: hearing it goes on with its edits
        b.beginEditing()
        comparison.beginEditing(.compared)
        b.apply { $0.preampDB = -5 }
        #expect(comparison.comparedIsEditing)
        #expect(comparison.comparedHasChanges)
        let bEditing = EQManagerComparison.versions(isEditing: false, isComparing: true, comparedIsEditing: true)
        #expect(bEditing == [.saved, .compared, .comparedEdited])
        #expect(comparison.current(in: bEditing) == .comparedEdited)
        comparison.toggle(in: bEditing)
        #expect(comparison.current(in: bEditing) == .compared)
        // Then the preset of the top bar too: four versions
        let four = EQManagerComparison.versions(isEditing: true, isComparing: true, comparedIsEditing: true)
        #expect(four == [.saved, .edited, .compared, .comparedEdited])
        comparison.select(.saved, in: four)
        comparison.beginEditing(.base)
        #expect(comparison.current(in: four) == .edited)
    }

    @Test("Comparing shows the preset of the top bar; stopping shows it again")
    func displayed() {
        let comparison = EQManagerComparison()
        comparison.compare(with: profile("b"), isEditing: false)
        #expect(comparison.displayed == .base)
        comparison.displayed = .compared
        comparison.compare(with: profile("c"), isEditing: false)
        #expect(comparison.displayed == .base)
        comparison.displayed = .compared
        comparison.stopComparing()
        #expect(comparison.displayed == .base)
    }

    @Test("Once the compared preset's edits are gone, it is heard as saved")
    func comparedEditsGone() {
        let comparison = EQManagerComparison()
        let four = EQManagerComparison.versions(isEditing: true, isComparing: true, comparedIsEditing: true)
        comparison.compare(with: profile("b"), isEditing: true)
        comparison.select(.comparedEdited, in: four)
        let three = EQManagerComparison.versions(isEditing: true, isComparing: true)
        #expect(comparison.current(in: three) == .compared)
    }

    @Test("Stopping hears the preset shown and forgets the gain set by hand")
    func stop() {
        let comparison = EQManagerComparison()
        let all = EQManagerComparison.versions(isEditing: false, isComparing: true)
        comparison.compare(with: profile("b"), isEditing: false)
        comparison.select(.compared, in: all)
        comparison.manualTrimDB = 2
        comparison.stopComparing()
        #expect(comparison.comparedEditor == nil)
        #expect(comparison.manualTrimDB == nil)
        #expect(comparison.current(in: [.saved]) == .saved)
    }

    @Test("Choosing a new preset to compare follows the level match again")
    func newComparisonResetsTrim() {
        let comparison = EQManagerComparison()
        comparison.compare(with: profile("b"), isEditing: false)
        comparison.manualTrimDB = 3
        comparison.compare(with: profile("c"), isEditing: false)
        #expect(comparison.manualTrimDB == nil)
    }

    @Test("Flat presets are matched by their preamps")
    func matchPreamps() {
        let trim = EQManagerComparison.matchingTrimDB(
            reference: profile("a", preampDB: -6), compared: profile("b", preampDB: -2))
        #expect(trim == -4)
    }

    @Test("A boost is matched by a cut, so both sound as loud")
    func matchBoost() {
        let flat = profile("a")
        let boosted = profile("b", gainDB: 6)
        let trim = EQManagerComparison.matchingTrimDB(reference: flat, compared: boosted)
        let boostLevel = AutoEQResponse.perceivedLevelChangeDB(boosted) ?? 0
        #expect(trim < 0)
        #expect(abs(trim + boostLevel) <= 0.05)
        // The other way round, the same gain with the opposite sign
        #expect(EQManagerComparison.matchingTrimDB(reference: boosted, compared: flat) == -trim)
    }

    @Test("With the preamp off, the preamps play no part in the match")
    func matchPreampOff() {
        let trim = EQManagerComparison.matchingTrimDB(
            reference: profile("a", gainDB: 6, preampDB: -6), compared: profile("b", preampDB: -2), preampOn: false)
        let boostLevel = AutoEQResponse.perceivedLevelChangeDB(profile("a", gainDB: 6)) ?? 0
        #expect(abs(trim - boostLevel) <= 0.05)
    }

    @Test("A device with its correction off is matched on what it plays: the preamps and their level match")
    func matchCorrectionOff() {
        let a = profile("a", gainDB: 6, preampDB: -6)
        let b = profile("b", preampDB: -2)
        let on = EQManagerComparison.matchingTrimDB(reference: a, compared: b)
        // With the level match setting on, the correction off keeps each preset's level
        let offMatched = EQManagerComparison.matchingTrimDB(
            reference: AudioEngine.activeAutoEQProfile(a, correctionEnabled: false, levelMatched: true),
            compared: AudioEngine.activeAutoEQProfile(b, correctionEnabled: false, levelMatched: true))
        #expect(abs(offMatched - on) <= 0.1)
        // Without it, only the preamps are left
        let offPlain = EQManagerComparison.matchingTrimDB(
            reference: AudioEngine.activeAutoEQProfile(a, correctionEnabled: false, levelMatched: false),
            compared: AudioEngine.activeAutoEQProfile(b, correctionEnabled: false, levelMatched: false))
        #expect(offPlain == -4)
        // Preamp off and correction off: nothing is played, nothing to match
        let nothing = EQManagerComparison.matchingTrimDB(
            reference: AudioEngine.activeAutoEQProfile(a, correctionEnabled: false, levelMatched: true),
            compared: AudioEngine.activeAutoEQProfile(b, correctionEnabled: false, levelMatched: true),
            preampOn: false)
        #expect(nothing == 0)
    }

    @Test("The gain stays within its range")
    func matchClamped() {
        let trim = EQManagerComparison.matchingTrimDB(
            reference: profile("a", preampDB: 30), compared: profile("b", preampDB: -30))
        #expect(trim == EQManagerComparison.trimRange.upperBound)
    }
}
