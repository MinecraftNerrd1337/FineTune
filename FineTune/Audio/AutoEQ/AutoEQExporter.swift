// FineTune/Audio/AutoEQ/AutoEQExporter.swift
import Foundation

/// Writes a preset as the Equalizer APO text files `AutoEQParser` reads: ParametricEQ.txt for a
/// list of filters, GraphicEQ.txt for a curve. AutoEQ, Wavelet, Equalizer APO and FineTune
/// read them back, with the values as the preset holds them.
nonisolated enum AutoEQExporter {
    /// The preset's name, then the kind of file, as AutoEQ names its files
    static func fileName(for profile: AutoEQProfile) -> String {
        let name = profile.name
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        let kind = profile.kind == .graphic ? "GraphicEQ" : "ParametricEQ"
        return name.isEmpty ? "\(kind).txt" : "\(name) \(kind).txt"
    }

    /// The file's text: what the preset is, as comments, then its preamp and its filters or curve
    static func text(for profile: AutoEQProfile) -> String {
        var lines = ["# \(profile.name)", "# Exported from FineTune: \(profile.kind.displayName), \(rateDescription(profile.optimizedSampleRate))"]
        lines.append("Preamp: \(number(Double(profile.preampDB), decimals: 2)) dB")
        switch profile.kind {
        case .parametric:
            for (index, filter) in profile.filters.enumerated() {
                lines.append(
                    "Filter \(index + 1): ON \(code(of: filter.type)) Fc \(number(filter.frequency, decimals: 2)) Hz"
                        + " Gain \(number(Double(filter.gainDB), decimals: 2)) dB Q \(number(filter.q, decimals: 3))"
                )
            }
        case .graphic:
            let points = profile.curve.map { "\(number($0.frequency, decimals: 2)) \(number(Double($0.gainDB), decimals: 2))" }
            lines.append("GraphicEQ: " + points.joined(separator: "; "))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func code(of type: AutoEQFilter.FilterType) -> String {
        switch type {
        case .peaking: return "PK"
        case .lowShelf: return "LSC"
        case .highShelf: return "HSC"
        }
    }

    /// The rate the filters were made for, which the file has no field for
    private static func rateDescription(_ rate: Double) -> String {
        guard rate.isFinite, rate > 0 else { return "analog filters" }
        return "made for \(number(rate / 1000, decimals: 1)) kHz"
    }

    /// `value` with up to `decimals` decimals and a dot, whatever the language: "42", "0.93"
    static func number(_ value: Double, decimals: Int) -> String {
        var text = String(format: "%.\(decimals)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }
}
