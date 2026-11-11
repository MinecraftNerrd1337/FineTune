// FineTune/Audio/AutoEQ/AutoEQProfileManager.swift
import Foundation
import os

/// Search result from `AutoEQProfileManager.search()`.
struct AutoEQSearchResult {
    let entries: [AutoEQCatalogEntry]
    let totalCount: Int
}

/// Manages the catalog of AutoEQ headphone correction profiles.
/// Search operates on lightweight catalog entries; full profiles are resolved on demand.
@Observable
@MainActor
final class AutoEQProfileManager {
    /// Fully-loaded profiles (imported + previously fetched).
    private(set) var profiles: [String: AutoEQProfile] = [:]

    private let fetcher: AutoEQFetcher
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "AutoEQProfileManager")
    private let loader: AutoEQProfileLoader
    /// Where presets created or edited in the EQ Manager persist (settings.json).
    private weak var userProfileStore: SettingsManager?

    /// Pre-sorted catalog entries for fast search.
    private var sortedEntries: [AutoEQCatalogEntry] = []

    /// Normalized names for fuzzy search (parallel array with sortedEntries).
    private var normalizedNames: [String] = []

    /// Whether each entry is one of the user's presets (parallel array with sortedEntries).
    private var localEntryFlags: [Bool] = []

    init(loader: AutoEQProfileLoader = AutoEQProfileLoader(), fetcher: AutoEQFetcher? = nil) {
        self.loader = loader
        self.fetcher = fetcher ?? AutoEQFetcher()

        // Imported profiles are small — load synchronously
        let imported = loader.loadImportedProfiles()
        for profile in imported {
            profiles[profile.id] = profile
        }

        // Load catalog from cache/GitHub
        Task { @MainActor in
            await self.fetcher.loadCatalog()
            self.rebuildSearchIndex()
        }
    }

    /// Load the presets created or edited in the EQ Manager. Edited versions replace
    /// the imported files they came from.
    func attachUserProfileStore(_ store: SettingsManager) {
        userProfileStore = store
        for profile in store.autoEQUserProfiles {
            profiles[profile.id] = profile
        }
        rebuildSearchIndex()
    }

    // MARK: - Catalog State (forwarded from fetcher)

    var catalogState: AutoEQFetcher.FetchState { fetcher.catalogState }
    var catalogEntries: [AutoEQCatalogEntry] { fetcher.catalog }

    func catalogEntry(for id: String) -> AutoEQCatalogEntry? {
        fetcher.catalog.first(where: { $0.id == id })
    }

    /// Catalog entry or local preset (imported or created) for an ID.
    func entry(for id: String) -> AutoEQCatalogEntry? {
        sortedEntries.first(where: { $0.id == id })
    }

    /// Imported and created presets, sorted by name.
    var localProfiles: [AutoEQProfile] {
        profiles.values
            .filter { $0.source.isLocal }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Import / Delete

    /// Import a ParametricEQ.txt or GraphicEQ.txt file. Copies it to app support and adds it to
    /// the catalog. `baseRate` is the sample rate the file's filters were designed for (see
    /// `AutoEQBaseRate`); a graphic curve has none.
    func importProfile(
        from url: URL, name: String, baseRate: Double = AutoEQBaseRate.autoEQDefault
    ) -> AutoEQProfile? {
        guard var profile = loader.importProfile(from: url, name: name) else { return nil }
        if profile.kind == .parametric {
            profile.optimizedSampleRate = AutoEQBaseRate.sanitized(baseRate)
            // The text file does not hold the rate: the stored copy (settings.json) replaces
            // the file's preset on the next launch
            userProfileStore?.saveAutoEQUserProfile(profile)
        }
        profiles[profile.id] = profile
        rebuildSearchIndex()
        return profile
    }

    /// Create an empty preset in the EQ Manager. Bands are added later by editing.
    func createPreset(name: String, kind: AutoEQPresetKind, engine: AutoEQCorrectionEngine) -> AutoEQProfile? {
        let profile = AutoEQProfile(
            id: UUID().uuidString, name: name, source: .created,
            preampDB: 0, filters: [], kind: kind, engine: engine
        )
        guard let userProfileStore else { return nil }
        userProfileStore.saveAutoEQUserProfile(profile)
        profiles[profile.id] = profile
        rebuildSearchIndex()
        return profile
    }

    /// Save a preset edited in the EQ Manager.
    /// Imported and created presets are saved in place; catalog presets are saved as a new custom copy.
    /// Returns the saved preset, or nil on failure.
    func saveEditedProfile(_ profile: AutoEQProfile) -> AutoEQProfile? {
        let toSave = profile.source.isLocal ? profile : AutoEQProfile(
            id: UUID().uuidString,
            name: "\(profile.name) (Custom)",
            source: .created,
            preampDB: profile.preampDB,
            filters: profile.filters,
            measuredBy: profile.measuredBy,
            optimizedSampleRate: profile.optimizedSampleRate,
            kind: profile.kind,
            engine: profile.engine,
            curve: profile.curve
        )
        guard let userProfileStore else { return nil }
        userProfileStore.saveAutoEQUserProfile(toSave)
        profiles[toSave.id] = toSave
        rebuildSearchIndex()
        logger.info("Saved edited preset: \(toSave.name)")
        return toSave
    }

    /// The user's library copy of a catalog preset, if it was already downloaded.
    func libraryCopy(of entry: AutoEQCatalogEntry) -> AutoEQProfile? {
        profiles.values.first {
            $0.source == .downloaded && $0.name == entry.name && $0.measuredBy == entry.measuredBy
        }
    }

    /// Copy a catalog preset into the user's library (settings.json). The copy is independent
    /// of the catalog: it keeps working offline and can be edited in place.
    func downloadToLibrary(_ entry: AutoEQCatalogEntry) async -> AutoEQProfile? {
        if let existing = libraryCopy(of: entry) { return existing }
        guard let fetched = await resolveProfile(for: entry), let userProfileStore else { return nil }
        let copy = AutoEQProfile(
            id: UUID().uuidString,
            name: fetched.name,
            source: .downloaded,
            preampDB: fetched.preampDB,
            filters: fetched.filters,
            measuredBy: entry.measuredBy,
            optimizedSampleRate: fetched.optimizedSampleRate,
            kind: fetched.kind,
            engine: fetched.engine,
            curve: fetched.curve
        )
        userProfileStore.saveAutoEQUserProfile(copy)
        profiles[copy.id] = copy
        rebuildSearchIndex()
        logger.info("Downloaded preset to library: \(copy.name)")
        return copy
    }

    /// Delete an imported or created profile from disk and catalog.
    func deleteImportedProfile(id: String) {
        guard let profile = profiles[id], profile.source.isLocal else { return }
        profiles.removeValue(forKey: id)
        loader.deleteProfileFiles(id: id)
        userProfileStore?.removeAutoEQUserProfile(id: id)
        rebuildSearchIndex()
        logger.info("Deleted imported profile: \(profile.name)")
    }

    // MARK: - Profile Resolution

    /// Resolve a profile by ID: memory → cache → network.
    func resolveProfile(for id: String) async -> AutoEQProfile? {
        // Already loaded (imported or previously fetched)
        if let existing = profiles[id] { return existing }

        // Find catalog entry for this ID
        guard let entry = fetcher.catalog.first(where: { $0.id == id }) else { return nil }

        do {
            let profile = try await fetcher.fetchProfile(for: entry)
            profiles[id] = profile
            return profile
        } catch {
            logger.error("Failed to resolve profile \(id): \(error.localizedDescription)")
            return nil
        }
    }

    /// Resolve a profile from a catalog entry.
    func resolveProfile(for entry: AutoEQCatalogEntry) async -> AutoEQProfile? {
        if let existing = profiles[entry.id] { return existing }

        do {
            let profile = try await fetcher.fetchProfile(for: entry)
            profiles[entry.id] = profile
            return profile
        } catch {
            logger.error("Failed to fetch profile \(entry.name): \(error.localizedDescription)")
            return nil
        }
    }

    /// Look up a profile by ID (only returns already-loaded profiles).
    func profile(for id: String) -> AutoEQProfile? {
        profiles[id]
    }

    // MARK: - Search

    /// Rebuild the search index from fetcher catalog + imported profiles.
    private func rebuildSearchIndex() {
        // Catalog entries from GitHub
        var entries = fetcher.catalog

        // Add imported and created profiles as pseudo-catalog entries
        for profile in profiles.values where profile.source.isLocal {
            let entry = AutoEQCatalogEntry(
                id: profile.id,
                name: profile.name,
                measuredBy: profile.sourceLabel ?? "Imported",
                relativePath: ""
            )
            entries.append(entry)
        }

        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        sortedEntries = entries
        normalizedNames = entries.map { Self.normalize($0.name) }
        localEntryFlags = entries.map { profiles[$0.id]?.source.isLocal == true }
    }

    /// Fuzzy search across catalog entry names with relevance ranking.
    /// - Parameter scope: limits the search to the user's presets or to the AutoEQ catalog; nil searches both.
    func search(query: String, limit: Int = 50, scope: AutoEQSearchScope? = nil) -> AutoEQSearchResult {
        guard !query.isEmpty else { return AutoEQSearchResult(entries: [], totalCount: 0) }

        let loweredQuery = query.lowercased()
        let normalizedQuery = Self.normalize(query)

        var scored: [(index: Int, score: Int)] = []
        scored.reserveCapacity(200)

        for i in 0..<sortedEntries.count {
            if let scope, localEntryFlags[i] != (scope == .library) { continue }
            let loweredName = sortedEntries[i].name.lowercased()
            let normalizedName = normalizedNames[i]

            let score = Self.matchScore(
                loweredQuery: loweredQuery,
                normalizedQuery: normalizedQuery,
                loweredName: loweredName,
                normalizedName: normalizedName
            )

            if score > 0 {
                scored.append((index: i, score: score))
            }
        }

        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return sortedEntries[$0.index].name < sortedEntries[$1.index].name
        }

        let totalCount = scored.count
        let limitedResults = scored.prefix(limit).map { sortedEntries[$0.index] }

        return AutoEQSearchResult(entries: Array(limitedResults), totalCount: totalCount)
    }

    // MARK: - Scoring

    private static func matchScore(
        loweredQuery: String,
        normalizedQuery: String,
        loweredName: String,
        normalizedName: String
    ) -> Int {
        // Tier 1: Exact substring in original name (case-insensitive)
        if loweredName.contains(loweredQuery) {
            var score = 100
            if loweredName.hasPrefix(loweredQuery) { score += 50 }
            if loweredName == loweredQuery { score += 100 }
            score += max(0, 50 - loweredName.count)
            return score
        }

        // Tier 2: Normalized substring (space/punctuation tolerance)
        if !normalizedQuery.isEmpty && normalizedName.contains(normalizedQuery) {
            var score = 50
            if normalizedName.hasPrefix(normalizedQuery) { score += 25 }
            score += max(0, 25 - normalizedName.count)
            return score
        }

        // Tier 3: Token-based fuzzy match
        let queryTokens = loweredQuery.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !queryTokens.isEmpty else { return 0 }

        var totalTokenScore = 0
        for token in queryTokens {
            let tokenScore = bestTokenMatch(token: token, in: loweredName)
            if tokenScore == 0 { return 0 }
            totalTokenScore += tokenScore
        }

        return min(49, totalTokenScore / queryTokens.count)
    }

    private static func bestTokenMatch(token: String, in name: String) -> Int {
        if name.contains(token) { return 40 }

        let nameTokens = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map(String.init)
        let maxAllowedDistance = token.count <= 4 ? 1 : 2

        var bestScore = 0
        for nameToken in nameTokens {
            let distance = editDistance(token, nameToken.lowercased())
            if distance <= maxAllowedDistance {
                let score = max(1, 30 - distance * 10)
                bestScore = max(bestScore, score)
            }
        }
        return bestScore
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count
        let n = bChars.count

        if m == 0 { return n }
        if n == 0 { return m }
        if abs(m - n) > 2 { return max(m, n) }

        var prev = Array(0...n)
        var curr = Array(repeating: 0, count: n + 1)

        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                if aChars[i - 1] == bChars[j - 1] {
                    curr[j] = prev[j - 1]
                } else {
                    curr[j] = 1 + min(prev[j - 1], prev[j], curr[j - 1])
                }
            }
            swap(&prev, &curr)
        }
        return prev[n]
    }

    // MARK: - Normalization

    private static func normalize(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        for char in string.unicodeScalars {
            if CharacterSet.alphanumerics.contains(char) {
                result.append(Character(char))
            }
        }
        return result.lowercased()
    }
}

/// Where a preset search looks.
nonisolated enum AutoEQSearchScope: Hashable, CaseIterable, Identifiable {
    /// The user's presets: imported, created or downloaded.
    case library
    /// The AutoEQ catalog on GitHub.
    case catalog

    var id: Self { self }

    var displayName: String {
        switch self {
        case .library: "My Presets"
        case .catalog: "AutoEQ Catalog"
        }
    }
}
