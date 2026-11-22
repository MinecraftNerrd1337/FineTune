// FineTune/Views/EQManager/EQGraphScale.swift
import AppKit
import SwiftUI

/// The dB window of the EQ Manager's response graph: its scale (±`span` around its middle) and
/// the level at its middle, in whole dB, never past ±24 dB. Every control of the graph (the
/// scale slider and field, the editable top, middle and bottom levels, ⌘-scroll and ⌘-drag) sets
/// it through these setters, which keep it in bounds, so they can never disagree.
struct EQGraphScale: Equatable {
    /// The window never goes past ±24 dB.
    static let limitDB = 24
    static let spanRange = 1...limitDB

    private(set) var span: Int
    private(set) var center: Int

    init(span: Int = 12, center: Int = 0) {
        self.span = Self.clamp(span, to: Self.spanRange)
        self.center = 0
        setCenter(center)
    }

    var top: Int { center + span }
    var bottom: Int { center - span }

    /// The middle levels the scale allows: at ±12 dB, from −12 to +12 dB.
    var centerRange: ClosedRange<Int> { (span - Self.limitDB)...(Self.limitDB - span) }
    var topRange: ClosedRange<Int> { (2 * span - Self.limitDB)...Self.limitDB }
    var bottomRange: ClosedRange<Int> { -Self.limitDB...(Self.limitDB - 2 * span) }

    /// Changes the scale around the middle level, which moves only as far as the window needs
    /// to stay within ±24 dB.
    mutating func setSpan(_ value: Int) {
        span = Self.clamp(value, to: Self.spanRange)
        center = Self.clamp(center, to: centerRange)
    }

    /// Each setter of a level moves the window, keeping its scale. A level past what the scale
    /// allows stops at the nearest one.
    mutating func setCenter(_ value: Int) {
        center = Self.clamp(value, to: centerRange)
    }

    mutating func setTop(_ value: Int) {
        setCenter(Self.clamp(value, to: topRange) - span)
    }

    mutating func setBottom(_ value: Int) {
        setCenter(Self.clamp(value, to: bottomRange) + span)
    }

    /// Moves the window up (positive) or down by whole dB.
    mutating func scroll(by delta: Int) {
        setCenter(center + delta)
    }

    /// Spacing of the grid lines, in dB: two to five lines on each side of the middle.
    var gridStepDB: Int {
        switch span {
        case ...4: return 1
        case ...8: return 2
        case ...15: return 3
        default: return 6
        }
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

// MARK: - Number Field

/// A whole number of dB typed in place, for the graph's scale and levels. Committed on Return
/// or a click anywhere else, within `range` (a number past it stops at its nearest bound), and
/// left as it was on Escape. Unless it is being typed in, it shows `value`, so it can never
/// disagree with what it sets. The axis style is a pill until clicked.
struct EQScaleNumberField: View {
    enum Style {
        /// Always a text field (the scale).
        case field
        /// A level of the axis: a pill until clicked, signed, 0 reading "0 dB".
        case axisLabel
    }

    let value: Int
    let range: ClosedRange<Int>
    var style: Style = .field
    var width: CGFloat = 38
    /// Tints the pill: the middle level, so the center of the graph shows at any level.
    var isEmphasized = false
    let onCommit: (Int) -> Void

    @State private var draft = ""
    @State private var isEditing = false
    @State private var isHovered = false
    /// Escape was pressed: the focus goes without committing.
    @State private var isCancelled = false
    @State private var clickMonitor: Any?
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if style == .field || isEditing {
                textField
            } else {
                label
            }
        }
        .onAppear { draft = text(value) }
        // Set from elsewhere (the slider, another level, a scroll): the field follows at once
        .onChange(of: value) { _, newValue in draft = text(newValue) }
        .onChange(of: isFocused) { _, focused in focusChanged(focused) }
        .onDisappear { removeClickMonitor() }
    }

    /// A pill, so the levels that can be typed in stand out from the axis' other levels.
    private var label: some View {
        let tint = isEmphasized ? Color.accentColor : Color.primary
        return Text(value == 0 ? "0 dB" : text(value))
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(isEmphasized ? Color.accentColor : Color.primary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(isHovered ? 0.22 : 0.12)))
            .overlay(Capsule().strokeBorder(tint.opacity(isHovered ? 0.5 : 0.3), lineWidth: 0.5))
            .frame(width: width, alignment: .trailing)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture {
                draft = text(value)
                isEditing = true
            }
            .help("Click to type a level")
    }

    private var textField: some View {
        TextField("", text: $draft)
            .textFieldStyle(.roundedBorder)
            .controlSize(style == .axisLabel ? .mini : .small)
            .font(.system(size: style == .axisLabel ? 10 : 11).monospacedDigit())
            .multilineTextAlignment(.trailing)
            .frame(width: width)
            .focused($isFocused)
            .onChange(of: draft) { _, typed in
                let kept = Self.wholeNumberCharacters(typed)
                if kept != typed { draft = kept }
            }
            .onSubmit {
                commit()
                if style == .axisLabel { endEditing() }
            }
            .onExitCommand {
                isCancelled = true
                draft = text(value)
                if style == .axisLabel { endEditing() } else { isFocused = false }
            }
            .task {
                // An axis level opens focused, to type at once
                if style == .axisLabel { isFocused = true }
            }
    }

    // MARK: - Editing

    private func focusChanged(_ focused: Bool) {
        if focused {
            installClickMonitor()
            return
        }
        removeClickMonitor()
        if isCancelled {
            isCancelled = false
        } else {
            commit()
        }
        isEditing = false
    }

    private func endEditing() {
        removeClickMonitor()
        isFocused = false
        isEditing = false
    }

    /// Sends the number typed, kept within `range`; anything else goes back to the value.
    private func commit() {
        guard let typed = Self.number(in: draft) else {
            draft = text(value)
            return
        }
        let committed = min(max(typed, range.lowerBound), range.upperBound)
        // Shown at once, also when it does not change the value
        draft = text(committed)
        if committed != value { onCommit(committed) }
    }

    private func text(_ number: Int) -> String {
        style == .axisLabel && number > 0 ? "+\(number)" : "\(number)"
    }

    /// The digits typed, and a sign in front.
    static func wholeNumberCharacters(_ typed: String) -> String {
        var kept = ""
        for (index, character) in typed.enumerated() {
            if character.isASCII && character.isNumber {
                kept.append(character)
            } else if index == 0 && (character == "+" || character == "-" || character == "−") {
                kept.append(character == "−" ? "-" : character)
            }
        }
        return kept
    }

    /// The whole number typed, if there is one.
    static func number(in typed: String) -> Int? {
        Int(wholeNumberCharacters(typed))
    }

    // MARK: - Click Outside

    /// SwiftUI leaves a field focused when a click lands on something that takes no focus, such
    /// as the graph: a click outside the field ends the typing there, as Return does.
    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            Self.endTyping(onClickOutside: event)
            return event
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    private static func endTyping(onClickOutside event: NSEvent) {
        guard let window = event.window,
              let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSView,
              let contentView = window.contentView else { return }
        // hitTest takes a point in the coordinates of the view's superview
        let point = contentView.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        if let hit = contentView.hitTest(point), hit === field || hit.isDescendant(of: field) { return }
        window.makeFirstResponder(nil)
    }
}
