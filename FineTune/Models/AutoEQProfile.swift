// FineTune/Models/AutoEQProfile.swift

/// A single biquad filter in an AutoEQ correction profile.
nonisolated struct AutoEQFilter: Codable, Equatable {
    enum FilterType: String, Codable {
        case peaking, lowShelf, highShelf
    }
    var type: FilterType
    var frequency: Double    // Hz
    var gainDB: Float        // dB
    var q: Double            // Quality factor

    /// Limits applied when editing a band in the EQ Manager.
    static let frequencyRange: ClosedRange<Double> = 10...20_000
    static let gainRange: ClosedRange<Float> = -24...24
    static let qRange: ClosedRange<Double> = 0.1...30
}

/// How a preset describes its correction curve.
nonisolated enum AutoEQPresetKind: String, Codable, CaseIterable, Identifiable {
    /// A list of filters (ParametricEQ.txt).
    case parametric
    /// A frequency/gain curve (GraphicEQ.txt).
    case graphic

    var id: Self { self }

    var displayName: String {
        switch self {
        case .parametric: return "Parametric EQ"
        case .graphic: return "Graphic EQ"
        }
    }

    var shortName: String {
        switch self {
        case .parametric: return "PEQ"
        case .graphic: return "GraphicEQ"
        }
    }
}

/// How a preset's curve is turned into audio processing.
nonisolated enum AutoEQCorrectionEngine: String, Codable, CaseIterable, Identifiable {
    /// The exact target curve as a FIR filter.
    case exactFIR
    /// A cascade of biquad filters, like most parametric EQ apps.
    case biquad

    var id: Self { self }

    var displayName: String {
        switch self {
        case .exactFIR: return "Exact FIR"
        case .biquad: return "Biquad"
        }
    }
}

/// A headphone/speaker correction profile from AutoEQ.
nonisolated struct AutoEQProfile: Codable, Equatable, Identifiable {
    let id: String           // Slug for fetched, UUID for imported
    var name: String         // "Sennheiser HD 600"
    let source: AutoEQSource
    var preampDB: Float      // Negative preamp to prevent clipping
    var filters: [AutoEQFilter]
    /// Measurement source (e.g. "oratory1990", "crinacle"). Nil for imported profiles.
    let measuredBy: String?
    /// Sample rate the filter parameters were optimized for (Hz).
    var optimizedSampleRate: Double
    /// Parametric (filters) or graphic (curve).
    var kind: AutoEQPresetKind
    /// Engine chosen for this preset. Processing is biquad-only until the FIR engine exists.
    var engine: AutoEQCorrectionEngine

    static let maxFilters = 128
    /// Limits applied when editing the preamp in the EQ Manager.
    static let preampRange: ClosedRange<Float> = -30...12

    enum CodingKeys: String, CodingKey {
        case id, name, source, preampDB, filters, measuredBy, optimizedSampleRate, kind, engine
    }

    init(
        id: String, name: String, source: AutoEQSource,
        preampDB: Float, filters: [AutoEQFilter],
        measuredBy: String? = nil,
        optimizedSampleRate: Double = 48000,
        kind: AutoEQPresetKind = .parametric,
        engine: AutoEQCorrectionEngine = .biquad
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.preampDB = preampDB
        self.filters = filters
        self.measuredBy = measuredBy
        self.optimizedSampleRate = optimizedSampleRate
        self.kind = kind
        self.engine = engine
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        source = try container.decode(AutoEQSource.self, forKey: .source)
        preampDB = try container.decode(Float.self, forKey: .preampDB)
        filters = try container.decode([AutoEQFilter].self, forKey: .filters)
        measuredBy = try container.decodeIfPresent(String.self, forKey: .measuredBy)
        optimizedSampleRate = try container.decodeIfPresent(Double.self, forKey: .optimizedSampleRate) ?? 48000
        kind = try container.decodeIfPresent(AutoEQPresetKind.self, forKey: .kind) ?? .parametric
        engine = try container.decodeIfPresent(AutoEQCorrectionEngine.self, forKey: .engine) ?? .biquad
    }
}

nonisolated extension AutoEQProfile {
    /// Number of bands, for parametric presets only.
    var bandCount: Int? {
        kind == .parametric ? filters.count : nil
    }

    /// One-line description of the preset, e.g. "PEQ · 10 bands · Biquad".
    var attributesSummary: String {
        var parts = [kind.shortName]
        if let bandCount {
            parts.append(bandCount == 1 ? "1 band" : "\(bandCount) bands")
        }
        parts.append(engine.displayName)
        return parts.joined(separator: " · ")
    }

    /// Short label for where the preset came from.
    var sourceLabel: String? {
        switch source {
        case .imported: return "Imported"
        case .created: return "Custom"
        case .downloaded: return measuredBy.map { "\($0) · Downloaded" } ?? "Downloaded"
        case .bundled, .fetched: return measuredBy
        }
    }
}

extension AutoEQProfile {
    /// Validates filters using the same rules as the text parser.
    func validated() -> AutoEQProfile {
        let validFilters = filters.filter { f in
            f.frequency > 0 && f.q > 0 && abs(f.gainDB) <= 30
        }
        let clampedPreamp = max(-30, min(30, preampDB))
        return AutoEQProfile(
            id: id, name: name, source: source,
            preampDB: clampedPreamp,
            filters: Array(validFilters.prefix(Self.maxFilters)),
            measuredBy: measuredBy,
            optimizedSampleRate: optimizedSampleRate,
            kind: kind,
            engine: engine
        )
    }
}

/// Where a profile came from.
nonisolated enum AutoEQSource: String, Codable {
    case bundled, imported, fetched
    /// Created in the EQ Manager.
    case created
    /// Copied from the AutoEQ catalog into the user's library.
    case downloaded

    /// Stored by the user (imported, created or downloaded), as opposed to the AutoEQ catalog.
    var isLocal: Bool { self == .imported || self == .created || self == .downloaded }
}

/// Lightweight catalog entry for the AutoEQ search index (no filter data).
/// Populated from the AutoEQ GitHub INDEX.md.
nonisolated struct AutoEQCatalogEntry: Codable, Identifiable, Equatable {
    let id: String           // Slugified name
    let name: String         // "AKG K240 Studio"
    let measuredBy: String   // "oratory1990"
    let relativePath: String // "oratory1990/over-ear/AKG K240 Studio"
}

/// Per-device AutoEQ selection (stored in settings).
nonisolated struct AutoEQSelection: Codable, Equatable {
    let profileID: String
    var isEnabled: Bool
}
