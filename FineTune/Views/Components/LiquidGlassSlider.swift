// FineTune/Views/Components/LiquidGlassSlider.swift
import SwiftUI

/// A slider using native SwiftUI Slider for Liquid Glass effect on macOS 26+
/// Styled to match the minimal track appearance of device sliders
struct LiquidGlassSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let showUnityMarker: Bool
    let fillColor: Color
    let trackColor: Color
    let trackHeight: CGFloat
    /// A level of 0 still shows a dot of fill; without it, only the track shows.
    let showsDotAtZero: Bool
    let onEditingChanged: ((Bool) -> Void)?

    @State private var isEditing = false
    @State private var isHovered = false

    /// Show thumb only when hovering or dragging
    private var showThumb: Bool {
        isHovered || isEditing
    }

    init(
        value: Binding<Double>,
        in range: ClosedRange<Double> = 0...1,
        showUnityMarker: Bool = false,
        fillColor: Color = DesignTokens.Colors.accentPrimary,
        trackColor: Color = DesignTokens.Colors.sliderTrack,
        trackHeight: CGFloat = 4,
        showsDotAtZero: Bool = true,
        onEditingChanged: ((Bool) -> Void)? = nil
    ) {
        self._value = value
        self.range = range
        self.showUnityMarker = showUnityMarker
        self.fillColor = fillColor
        self.trackColor = trackColor
        self.trackHeight = trackHeight
        self.showsDotAtZero = showsDotAtZero
        self.onEditingChanged = onEditingChanged
    }

    private var normalizedValue: Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Custom track overlay (always visible, hides native track)
                ZStack(alignment: .leading) {
                    // Track background
                    Capsule()
                        .fill(trackColor)
                        .frame(height: trackHeight)

                    // Filled track
                    if showsDotAtZero || normalizedValue > 0 {
                        Capsule()
                            .fill(fillColor)
                            .frame(width: max(trackHeight, geo.size.width * normalizedValue), height: trackHeight)
                    }
                }
                .frame(maxHeight: .infinity)
                .allowsHitTesting(false)

                // Unity marker at 50% (horizontally centered, vertically centered via frame)
                if showUnityMarker {
                    HStack {
                        Spacer()
                        Rectangle()
                            .fill(DesignTokens.Colors.unityMarker)
                            .frame(width: 1.5, height: 8)
                        Spacer()
                    }
                    .frame(maxHeight: .infinity)
                    .allowsHitTesting(false)
                }

                // Native SwiftUI Slider - gets Liquid Glass thumb on macOS 26+
                // Thumb only visible on hover/drag
                Slider(value: $value, in: range) { editing in
                    isEditing = editing
                    onEditingChanged?(editing)
                }
                .controlSize(.mini)
                .tint(.clear)  // Hide native track, we draw our own
                .opacity(showThumb ? 1 : 0.01)  // Nearly invisible when not hovered, but still interactive
            }
        }
        .frame(height: DesignTokens.Dimensions.sliderThumbHeight)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Preview

#Preview("Liquid Glass Slider") {
    struct PreviewWrapper: View {
        @State private var value: Double = 0.5

        var body: some View {
            VStack(spacing: 30) {
                LiquidGlassSlider(value: $value, showUnityMarker: true)
                    .frame(width: 200)

                Text("\(Int(value * 200))%")
                    .foregroundStyle(.secondary)
            }
            .padding(40)
            .background(Color.black)
        }
    }
    return PreviewWrapper()
}
