// FineTuneTests/AutoEQExporterTests.swift
import Foundation
import Testing
@testable import FineTune

@Suite("AutoEQExporter — a preset as an Equalizer APO file")
struct AutoEQExporterTests {
    @Test("A parametric preset reads back with its preamp and filters")
    func parametricRoundTrip() throws {
        let filters = [
            AutoEQFilter(type: .lowShelf, frequency: 105, gainDB: 6.4, q: 0.7),
            AutoEQFilter(type: .peaking, frequency: 1234.56, gainDB: -2.15, q: 1.414),
            AutoEQFilter(type: .highShelf, frequency: 10_000, gainDB: -3, q: 0.707),
        ]
        let preset = AutoEQProfile(id: "p", name: "My Preset", source: .created, preampDB: -6.4, filters: filters)
        let text = AutoEQExporter.text(for: preset)
        let read = try #require(AutoEQParser.parse(text: text, name: "My Preset", source: .imported))
        #expect(read.kind == .parametric)
        #expect(read.preampDB == -6.4)
        // The parser reads Fc and Q as Float, as Equalizer APO does
        try #require(read.filters.count == filters.count)
        for (back, original) in zip(read.filters, filters) {
            #expect(back.type == original.type)
            #expect(abs(back.frequency - original.frequency) < 0.001)
            #expect(back.gainDB == original.gainDB)
            #expect(abs(back.q - original.q) < 0.0001)
        }
    }

    @Test("A graphic preset reads back with its curve")
    func graphicRoundTrip() throws {
        let curve = [
            AutoEQCurvePoint(frequency: 20, gainDB: 1.5),
            AutoEQCurvePoint(frequency: 1000, gainDB: 0),
            AutoEQCurvePoint(frequency: 20_000, gainDB: -4.25),
        ]
        let preset = AutoEQProfile(
            id: "g", name: "Curve", source: .created, preampDB: -1.5, filters: [],
            kind: .graphic, engine: .minimumPhaseFIR, curve: curve
        )
        let text = AutoEQExporter.text(for: preset)
        let read = try #require(AutoEQParser.parse(text: text, name: "Curve", source: .imported))
        #expect(read.kind == .graphic)
        #expect(read.preampDB == -1.5)
        #expect(read.curve == curve)
    }

    @Test("Numbers are written with a dot and no trailing zeros")
    func numbers() {
        #expect(AutoEQExporter.number(42, decimals: 2) == "42")
        #expect(AutoEQExporter.number(0.930, decimals: 3) == "0.93")
        #expect(AutoEQExporter.number(-0.001, decimals: 2) == "0")
        #expect(AutoEQExporter.number(-2.15, decimals: 2) == "-2.15")
    }

    @Test("The file is named after the preset and its kind, without path separators")
    func fileName() {
        let preset = AutoEQProfile(id: "p", name: "HD 600 / warm: v2", source: .created, preampDB: 0, filters: [])
        #expect(AutoEQExporter.fileName(for: preset) == "HD 600 - warm- v2 ParametricEQ.txt")
    }
}
