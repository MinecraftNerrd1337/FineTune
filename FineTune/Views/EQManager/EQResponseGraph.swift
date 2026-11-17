// FineTune/Views/EQManager/EQResponseGraph.swift
import SwiftUI

/// Frequency response graph of a preset: log frequency axis (20 Hz to 20 kHz), dB axis,
/// the summed curve, the preamp level and one point per band, numbered by frequency.
///
/// Layout ideas (decade/minor grid tiers, knob on a stem from 0 dB, drag by offset from
/// the grab point) come from iQualize's `EQCanvasView` (MIT, Darius). This version keeps
/// a plainer style for legibility: stronger grid, labels outside the plot, no glow or fills.
@MainActor
struct EQResponseGraph: View {
    let profile: AutoEQProfile
    /// Half-range of the dB axis (12 or 24).
    let scaleDB: Double
    @Binding var selectedBand: Int?
    /// Bands can be dragged (frequency and gain) when true.
    let isEditable: Bool
    var onDragBegan: () -> Void = {}
    var onDrag: (_ band: Int, _ frequency: Double, _ gainDB: Float) -> Void = { _, _, _ in }
    var onDragEnded: () -> Void = {}

    /// How the preamp is drawn. `.peakLimit` (default) mirrors it above 0 dB: the curve should
    /// stay under that line. `.gainLevel` draws it at its own (negative) level.
    var preampMarker: PreampMarker = .peakLimit

    enum PreampMarker {
        case peakLimit, gainLevel
    }

    @State private var hoveredBand: Int?
    @State private var drag: DragInfo?

    private struct DragInfo {
        let band: Int
        let startFrequency: Double
        let startGain: Double
        var isMoving = false
    }

    private static let insets = EdgeInsets(top: 8, leading: 44, bottom: 22, trailing: 12)
    private static let curvePointCount = 400
    private static let hitRadius: CGFloat = 12

    private static let minorFrequencies: [Double] = [
        30, 40, 50, 60, 70, 80, 90,
        200, 300, 400, 500, 600, 700, 800, 900,
        2000, 3000, 4000, 5000, 6000, 7000, 8000, 9000,
    ]
    private static let decadeFrequencies: [Double] = [100, 1000, 10_000]
    private static let labeledFrequencies: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10_000, 20_000]

    var body: some View {
        GeometryReader { proxy in
            let plot = Self.plotRect(in: proxy.size)
            ZStack {
                Canvas { context, size in
                    draw(into: &context, plot: Self.plotRect(in: size))
                }
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { handleDragChanged($0, plot: plot) }
                            .onEnded { _ in handleDragEnded() }
                    )
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): hoveredBand = nearestBand(to: point, plot: plot)
                        case .ended: hoveredBand = nil
                        }
                    }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Frequency response of \(profile.name)")
    }

    // MARK: - Geometry

    private static func plotRect(in size: CGSize) -> CGRect {
        CGRect(
            x: insets.leading,
            y: insets.top,
            width: max(1, size.width - insets.leading - insets.trailing),
            height: max(1, size.height - insets.top - insets.bottom)
        )
    }

    private static let logMin = log10(AutoEQResponse.minFrequency)
    private static let logMax = log10(AutoEQResponse.maxFrequency)

    private func x(for frequency: Double, in plot: CGRect) -> CGFloat {
        let t = (log10(max(frequency, 1)) - Self.logMin) / (Self.logMax - Self.logMin)
        return plot.minX + CGFloat(t) * plot.width
    }

    private func frequency(atX x: CGFloat, in plot: CGRect) -> Double {
        let t = Double((x - plot.minX) / plot.width)
        return pow(10, Self.logMin + t * (Self.logMax - Self.logMin))
    }

    private func y(for db: Double, in plot: CGRect) -> CGFloat {
        plot.midY - CGFloat(db / scaleDB) * plot.height / 2
    }

    private func gain(atY y: CGFloat, in plot: CGRect) -> Double {
        Double((plot.midY - y) / (plot.height / 2)) * scaleDB
    }

    private func knobPoint(for filter: AutoEQFilter, in plot: CGRect) -> CGPoint {
        let clampedGain = min(max(Double(filter.gainDB), -scaleDB), scaleDB)
        return CGPoint(x: x(for: filter.frequency, in: plot), y: y(for: clampedGain, in: plot))
    }

    // MARK: - Drawing

    private func draw(into context: inout GraphicsContext, plot: CGRect) {
        drawGrid(into: &context, plot: plot)

        context.drawLayer { layer in
            layer.clip(to: Path(plot))
            if profile.kind == .graphic {
                drawGraphicPlaceholder(into: &layer, plot: plot)
                return
            }
            drawPreamp(into: &layer, plot: plot)
            if let band = selectedBand ?? hoveredBand, profile.filters.indices.contains(band) {
                drawSingleBand(profile.filters[band], into: &layer, plot: plot)
            }
            drawCurve(into: &layer, plot: plot)
        }

        if profile.kind == .parametric {
            drawKnobs(into: &context, plot: plot)
            drawReadout(into: &context, plot: plot)
        }
    }

    private func drawGrid(into context: inout GraphicsContext, plot: CGRect) {
        context.fill(Path(plot), with: .color(.primary.opacity(0.03)))

        for f in Self.minorFrequencies {
            let px = x(for: f, in: plot)
            context.stroke(line(from: CGPoint(x: px, y: plot.minY), to: CGPoint(x: px, y: plot.maxY)),
                           with: .color(.primary.opacity(0.10)), lineWidth: 0.5)
        }
        for f in Self.decadeFrequencies {
            let px = x(for: f, in: plot)
            context.stroke(line(from: CGPoint(x: px, y: plot.minY), to: CGPoint(x: px, y: plot.maxY)),
                           with: .color(.primary.opacity(0.24)), lineWidth: 1)
        }

        let step: Double = scaleDB <= 12 ? 3 : 6
        var db = -scaleDB
        while db <= scaleDB + 0.001 {
            let py = y(for: db, in: plot)
            let isZero = abs(db) < 0.001
            let isMajor = abs(db.truncatingRemainder(dividingBy: step * 2)) < 0.001
            context.stroke(line(from: CGPoint(x: plot.minX, y: py), to: CGPoint(x: plot.maxX, y: py)),
                           with: .color(.primary.opacity(isZero ? 0.45 : isMajor ? 0.20 : 0.10)),
                           lineWidth: isZero ? 1 : 0.5)
            let label = isZero ? "0 dB" : String(format: "%+.0f", db)
            context.draw(
                Text(label).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary),
                at: CGPoint(x: plot.minX - 6, y: py),
                anchor: .trailing
            )
            db += step
        }

        context.stroke(Path(plot), with: .color(.primary.opacity(0.24)), lineWidth: 1)

        for f in Self.labeledFrequencies {
            let px = x(for: f, in: plot)
            let isFirst = f == Self.labeledFrequencies.first
            let isLast = f == Self.labeledFrequencies.last
            let label = isFirst ? "20 Hz" : isLast ? "20 kHz" : f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))"
            context.draw(
                Text(label).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary),
                at: CGPoint(x: px, y: plot.maxY + 11),
                anchor: isFirst ? .leading : isLast ? .trailing : .center
            )
        }
    }

    private func drawCurve(into context: inout GraphicsContext, plot: CGRect) {
        let frequencies = AutoEQResponse.logFrequencies(count: Self.curvePointCount)
        let gains = AutoEQResponse.curve(profile.filters, engine: profile.engine, frequencies: frequencies)
        context.stroke(
            polyline(frequencies: frequencies, gains: gains, plot: plot),
            with: .color(.accentColor),
            style: StrokeStyle(lineWidth: 2, lineJoin: .round)
        )
    }

    private func drawSingleBand(_ filter: AutoEQFilter, into context: inout GraphicsContext, plot: CGRect) {
        let frequencies = AutoEQResponse.logFrequencies(count: Self.curvePointCount / 2)
        let gains = AutoEQResponse.curve(of: filter, engine: profile.engine, frequencies: frequencies)
        context.stroke(
            polyline(frequencies: frequencies, gains: gains, plot: plot),
            with: .color(.accentColor.opacity(0.6)),
            style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])
        )
    }

    private func drawPreamp(into context: inout GraphicsContext, plot: CGRect) {
        let preamp = Double(profile.preampDB)
        guard abs(preamp) >= 0.05 else { return }
        let level = preampMarker == .peakLimit ? -preamp : preamp
        guard abs(level) <= scaleDB else { return }
        let py = y(for: level, in: plot)
        context.stroke(
            line(from: CGPoint(x: plot.minX, y: py), to: CGPoint(x: plot.maxX, y: py)),
            with: .color(.primary.opacity(0.6)),
            style: StrokeStyle(lineWidth: 1, dash: [6, 4])
        )
        let label = preampMarker == .peakLimit
            ? String(format: "Preamp %+.1f dB · peak limit %+.1f dB", preamp, level)
            : String(format: "Preamp %+.1f dB", preamp)
        context.draw(
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.75)),
            at: CGPoint(x: plot.maxX - 6, y: level >= 0 ? py - 3 : py + 3),
            anchor: level >= 0 ? .bottomTrailing : .topTrailing
        )
    }

    private func drawKnobs(into context: inout GraphicsContext, plot: CGRect) {
        let zeroY = y(for: 0, in: plot)
        let showsAllNumbers = profile.filters.count <= 24
        let knobFill = Color(nsColor: .windowBackgroundColor)
        let numbers = Self.bandNumbers(profile.filters)

        for (index, filter) in profile.filters.enumerated() {
            let point = knobPoint(for: filter, in: plot)
            let isActive = index == selectedBand || index == hoveredBand || index == drag?.band
            let radius: CGFloat = isActive ? 7 : 5.5

            context.stroke(line(from: CGPoint(x: point.x, y: zeroY), to: point),
                           with: .color(.accentColor.opacity(isActive ? 0.7 : 0.35)), lineWidth: 1.5)

            let knob = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
            context.fill(knob, with: .color(isActive ? .accentColor : knobFill))
            context.stroke(knob, with: .color(.accentColor), lineWidth: isActive ? 2 : 1.5)

            if showsAllNumbers || isActive {
                // Number on the side away from the stem.
                let above = filter.gainDB >= 0
                context.draw(
                    Text("\(numbers[index])")
                        .font(.system(size: 9, weight: isActive ? .bold : .medium).monospacedDigit())
                        .foregroundStyle(isActive ? Color.primary : Color.secondary),
                    at: CGPoint(x: point.x, y: above ? point.y - radius - 2 : point.y + radius + 2),
                    anchor: above ? .bottom : .top
                )
            }
        }
    }

    /// Details of the hovered (or selected) band, in the top-left corner of the plot.
    private func drawReadout(into context: inout GraphicsContext, plot: CGRect) {
        guard let band = hoveredBand ?? selectedBand, profile.filters.indices.contains(band) else { return }
        let filter = profile.filters[band]
        let text = context.resolve(
            Text("Band \(Self.bandNumbers(profile.filters)[band]) · \(Self.typeName(filter.type)) · \(Self.formatFrequency(filter.frequency)) · "
                 + String(format: "%+.1f dB · Q %.2f", filter.gainDB, filter.q))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary)
        )
        let size = text.measure(in: plot.size)
        let box = CGRect(x: plot.minX + 6, y: plot.minY + 6, width: size.width + 12, height: size.height + 6)
        let shape = Path(roundedRect: box, cornerRadius: 5)
        context.fill(shape, with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
        context.stroke(shape, with: .color(.primary.opacity(0.2)), lineWidth: 0.5)
        context.draw(text, at: CGPoint(x: box.minX + 6, y: box.midY), anchor: .leading)
    }

    private func drawGraphicPlaceholder(into context: inout GraphicsContext, plot: CGRect) {
        context.draw(
            Text("Graphic EQ curves are not displayed yet")
                .font(.system(size: 11))
                .foregroundStyle(.secondary),
            at: CGPoint(x: plot.midX, y: plot.midY - 14),
            anchor: .center
        )
    }

    private func line(from start: CGPoint, to end: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        return path
    }

    private func polyline(frequencies: [Double], gains: [Double], plot: CGRect) -> Path {
        var path = Path()
        for (i, f) in frequencies.enumerated() {
            let point = CGPoint(x: x(for: f, in: plot), y: y(for: gains[i], in: plot))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    // MARK: - Interaction

    private func nearestBand(to point: CGPoint, plot: CGRect) -> Int? {
        guard profile.kind == .parametric else { return nil }
        var best: (index: Int, distance: CGFloat)?
        for (index, filter) in profile.filters.enumerated() {
            let knob = knobPoint(for: filter, in: plot)
            let distance = hypot(knob.x - point.x, knob.y - point.y)
            if distance <= Self.hitRadius, distance < (best?.distance ?? .infinity) {
                best = (index, distance)
            }
        }
        return best?.index
    }

    private func handleDragChanged(_ value: DragGesture.Value, plot: CGRect) {
        if drag == nil {
            let hit = nearestBand(to: value.startLocation, plot: plot)
            selectedBand = hit
            guard isEditable, let hit else { return }
            let filter = profile.filters[hit]
            drag = DragInfo(band: hit, startFrequency: filter.frequency, startGain: Double(filter.gainDB))
        }
        guard var info = drag else { return }

        // Ignore the first pixels so a click selects a band without moving it.
        if !info.isMoving {
            guard hypot(value.translation.width, value.translation.height) >= 3 else { return }
            info.isMoving = true
            drag = info
            onDragBegan()
        }

        // Move by the pointer's offset from where the band was grabbed, so it does not jump.
        let startX = x(for: info.startFrequency, in: plot)
        let startY = y(for: info.startGain, in: plot)
        let newX = min(max(startX + value.translation.width, plot.minX), plot.maxX)
        let newY = min(max(startY + value.translation.height, plot.minY), plot.maxY)

        let range = AutoEQFilter.frequencyRange
        let rawFrequency = min(max(frequency(atX: newX, in: plot), range.lowerBound), range.upperBound)
        let newFrequency = rawFrequency < 1000 ? rawFrequency.rounded() : (rawFrequency / 10).rounded() * 10
        let newGain = Float((gain(atY: newY, in: plot) * 10).rounded() / 10)
        onDrag(info.band, newFrequency, newGain)
    }

    private func handleDragEnded() {
        if drag?.isMoving == true {
            onDragEnded()
        }
        drag = nil
    }

    // MARK: - Band Order

    /// Storage indices sorted by frequency (lowest first).
    static func frequencyOrder(_ filters: [AutoEQFilter]) -> [Int] {
        filters.indices.sorted { a, b in
            filters[a].frequency != filters[b].frequency ? filters[a].frequency < filters[b].frequency : a < b
        }
    }

    /// Display number of each band (1 = lowest frequency), by storage index.
    static func bandNumbers(_ filters: [AutoEQFilter]) -> [Int] {
        var numbers = [Int](repeating: 0, count: filters.count)
        for (rank, index) in frequencyOrder(filters).enumerated() {
            numbers[index] = rank + 1
        }
        return numbers
    }

    // MARK: - Formatting

    static func typeName(_ type: AutoEQFilter.FilterType) -> String {
        switch type {
        case .peaking: return "Peak"
        case .lowShelf: return "Low shelf"
        case .highShelf: return "High shelf"
        }
    }

    static func formatFrequency(_ hz: Double) -> String {
        if hz >= 1000 {
            let khz = hz / 1000
            return khz >= 10 ? String(format: "%.1f kHz", khz) : String(format: "%.2f kHz", khz)
        }
        return String(format: "%.0f Hz", hz)
    }
}
