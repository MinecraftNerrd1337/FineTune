// FineTuneTests/AutoEQPresetLibraryTests.swift
//
// The library of the EQ Manager: templates (imported, downloaded, catalog) keep their
// correction, presets are saved in place with their earlier versions kept, and presets edited
// in place by earlier builds are migrated without losing anything.

import Testing
import Foundation
@testable import FineTune

private let fileText = """
Preamp: -6.0 dB
Filter 1: ON PK Fc 100 Hz Gain -2.0 dB Q 1.41
Filter 2: ON HSC Fc 8000 Hz Gain 3.0 dB Q 0.71
"""

private func band(_ frequency: Double, _ gain: Float, _ q: Double = 1, _ type: AutoEQFilter.FilterType = .peaking) -> AutoEQFilter {
    AutoEQFilter(type: type, frequency: frequency, gainDB: gain, q: q)
}

private func makeTempDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("AutoEQPresetLibraryTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A library in a temporary folder: imported files, settings.json and the history.
@MainActor
private struct Library {
    let root: URL
    let settings: SettingsManager
    let history: AutoEQPresetHistoryStore
    let manager: AutoEQProfileManager

    /// - Parameters:
    ///   - files: imported files by profile ID (text, display name).
    ///   - stored: profiles already in settings.json before launch.
    init(
        files: [String: (text: String, name: String)] = [:],
        stored: [AutoEQProfile] = [],
        root: URL = makeTempDirectory(),
        configure: (SettingsManager) -> Void = { _ in }
    ) {
        self.root = root
        let importDir = root.appendingPathComponent("AutoEQ")
        try? FileManager.default.createDirectory(at: importDir, withIntermediateDirectories: true)
        for (id, file) in files {
            try? file.text.write(to: importDir.appendingPathComponent("\(id).txt"), atomically: true, encoding: .utf8)
            try? file.name.write(to: importDir.appendingPathComponent("\(id).name"), atomically: true, encoding: .utf8)
        }
        settings = SettingsManager(directory: root)
        for profile in stored { settings.saveAutoEQUserProfile(profile) }
        configure(settings)
        history = AutoEQPresetHistoryStore(directory: root.appendingPathComponent("History"))
        manager = AutoEQProfileManager(loader: AutoEQProfileLoader(directory: importDir), history: history)
        manager.attachUserProfileStore(settings)
    }

    /// The same folders and settings after a relaunch.
    func relaunched() -> AutoEQProfileManager {
        let manager = AutoEQProfileManager(
            loader: AutoEQProfileLoader(directory: root.appendingPathComponent("AutoEQ")),
            history: AutoEQPresetHistoryStore(directory: root.appendingPathComponent("History"))
        )
        manager.attachUserProfileStore(settings)
        return manager
    }
}

private func fileProfile(id: String, name: String = "HD 600") -> AutoEQProfile {
    AutoEQParser.parse(text: fileText, name: name, source: .imported, id: id)!
}

// MARK: - Model

@Suite("Preset library — model")
struct AutoEQPresetModelTests {

    @Test("Only presets created in the EQ Manager are presets")
    func roles() {
        #expect(AutoEQSource.created.isTemplate == false)
        for source: AutoEQSource in [.imported, .downloaded, .fetched, .bundled] {
            #expect(source.isTemplate)
        }
    }

    @Test("The correction is the kind, bands, curve and preamp, not the name, rate or engine")
    func sameCorrection() {
        let a = AutoEQProfile(id: "a", name: "A", source: .imported, preampDB: -3, filters: [band(100, -2)])
        var b = a
        b.name = "B"
        b.optimizedSampleRate = 96_000
        b.engine = .minimumPhaseFIR
        #expect(a.hasSameCorrection(as: b))
        b.preampDB = -4
        #expect(!a.hasSameCorrection(as: b))
        var c = a
        c.filters[0].q = 2
        #expect(!a.hasSameCorrection(as: c))
        #expect(c.withCorrection(of: a).hasSameCorrection(as: a))
        #expect(c.withCorrection(of: a).id == c.id)
    }

    @Test("The template link is stored, and older settings without it still load")
    func templateIDCoding() throws {
        let preset = AutoEQProfile(id: "p", name: "P", source: .created, preampDB: 0, filters: [band(1000, 2)], templateID: "t")
        let decoded = try JSONDecoder().decode(AutoEQProfile.self, from: JSONEncoder().encode(preset))
        #expect(decoded == preset)
        #expect(decoded.validated().templateID == "t")

        let old = #"{"id":"x","name":"X","source":"created","preampDB":0,"filters":[]}"#
        let legacy = try JSONDecoder().decode(AutoEQProfile.self, from: Data(old.utf8))
        #expect(legacy.templateID == nil)
    }

    @Test("Saving: presets in place, templates in place only for their settings, catalog never")
    func saveKind() {
        let preset = AutoEQProfile(id: "p", name: "P", source: .created, preampDB: 0, filters: [band(100, 1)])
        var presetDraft = preset
        presetDraft.filters[0].gainDB = 5
        #expect(AutoEQProfileManager.saveKind(original: preset, draft: presetDraft) == .updateInPlace)

        for source: AutoEQSource in [.imported, .downloaded] {
            let template = AutoEQProfile(id: "t", name: "T", source: source, preampDB: -2, filters: [band(100, 1)])
            var settingsOnly = template
            settingsOnly.name = "Renamed"
            settingsOnly.optimizedSampleRate = 44_100
            settingsOnly.engine = .matchedBiquad
            #expect(AutoEQProfileManager.saveKind(original: template, draft: settingsOnly) == .updateInPlace)
            var bands = template
            bands.filters.append(band(2000, -1))
            #expect(AutoEQProfileManager.saveKind(original: template, draft: bands) == .createPreset)
            var preamp = template
            preamp.preampDB = -1
            #expect(AutoEQProfileManager.saveKind(original: template, draft: preamp) == .createPreset)
        }

        let catalog = AutoEQProfile(id: "sennheiser-hd-600", name: "HD 600", source: .fetched, preampDB: 0, filters: [])
        var renamed = catalog
        renamed.name = "Mine"
        #expect(AutoEQProfileManager.saveKind(original: catalog, draft: renamed) == .createPreset)
    }

    @Test("Preset settings: confirmation on and 10 versions by default, limit clamped")
    func appSettingsDefaults() throws {
        let defaults = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(defaults.confirmPresetSaves)
        #expect(defaults.presetHistoryLimit == 10)
        let high = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"presetHistoryLimit":500,"confirmPresetSaves":false}"#.utf8))
        #expect(high.presetHistoryLimit == AutoEQPresetHistoryStore.limitRange.upperBound)
        #expect(!high.confirmPresetSaves)
        let low = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"presetHistoryLimit":-3}"#.utf8))
        #expect(low.presetHistoryLimit == 0)
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(high))
        #expect(roundTrip == high)
    }
}

// MARK: - History

@Suite("Preset library — version history")
@MainActor
struct AutoEQPresetHistoryTests {

    @Test("Versions are kept newest first, on disk, up to the limit")
    func recordAndReload() {
        let dir = makeTempDirectory()
        let store = AutoEQPresetHistoryStore(directory: dir)
        var profile = AutoEQProfile(id: "p", name: "P", source: .created, preampDB: 0, filters: [])
        for gain: Float in [1, 2, 3, 4] {
            profile.filters = [band(100, gain)]
            store.record(profile, limit: 3)
        }
        let gains = store.versions(of: "p").map { $0.profile.filters[0].gainDB }
        #expect(gains == [4, 3, 2])

        let reloaded = AutoEQPresetHistoryStore(directory: dir)
        #expect(reloaded.versions(of: "p").map(\.profile) == store.versions(of: "p").map(\.profile))

        reloaded.clear(profileID: "p")
        #expect(AutoEQPresetHistoryStore(directory: dir).versions(of: "p").isEmpty)
    }

    @Test("A limit of 0 records nothing and drops nothing; the same version is not recorded twice")
    func limitZeroAndDuplicates() {
        let store = AutoEQPresetHistoryStore(directory: makeTempDirectory())
        let profile = AutoEQProfile(id: "p", name: "P", source: .created, preampDB: 0, filters: [band(100, 1)])
        store.record(profile, limit: 5)
        store.record(profile, limit: 5)
        #expect(store.versions(of: "p").count == 1)
        var other = profile
        other.preampDB = -2
        store.record(other, limit: 0)
        #expect(store.versions(of: "p").count == 1)
    }

    @Test("Profile IDs that are not file names still get their own history")
    func unsafeIDs() {
        let store = AutoEQPresetHistoryStore(directory: makeTempDirectory())
        let a = AutoEQProfile(id: "oratory1990/over-ear/HD 600", name: "A", source: .created, preampDB: 0, filters: [])
        let b = AutoEQProfile(id: "oratory1990_over-ear_HD 600", name: "B", source: .created, preampDB: 0, filters: [])
        store.record(a, limit: 5)
        store.record(b, limit: 5)
        #expect(store.versions(of: a.id).map(\.profile.name) == ["A"])
        #expect(store.versions(of: b.id).map(\.profile.name) == ["B"])
    }
}

// MARK: - Saving

@Suite("Preset library — saving")
@MainActor
struct AutoEQPresetSavingTests {

    @Test("Saving a preset in place keeps the version it replaces")
    func presetInPlace() throws {
        let library = Library()
        let created = try #require(library.manager.createPreset(name: "Mine", kind: .parametric, engine: .biquad))
        var draft = created
        draft.filters = [band(250, -3)]
        let saved = try #require(library.manager.saveInPlace(draft))
        #expect(saved == draft)
        #expect(library.manager.profile(for: created.id) == draft)
        #expect(library.settings.autoEQUserProfiles.contains(draft))
        #expect(library.history.versions(of: created.id).map(\.profile) == [created])

        var second = saved
        second.preampDB = -4
        _ = library.manager.saveInPlace(second)
        #expect(library.history.versions(of: created.id).map(\.profile) == [saved, created])

        // Saving without a change records nothing
        _ = library.manager.saveInPlace(second)
        #expect(library.history.versions(of: created.id).count == 2)
    }

    @Test("The number of versions kept follows the setting")
    func historyLimitSetting() throws {
        let library = Library { settings in
            var app = settings.appSettings
            app.presetHistoryLimit = 2
            settings.updateAppSettings(app)
        }
        var preset = try #require(library.manager.createPreset(name: "Mine", kind: .parametric, engine: .biquad))
        for gain: Float in [1, 2, 3, 4] {
            preset.filters = [band(100, gain)]
            preset = try #require(library.manager.saveInPlace(preset))
        }
        // Replaced versions: empty, 1, 2, 3 dB; the last two are kept
        #expect(library.history.versions(of: preset.id).map { $0.profile.filters.first?.gainDB } == [3, 2])
    }

    @Test("A template saved in place keeps its correction")
    func templateKeepsCorrection() throws {
        let library = Library(files: ["imp": (fileText, "HD 600")])
        let template = try #require(library.manager.profile(for: "imp"))
        var draft = template
        draft.name = "HD 600 (desk)"
        draft.engine = .matchedBiquad
        draft.filters[0].gainDB = 9  // not allowed on a template: ignored
        let saved = try #require(library.manager.saveInPlace(draft))
        #expect(saved.name == "HD 600 (desk)")
        #expect(saved.engine == .matchedBiquad)
        #expect(saved.hasSameCorrection(as: template))
        #expect(library.history.versions(of: "imp").map(\.profile) == [template])
    }

    @Test("Changes to a template become a new preset linked to it")
    func presetFromTemplate() throws {
        let library = Library(files: ["imp": (fileText, "HD 600")]) { $0.favoriteAutoEQProfile(id: "imp") }
        let template = try #require(library.manager.profile(for: "imp"))
        var draft = template
        draft.filters[0].gainDB = -5
        let preset = try #require(library.manager.saveAsNewPreset(draft, name: "HD 600 (Custom)"))
        #expect(preset.source == .created)
        #expect(preset.templateID == "imp")
        #expect(preset.filters == draft.filters)
        #expect(preset.name == "HD 600 (Custom)")
        #expect(library.manager.profile(for: "imp") == template)
        #expect(library.manager.localPresets.map(\.id) == [preset.id])
        #expect(library.manager.localTemplates.map(\.id) == ["imp"])
        #expect(library.manager.templateName(of: preset) == "HD 600")
        // It is listed in the AutoEQ popup like its template
        #expect(library.settings.isAutoEQFavorite(id: preset.id))
        #expect(library.settings.isAutoEQFavorite(id: "imp"))

        // A copy of that preset keeps the same template
        let copy = try #require(library.manager.saveAsNewPreset(preset, name: "Copy"))
        #expect(copy.templateID == "imp")
        #expect(library.manager.profile(for: preset.id) == preset)
    }

    @Test("Reset All Settings keeps the presets and templates")
    func resetKeepsLibrary() {
        let library = Library()
        let preset = AutoEQProfile(id: "p", name: "P", source: .created, preampDB: 0, filters: [band(100, 1)])
        library.settings.saveAutoEQUserProfile(preset)
        library.settings.resetAllSettings()
        #expect(library.settings.autoEQUserProfiles == [preset])
    }
}

// MARK: - Migration

@Suite("Preset library — migration of edited imports")
@MainActor
struct AutoEQPresetMigrationTests {

    @Test("An import edited in place becomes a template again, and its edits a preset")
    func splitEditedImport() throws {
        var edited = fileProfile(id: "imp")
        edited.name = "HD 600 (desk)"
        edited.filters[0].gainDB = -5
        edited.optimizedSampleRate = 44_100
        edited.engine = .matchedBiquad
        let library = Library(files: ["imp": (fileText, "HD 600")], stored: [edited]) { settings in
            settings.setAutoEQSelection(for: "dev-1", to: AutoEQSelection(profileID: "imp", isEnabled: false))
            settings.setAutoEQSelection(for: "dev-2", to: AutoEQSelection(profileID: "other", isEnabled: true))
            settings.favoriteAutoEQProfile(id: "imp")
        }

        let template = try #require(library.manager.profile(for: "imp"))
        #expect(template.source == .imported)
        #expect(template.hasSameCorrection(as: fileProfile(id: "imp")))
        #expect(template.name == "HD 600 (desk)")
        #expect(template.optimizedSampleRate == 44_100)
        #expect(template.engine == .matchedBiquad)

        let presets = library.manager.localPresets
        #expect(presets.count == 1)
        let preset = try #require(presets.first)
        #expect(preset.hasSameCorrection(as: edited))
        #expect(preset.templateID == "imp")
        #expect(preset.name == edited.name)
        #expect(preset.engine == .matchedBiquad)

        // What played the edited version still plays it, with the same on/off state
        #expect(library.settings.getAutoEQSelection(for: "dev-1") == AutoEQSelection(profileID: preset.id, isEnabled: false))
        #expect(library.settings.getAutoEQSelection(for: "dev-2")?.profileID == "other")
        #expect(library.settings.isAutoEQFavorite(id: preset.id))
        #expect(!library.settings.isAutoEQFavorite(id: "imp"))

        // Both are stored: a relaunch finds the same library and splits nothing again
        let again = library.relaunched()
        #expect(again.localPresets.map(\.id) == [preset.id])
        #expect(again.profile(for: "imp") == template)
        #expect(again.profile(for: preset.id) == preset)
    }

    @Test("An import whose stored copy only changed its settings stays a template")
    func settingsOnlyStayTemplate() throws {
        var stored = fileProfile(id: "imp")
        stored.optimizedSampleRate = 44_100
        stored.engine = .linearPhaseFIR
        let library = Library(files: ["imp": (fileText, "HD 600")], stored: [stored]) { settings in
            settings.setAutoEQSelection(for: "dev-1", to: AutoEQSelection(profileID: "imp", isEnabled: true))
        }
        #expect(library.manager.localPresets.isEmpty)
        #expect(library.manager.profile(for: "imp") == stored)
        #expect(library.settings.getAutoEQSelection(for: "dev-1")?.profileID == "imp")
    }

    @Test("Created and downloaded profiles are left as they are")
    func othersUntouched() {
        let created = AutoEQProfile(id: "c", name: "Mine", source: .created, preampDB: 0, filters: [band(100, 2)])
        let downloaded = AutoEQProfile(id: "d", name: "HD 650", source: .downloaded, preampDB: -3, filters: [band(60, 4)], measuredBy: "oratory1990")
        let library = Library(stored: [created, downloaded])
        #expect(library.manager.localPresets == [created])
        #expect(library.manager.localTemplates == [downloaded])
    }
}
