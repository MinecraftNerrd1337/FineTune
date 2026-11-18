// FineTune/Models/AutoEQProfile.swift
import Foundation

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

/// One point of a graphic preset's curve.
nonisolated struct AutoEQCurvePoint: Codable, Equatable {
    var frequency: Double    // Hz
    var gainDB: Float        // dB
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
    /// A cascade of standard (RBJ cookbook) biquad filters, like most parametric EQ apps.
    /// No latency. Bands near the top of the spectrum are narrower than drawn.
    case biquad
    /// A cascade of biquads fitted to the exact curve of each band up to the Nyquist
    /// frequency. No latency, same cost as `biquad`.
    case matchedBiquad
    /// The exact curve as a minimum-phase FIR filter: no latency, same phase behaviour as
    /// an analog EQ. The only zero-latency engine for graphic presets.
    case minimumPhaseFIR
    /// The exact curve as a linear-phase FIR filter: no phase change at all, at the price of
    /// a latency that depends on the curve.
    case linearPhaseFIR

    var id: Self { self }

    var displayName: String {
        switch self {
        case .biquad: return "Biquad"
        case .matchedBiquad: return "Exact biquad"
        case .minimumPhaseFIR: return "Minimum-phase FIR"
        case .linearPhaseFIR: return "Linear-phase FIR"
        }
    }

    /// One line on what the engine does, for the EQ Manager.
    var summary: String {
        switch self {
        case .biquad: return "Standard biquad filters, re-tuned from the base rate. No latency."
        case .matchedBiquad: return "Biquad filters fitted to the exact curve at every sample rate. No latency."
        case .minimumPhaseFIR: return "Exact curve, phase of an analog EQ. No latency."
        case .linearPhaseFIR: return "Exact curve, phase untouched. Adds latency."
        }
    }

    var isFIR: Bool { self == .minimumPhaseFIR || self == .linearPhaseFIR }

    /// Engines that can render a preset of this kind. A curve has no bands to build biquads from.
    static func available(for kind: AutoEQPresetKind) -> [AutoEQCorrectionEngine] {
        switch kind {
        case .parametric: return allCases
        case .graphic: return [.minimumPhaseFIR, .linearPhaseFIR]
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // "exactFIR" was the single FIR engine of earlier builds
        self = raw == "exactFIR" ? .minimumPhaseFIR : (AutoEQCorrectionEngine(rawValue: raw) ?? .biquad)
    }
}

/// Sample rate a filter list was designed for (`AutoEQProfile.optimizedSampleRate`).
///
/// AutoEQ, like most parametric EQ tools, optimises its filters as cookbook biquads at one
/// sample rate. The same list played at another rate gives a slightly different curve near the
/// top of the spectrum, so the exact engines need to know that rate to reproduce the curve the
/// list was made for. 0 stands for analog filters (the RBJ analog prototypes).
nonisolated enum AutoEQBaseRate {
    static let analog = 0.0
    /// AutoEQ's default (`DEFAULT_FS` in autoeq/constants.py), used for its published results.
    static let autoEQDefault = 44_100.0
    /// Rates offered in the import dialogs and the EQ Manager.
    static let choices: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000, analog]
    /// The last rate chosen when importing a file (UserDefaults).
    static let lastImportRateKey = "AutoEQImportBaseRate"

    static func label(_ rate: Double) -> String {
        rate > 0 ? String(format: "%g kHz", rate / 1000) : "Analog"
    }

    /// A stored rate, or 48 kHz when it is not one a filter list can be made for.
    static func sanitized(_ rate: Double) -> Double {
        rate == analog || (rate.isFinite && rate >= 8_000 && rate <= 768_000) ? rate : 48_000
    }

    /// The rate the import dialogs offer first: the last one chosen, else AutoEQ's.
    static var lastImportRate: Double {
        get {
            let stored = UserDefaults.standard.object(forKey: lastImportRateKey) as? Double
            return stored.map(sanitized) ?? autoEQDefault
        }
        set { UserDefaults.standard.set(sanitized(newValue), forKey: lastImportRateKey) }
    }
}

/// How closely a linear-phase FIR preset follows its curve (`AutoEQProfile.linearPhaseToleranceDB`).
///
/// The linear-phase engine picks the shortest filter whose curve stays within this tolerance
/// above 100 Hz (twice it at 20 Hz). A tighter tolerance gives a longer filter: more latency and
/// more CPU. The latency still stops at 85 ms; the EQ Manager shows the error actually reached.
nonisolated enum AutoEQLinearPhasePrecision {
    /// The tolerance of presets that never chose one (`FIRDesign.linearPhaseToleranceDB`).
    static let standard = 0.5
    /// Tolerances offered in the EQ Manager, in dB, tightest first.
    static let choices: [Double] = [0.05, 0.1, 0.25, 0.5, 1.0]

    /// The value to store for a chosen tolerance: nil for the standard one or an unknown value.
    static func stored(_ tolerance: Double?) -> Double? {
        guard let tolerance, tolerance != standard, choices.contains(tolerance) else { return nil }
        return tolerance
    }

    static func label(_ tolerance: Double) -> String {
        let value = "±\(String(format: "%g", tolerance)) dB"
        return tolerance == standard ? "\(value) (Standard)" : value
    }
}

/// A headphone/speaker correction profile.
///
/// Profiles come in two roles (see `isTemplate`):
/// - a **template** is what comes from outside: an imported file, a profile of the AutoEQ catalog
///   or a downloaded copy of one. Its correction (bands or curve, and preamp) never changes;
///   only its name, base rate, engine and precision can be edited.
/// - a **preset** is created in the EQ Manager, empty or from a template (`templateID`), and is
///   edited in place. Its earlier versions are kept by `AutoEQPresetHistoryStore`.
nonisolated struct AutoEQProfile: Codable, Equatable, Identifiable {
    let id: String           // Slug for fetched, UUID for imported
    var name: String         // "Sennheiser HD 600"
    let source: AutoEQSource
    var preampDB: Float      // Negative preamp to prevent clipping
    var filters: [AutoEQFilter]
    /// Measurement source (e.g. "oratory1990", "crinacle"). Nil for imported profiles.
    let measuredBy: String?
    /// Sample rate the filter parameters were optimized for (Hz), or 0 for analog filters.
    /// See `AutoEQBaseRate`. Not used by graphic presets, whose curve is in Hz.
    var optimizedSampleRate: Double
    /// Parametric (filters) or graphic (curve).
    var kind: AutoEQPresetKind
    /// Engine chosen for this preset. See `effectiveEngine` for the one that runs.
    var engine: AutoEQCorrectionEngine
    /// The curve of a graphic preset, by rising frequency. Empty for parametric presets.
    var curve: [AutoEQCurvePoint]
    /// The template a preset was created from. Nil for templates and for presets made from scratch.
    var templateID: String?
    /// Tolerance of the linear-phase FIR engine, in dB. Nil for the standard one. See
    /// `AutoEQLinearPhasePrecision` and `effectiveLinearPhaseToleranceDB`.
    var linearPhaseToleranceDB: Double?
    /// Gain added at runtime to the preamp, in dB, and bypassed with it by the Preamp switch:
    /// set by `AudioEngine` when the correction is off, so the preset keeps the level it has when on
    /// (see `AutoEQResponse.perceivedLevelChangeDB`). Never stored: not in `CodingKeys`.
    var levelMatchDB: Float = 0

    static let maxFilters = 128
    static let maxCurvePoints = 1024
    /// Limits applied when editing the preamp in the EQ Manager.
    static let preampRange: ClosedRange<Float> = -30...12

    enum CodingKeys: String, CodingKey {
        case id, name, source, preampDB, filters, measuredBy, optimizedSampleRate, kind, engine, curve, templateID
        case linearPhaseToleranceDB
    }

    init(
        id: String, name: String, source: AutoEQSource,
        preampDB: Float, filters: [AutoEQFilter],
        measuredBy: String? = nil,
        optimizedSampleRate: Double = 48000,
        kind: AutoEQPresetKind = .parametric,
        engine: AutoEQCorrectionEngine = .biquad,
        curve: [AutoEQCurvePoint] = [],
        templateID: String? = nil,
        linearPhaseToleranceDB: Double? = nil
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
        self.curve = curve
        self.templateID = templateID
        self.linearPhaseToleranceDB = linearPhaseToleranceDB
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
        curve = try container.decodeIfPresent([AutoEQCurvePoint].self, forKey: .curve) ?? []
        templateID = try container.decodeIfPresent(String.self, forKey: .templateID)
        linearPhaseToleranceDB = try container.decodeIfPresent(Double.self, forKey: .linearPhaseToleranceDB)
    }
}

nonisolated extension AutoEQProfile {
    /// Imported, downloaded or catalog profiles: their correction is never changed. Presets
    /// (created in the EQ Manager) are edited in place.
    var isTemplate: Bool { source.isTemplate }

    /// Whether two profiles apply the same correction: same kind, bands or curve, and preamp.
    /// Name, base rate, engine and precision are settings of the profile, not part of its correction.
    func hasSameCorrection(as other: AutoEQProfile) -> Bool {
        kind == other.kind && filters == other.filters && curve == other.curve && preampDB == other.preampDB
    }

    /// This profile with the correction (kind, bands, curve, preamp) of another.
    func withCorrection(of other: AutoEQProfile) -> AutoEQProfile {
        var copy = self
        copy.kind = other.kind
        copy.filters = other.filters
        copy.curve = other.curve
        copy.preampDB = other.preampDB
        return copy
    }

    /// Number of bands, for parametric presets only.
    var bandCount: Int? {
        kind == .parametric ? filters.count : nil
    }

    /// The engine that actually runs: the chosen one, or minimum-phase FIR when the chosen
    /// one cannot render this kind of preset (a graphic preset left on a biquad engine).
    var effectiveEngine: AutoEQCorrectionEngine {
        AutoEQCorrectionEngine.available(for: kind).contains(engine) ? engine : .minimumPhaseFIR
    }

    /// The tolerance the linear-phase FIR engine designs this preset's filter for, in dB.
    var effectiveLinearPhaseToleranceDB: Double {
        linearPhaseToleranceDB ?? AutoEQLinearPhasePrecision.standard
    }

    /// The base rate for the response math: nil for analog filters.
    var designBaseRate: Double? {
        optimizedSampleRate > 0 ? optimizedSampleRate : nil
    }

    /// Whether there is a curve to apply (as opposed to the preamp alone).
    var hasCorrection: Bool {
        switch kind {
        case .parametric: return !filters.isEmpty
        case .graphic: return curve.count >= 2
        }
    }

    /// One-line description of the preset, e.g. "PEQ · 10 bands · Biquad".
    var attributesSummary: String {
        var parts = [kind.shortName]
        if let bandCount {
            parts.append(bandCount == 1 ? "1 band" : "\(bandCount) bands")
        } else if kind == .graphic {
            parts.append("\(curve.count) points")
        }
        parts.append(effectiveEngine.displayName)
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
        let validCurve = curve
            .filter { $0.frequency > 0 && $0.frequency.isFinite && $0.gainDB.isFinite }
            .map { AutoEQCurvePoint(frequency: $0.frequency, gainDB: max(-30, min(30, $0.gainDB))) }
            .sorted { $0.frequency < $1.frequency }
        var result = AutoEQProfile(
            id: id, name: name, source: source,
            preampDB: clampedPreamp,
            filters: Array(validFilters.prefix(Self.maxFilters)),
            measuredBy: measuredBy,
            optimizedSampleRate: AutoEQBaseRate.sanitized(optimizedSampleRate),
            kind: kind,
            engine: engine,
            curve: Array(validCurve.prefix(Self.maxCurvePoints)),
            templateID: templateID,
            linearPhaseToleranceDB: AutoEQLinearPhasePrecision.stored(linearPhaseToleranceDB)
        )
        result.levelMatchDB = levelMatchDB.isFinite ? max(-30, min(30, levelMatchDB)) : 0
        return result
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

    /// Everything but the presets created in the EQ Manager. See `AutoEQProfile.isTemplate`.
    var isTemplate: Bool { self != .created }
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
