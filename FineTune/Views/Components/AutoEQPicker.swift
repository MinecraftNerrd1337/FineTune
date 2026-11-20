// FineTune/Views/Components/AutoEQPicker.swift
import SwiftUI

/// Icon-only button that opens a popover for selecting AutoEQ headphone correction profiles.
/// Follows the same pattern as the EQ toggle button in `AppRowControls`.
struct AutoEQPicker: View {
    let menu: AutoEQDeviceMenu
    /// Offers "Open EQ Manager..." in the popover (not from the EQ Manager itself).
    var showsManagerButton = true

    @State private var isExpanded = false
    @State private var isButtonHovered = false

    @Environment(\.appearancePreference) private var appearancePreference

    // MARK: - Layout Constants

    private let popoverWidth: CGFloat = 260

    // MARK: - Computed

    private var iconColor: Color {
        if isExpanded {
            return DesignTokens.Colors.accentPrimary
        } else if menu.selection != nil || menu.profileName != nil {
            // Dim when profile assigned but correction disabled
            return menu.isCorrectionEnabled
                ? DesignTokens.Colors.accentPrimary
                : DesignTokens.Colors.interactiveDefault
        } else if isButtonHovered {
            return DesignTokens.Colors.interactiveHover
        }
        return DesignTokens.Colors.interactiveDefault
    }

    // MARK: - Body

    var body: some View {
        triggerButton
            .background(
                PopoverHost(
                    isPresented: $isExpanded,
                    preferredColorScheme: appearancePreference.swiftUIColorScheme,
                    nsAppearance: appearancePreference.nsAppearance
                ) {
                    popoverContent
                }
            )
    }

    // MARK: - Trigger Button

    private var triggerButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            Image(systemName: "wand.and.sparkles")
                .font(.system(size: 16))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconColor)
                .frame(
                    minWidth: DesignTokens.Dimensions.minTouchTarget,
                    minHeight: DesignTokens.Dimensions.minTouchTarget
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isButtonHovered = $0 }
        .help(isExpanded ? "Close AutoEQ" : "AutoEQ correction")
        .animation(DesignTokens.Animation.hover, value: isButtonHovered)
    }

    // MARK: - Popover Content

    private var popoverContent: some View {
        VStack(spacing: 0) {
            AutoEQSearchPanel(
                menu: menu,
                showsManagerButton: showsManagerButton,
                onSelect: { profile in
                    menu.onSelect(profile)
                    withAnimation(.easeOut(duration: 0.15)) {
                        isExpanded = false
                    }
                },
                onDismiss: {
                    withAnimation(.easeOut(duration: 0.15)) {
                        isExpanded = false
                    }
                }
            )
        }
        .frame(width: popoverWidth)
        .background(
            VisualEffectBackground(material: .menu, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(DesignTokens.Colors.glassBorder, lineWidth: 0.5)
        }
    }
}
