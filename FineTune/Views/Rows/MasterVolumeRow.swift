// FineTune/Views/Rows/MasterVolumeRow.swift
import SwiftUI

/// Software master volume, applied as the last stage of every tap, right before the device.
/// 100% leaves the audio untouched; 0% silences all apps. Lets the user go quieter
/// than the lowest hardware step of the output device.
struct MasterVolumeRow: View {
    let volume: Float
    let onVolumeChange: (Float) -> Void

    @State private var dragOverrideValue: Double?

    private var sliderValue: Double {
        dragOverrideValue ?? VolumeMapping.gainToSlider(volume)
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { sliderValue },
            set: { newValue in
                dragOverrideValue = newValue
                onVolumeChange(VolumeMapping.sliderToGain(newValue))
            }
        )
    }

    private var displayedPercentage: Int { Int(round(sliderValue * 100)) }

    var body: some View {
        MasterRowLayout(
            spacing: DesignTokens.Spacing.sm,
            containerInset: DesignTokens.Spacing.sm,
            verticalInset: DesignTokens.Spacing.xs,
            trailingInset: DesignTokens.Spacing.sm,
            glassTrailingMargin: 1,
            contentHeight: DesignTokens.Dimensions.rowContentHeight
        ) {
            // 0: glass container (sized and placed by the layout)
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius, style: .continuous)
                .fill(Color.white.opacity(0.001))
                .glassContainer()

            // 1: label, right-aligned in the left half so it sits next to the speaker button
            Text("Master vol")
                .font(DesignTokens.Typography.rowName)
                .lineLimit(1)
                .fixedSize()

            // 2: speaker / mute
            MuteButton(isMuted: displayedPercentage == 0, levelFraction: sliderValue) {
                onVolumeChange(displayedPercentage == 0 ? 1.0 : 0.0)
            }

            // 3: slider
            LiquidGlassSlider(
                value: sliderBinding,
                showUnityMarker: false,
                onEditingChanged: { editing in
                    if !editing { dragOverrideValue = nil }
                }
            )
            .opacity(displayedPercentage == 0 ? 0.5 : 1.0)
            .scrollWheelStep(sliderBinding, in: 0.0...1.0)

            // 4: percentage
            EditablePercentage(
                percentage: Binding(
                    get: { displayedPercentage },
                    set: { newPercentage in
                        onVolumeChange(VolumeMapping.sliderToGain(Double(newPercentage) / 100.0))
                    }
                ),
                range: 0...100
            )
        }
        .help("Software master volume: applies on top of every app and the device volume")
    }
}

/// Lays the master row out like a `DeviceRow`: the label area and the slider split the space
/// left by the speaker button and the percentage equally, so the slider has the device slider
/// length. The glass container (first subview) starts `containerInset` before the label text
/// and ends `glassTrailingMargin` short of the trailing edge, `verticalInset` taller than the
/// controls. The margin keeps the container's border from being clipped at the edge.
private struct MasterRowLayout: Layout {
    let spacing: CGFloat
    let containerInset: CGFloat
    let verticalInset: CGFloat
    /// Space between the percentage and the trailing edge, as in a device row.
    let trailingInset: CGFloat
    let glassTrailingMargin: CGFloat
    let contentHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 400, height: contentHeight + 2 * verticalInset)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 5 else { return }
        let glass = subviews[0], label = subviews[1], mute = subviews[2]
        let slider = subviews[3], percentage = subviews[4]

        let labelSize = label.sizeThatFits(.unspecified)
        let muteSize = mute.sizeThatFits(.unspecified)
        let percentageSize = percentage.sizeThatFits(.unspecified)

        let contentWidth = bounds.width - trailingInset
        let remaining = max(0, contentWidth - muteSize.width - percentageSize.width - 3 * spacing)
        let halfWidth = remaining / 2
        let midY = bounds.midY

        let labelX = bounds.minX + max(0, halfWidth - labelSize.width)
        let muteX = bounds.minX + halfWidth + spacing
        let sliderX = muteX + muteSize.width + spacing
        let percentageX = sliderX + halfWidth + spacing

        let glassX = max(bounds.minX, labelX - containerInset)
        glass.place(
            at: CGPoint(x: glassX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.maxX - glassX - glassTrailingMargin, height: bounds.height)
        )
        label.place(at: CGPoint(x: labelX, y: midY), anchor: .leading, proposal: .unspecified)
        mute.place(at: CGPoint(x: muteX, y: midY), anchor: .leading, proposal: .unspecified)
        slider.place(
            at: CGPoint(x: sliderX, y: midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: halfWidth, height: contentHeight)
        )
        percentage.place(at: CGPoint(x: percentageX, y: midY), anchor: .leading, proposal: .unspecified)
    }
}
