import SwiftUI

/// An active call app whose audio is left under macOS control.
struct CallPassthroughAppRow: View {
    let app: AudioApp
    let isFocused: Bool
    let onAppActivate: () -> Void

    var body: some View {
        ExpandableGlassRow(isExpanded: false, isFocused: isFocused) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Button(action: onAppActivate) {
                    Image(nsImage: app.icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: DesignTokens.Dimensions.rowContentHeight - 4,
                               height: DesignTokens.Dimensions.rowContentHeight - 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(app.name)")

                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .font(DesignTokens.Typography.rowName)
                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                        .lineLimit(1)
                    Text("Microphone in use · Audio managed by macOS")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "mic.fill")
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
            .frame(height: DesignTokens.Dimensions.rowContentHeight)
            .help("Skip Apps on Calls is enabled in Settings → Audio. FineTune leaves this app untouched while it uses the microphone.")
        } expandedContent: {
            EmptyView()
        }
    }
}
