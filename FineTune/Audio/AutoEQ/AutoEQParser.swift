// FineTune/Audio/AutoEQ/AutoEQParser.swift
import Foundation
import os

/// Parses EqualizerAPO text files into AutoEQ profiles: ParametricEQ.txt (a list of filters)
/// and GraphicEQ.txt (a frequency/gain curve, the format AutoEQ publishes for Wavelet).
nonisolated enum AutoEQParser {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "AutoEQParser")

    // MARK: - ParametricEQ.txt Parsing

    /// Parse an EqualizerAPO ParametricEQ.txt or GraphicEQ.txt string into an AutoEQProfile.
    /// Returns nil if neither a valid filter nor a curve is found. A file with a curve and no
    /// filter gives a graphic preset, rendered by the minimum-phase FIR engine.
    /// - Parameters:
    ///   - id: Explicit ID to use. If nil, generates one (slug for fetched, UUID for imported).
    static func parse(text: String, name: String, source: AutoEQSource, id: String? = nil) -> AutoEQProfile? {
        var preampDB: Float = 0
        var filters: [AutoEQFilter] = []
        var curve: [AutoEQCurvePoint] = []

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            if trimmed.lowercased().hasPrefix("preamp:") {
                preampDB = parsePreamp(trimmed)
            } else if trimmed.lowercased().hasPrefix("graphiceq:") {
                curve = parseGraphicEQ(trimmed)
            } else if trimmed.lowercased().hasPrefix("filter") {
                if let filter = parseFilterLine(trimmed) {
                    filters.append(filter)
                }
            }
        }

        // Limit to maxFilters
        if filters.count > AutoEQProfile.maxFilters {
            filters = Array(filters.prefix(AutoEQProfile.maxFilters))
        }

        let isGraphic = filters.isEmpty && curve.count >= 2
        guard !filters.isEmpty || isGraphic else { return nil }

        let resolvedID: String
        if let id {
            resolvedID = id
        } else {
            switch source {
            case .bundled, .fetched:
                resolvedID = slugify(name)
            case .imported, .created, .downloaded:
                resolvedID = UUID().uuidString
            }
        }

        if isGraphic {
            return AutoEQProfile(
                id: resolvedID,
                name: name,
                source: source,
                preampDB: preampDB,
                filters: [],
                kind: .graphic,
                engine: .minimumPhaseFIR,
                curve: curve
            )
        }

        return AutoEQProfile(
            id: resolvedID,
            name: name,
            source: source,
            preampDB: preampDB,
            filters: filters
        )
    }

    /// Parse "GraphicEQ: 20 -1.5; 21 -1.4; …" into points sorted by frequency.
    /// Points that are not two numbers, or outside 1 Hz–100 kHz and ±30 dB, are skipped;
    /// of two points at the same frequency the first is kept.
    static func parseGraphicEQ(_ line: String) -> [AutoEQCurvePoint] {
        guard let colon = line.firstIndex(of: ":") else { return [] }
        var points: [AutoEQCurvePoint] = []
        var seen = Set<Double>()
        for pair in line[line.index(after: colon)...].split(separator: ";") {
            let tokens = pair.split(whereSeparator: { $0.isWhitespace })
            guard tokens.count == 2,
                  let frequency = Double(tokens[0]), let gain = Float(tokens[1]),
                  frequency >= 1, frequency <= 100_000, abs(gain) <= 30,
                  seen.insert(frequency).inserted else { continue }
            points.append(AutoEQCurvePoint(frequency: frequency, gainDB: gain))
        }
        points.sort { $0.frequency < $1.frequency }
        return Array(points.prefix(AutoEQProfile.maxCurvePoints))
    }

    // MARK: - Private Helpers

    /// Parse "Preamp: -6.2 dB" — handles irregular whitespace.
    private static func parsePreamp(_ line: String) -> Float {
        let parts = line.components(separatedBy: ":").dropFirst()
        guard let valuePart = parts.first else { return 0 }
        let tokens = valuePart.split(whereSeparator: { $0.isWhitespace })
        guard let first = tokens.first, let value = Float(first) else { return 0 }
        return max(-30, min(30, value))
    }

    /// Parse a filter line like:
    /// "Filter 1: ON PK Fc 100 Hz Gain -2.3 dB Q 1.41"
    /// "Filter 2: ON LSC Fc 105 Hz Gain 7.0 dB Q 0.71"
    private static func parseFilterLine(_ line: String) -> AutoEQFilter? {
        let tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)

        // Must contain "ON" — skip disabled filters
        guard tokens.contains(where: { $0.uppercased() == "ON" }) else { return nil }

        // Find filter type
        let filterType: AutoEQFilter.FilterType?
        if let typeToken = tokens.first(where: { isFilterType($0) }) {
            filterType = parseFilterType(typeToken)
        } else {
            filterType = nil
        }
        guard let type = filterType else { return nil }

        // Extract Fc (frequency), Gain, Q
        guard let frequency = extractValue(after: "Fc", in: tokens),
              let gainDB = extractValue(after: "Gain", in: tokens),
              let q = extractValue(after: "Q", in: tokens) else {
            return nil
        }

        // Validate ranges
        guard frequency > 0, q > 0, abs(gainDB) <= 30 else { return nil }

        return AutoEQFilter(
            type: type,
            frequency: Double(frequency),
            gainDB: gainDB,
            q: Double(q)
        )
    }

    private static func isFilterType(_ token: String) -> Bool {
        let upper = token.uppercased()
        return ["PK", "PEQ", "LS", "LSC", "HS", "HSC"].contains(upper)
    }

    private static func parseFilterType(_ token: String) -> AutoEQFilter.FilterType? {
        switch token.uppercased() {
        case "PK", "PEQ": return .peaking
        case "LS", "LSC": return .lowShelf
        case "HS", "HSC": return .highShelf
        default: return nil
        }
    }

    /// Extract the numeric value following a keyword (e.g., "Fc" → 100).
    private static func extractValue(after keyword: String, in tokens: [String]) -> Float? {
        guard let index = tokens.firstIndex(where: { $0.caseInsensitiveCompare(keyword) == .orderedSame }),
              index + 1 < tokens.count else { return nil }
        return Float(tokens[index + 1])
    }

    /// Convert a profile name to a URL-safe slug.
    private static func slugify(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}
