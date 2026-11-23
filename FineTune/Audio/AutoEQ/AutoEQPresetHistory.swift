// FineTune/Audio/AutoEQ/AutoEQPresetHistory.swift
import Foundation
import os

/// A version of a preset (or of a template's settings) that a later save replaced.
nonisolated struct AutoEQPresetVersion: Codable, Equatable, Identifiable {
    let id: UUID
    /// When this version stopped being the current one.
    let replacedAt: Date
    let profile: AutoEQProfile

    init(id: UUID = UUID(), replacedAt: Date, profile: AutoEQProfile) {
        self.id = id
        self.replacedAt = replacedAt
        self.profile = profile
    }
}

/// Earlier versions of the user's presets, newest first, so that a save never loses the version
/// it replaces. Each profile has its own JSON file, outside settings.json (which is rewritten on
/// every volume change, and would grow with the curves of graphic presets).
///
/// The number of versions kept is a setting (`AppSettings.presetHistoryLimit`). Lowering it never
/// deletes anything at once: a profile's oldest versions are dropped at its next save.
@Observable
@MainActor
final class AutoEQPresetHistoryStore {
    nonisolated static let defaultLimit = 10
    nonisolated static let limitRange = 0...100

    private let directory: URL
    /// Versions read so far, by profile ID. Reading a file on first use does not count as a
    /// change for observers: `revision` does.
    @ObservationIgnored private var cache: [String: [AutoEQPresetVersion]] = [:]
    /// Bumped by every change, so that views listing versions refresh.
    private var revision = 0
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "AutoEQPresetHistory")

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FineTune")
            .appendingPathComponent("AutoEQ History")
    }

    /// The earlier versions of a profile, newest first.
    func versions(of profileID: String) -> [AutoEQPresetVersion] {
        _ = revision
        if let cached = cache[profileID] { return cached }
        let loaded = load(profileID)
        cache[profileID] = loaded
        return loaded
    }

    /// Keep `profile` as the newest earlier version of its profile, then keep at most `limit`
    /// versions. With a limit of 0 nothing is recorded, and nothing already kept is dropped.
    /// A version identical to the newest one kept is not recorded twice.
    func record(_ profile: AutoEQProfile, limit: Int, at date: Date = Date()) {
        guard limit > 0 else { return }
        var list = versions(of: profile.id)
        if list.first?.profile != profile {
            list.insert(AutoEQPresetVersion(replacedAt: date, profile: profile), at: 0)
        }
        if list.count > limit { list.removeLast(list.count - limit) }
        store(list, for: profile.id)
    }

    /// Forget every earlier version of a profile.
    func clear(profileID: String) {
        store([], for: profileID)
    }

    // MARK: - Files

    private func fileURL(for profileID: String) -> URL {
        // Profile IDs are UUIDs or catalog slugs; keep only characters safe in a file name
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_")
        let name = profileID.addingPercentEncoding(withAllowedCharacters: allowed) ?? UUID().uuidString
        return directory.appendingPathComponent("\(name).json")
    }

    private func load(_ profileID: String) -> [AutoEQPresetVersion] {
        let url = fileURL(for: profileID)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([AutoEQPresetVersion].self, from: Data(contentsOf: url))
        } catch {
            logger.error("Could not read the history of \(profileID): \(error.localizedDescription)")
            return []
        }
    }

    private func store(_ list: [AutoEQPresetVersion], for profileID: String) {
        cache[profileID] = list
        revision += 1
        let url = fileURL(for: profileID)
        do {
            if list.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                return
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(list).write(to: url, options: .atomic)
        } catch {
            logger.error("Could not save the history of \(profileID): \(error.localizedDescription)")
        }
    }
}
