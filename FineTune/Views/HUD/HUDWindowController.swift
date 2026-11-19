// FineTune/Views/HUD/HUDWindowController.swift
import AppKit
import SwiftUI
import os

/// Owns the on-screen volume HUD panel and its auto-hide timing.
@MainActor
final class HUDWindowController: MediaKeyHUDPresenting {
    private let settingsManager: SettingsManager
    private let mediaKeyStatus: MediaKeyStatus
    private let panelVisibility: PanelVisibilityService
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "HUDWindowController")

    // Read from the nonisolated deinit, which hands them to the main thread.
    private nonisolated(unsafe) var panel: NSPanel?
    private var backdrop: HUDBackdropView?
    private var hostingView: NSHostingView<AnyView>?
    private var hideTask: Task<Void, Never>?
    private var styleAtLastShow: HUDStyle = .tahoe

    /// Slider fraction in [0, 1]. The wiring site converts to gain using the current device's tier.
    var volumeWriter: ((Double) -> Void)?

    /// What a device HUD shows
    struct DeviceState: Equatable {
        let sliderFraction: Double
        let mute: Bool
        let deviceName: String
    }

    /// The device HUD on screen, nil while the HUD is hidden or shows an app
    private var shownDevice: DeviceState?
    /// Reads the default output device's state, observed while it is followed
    private var deviceStateReader: (@MainActor () -> DeviceState?)?
    private var isHovering = false
    /// Bumped by each show, so a fade-out still running doesn't take the HUD away after it
    private var presentation = 0

    // MARK: - Suppression-degraded tracking

    private var lastSwallowedKeyTime: DispatchTime?
    private nonisolated(unsafe) var settingsChangedObserver: NSObjectProtocol?

    var hideDelayOverride: Duration?
    var frameProvider: () -> NSRect? = { NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame }
    private(set) var showCallCount: Int = 0
    private(set) var showDidUpdatePanel: Bool = false

    init(
        settingsManager: SettingsManager,
        mediaKeyStatus: MediaKeyStatus,
        panelVisibility: PanelVisibilityService
    ) {
        self.settingsManager = settingsManager
        self.mediaKeyStatus = mediaKeyStatus
        self.panelVisibility = panelVisibility
        subscribeToSettingsChangedNotification()
    }

    deinit {
        // Prefer shutdown() for synchronous teardown during willTerminate; this
        // deinit safety-net only fires for objects released without that call.
        let observer = settingsChangedObserver
        let panel = panel
        MainThreadCleanup.run {
            if let observer {
                DistributedNotificationCenter.default().removeObserver(observer)
            }
            // MainThreadCleanup runs its work on the main thread, which the compiler cannot see
            MainActor.assumeIsolated { panel?.orderOut(nil) }
        }
    }

    /// Synchronous teardown for `willTerminate` — hides without animation.
    func shutdown() {
        hideTask?.cancel()
        hideTask = nil
        if let panel, panel.isVisible {
            panel.orderOut(nil)
        }
    }

    // MARK: - Style-indexed hide delay

    func hideDelay(for style: HUDStyle) -> Duration {
        if let override = hideDelayOverride { return override }
        return .milliseconds(1100)
    }

    // MARK: - Public API

    /// Displays the HUD. Skipped when the foreground app is fullscreen or the menu bar panel is visible.
    func show(sliderFraction: Double, mute: Bool, deviceName: String) {
        showCallCount += 1
        showDidUpdatePanel = false
        shownDevice = nil

        guard !isForegroundAppFullscreen() else {
            logger.debug("Skipping HUD show: foreground app is fullscreen")
            return
        }
        guard !panelVisibility.isVisible else {
            logger.debug("Skipping HUD show: menu bar panel is visible")
            return
        }

        let style = settingsManager.appSettings.hudStyle
        let appearance = settingsManager.appSettings.appearance
        styleAtLastShow = style
        let panel = ensurePanel()
        ensureBackdrop(in: panel)
        // Refresh on every show so a preference change between invocations
        // takes effect immediately.
        panel.appearance = appearance.nsAppearance

        // Classic is click-through; Tahoe takes mouse events for drag + hover.
        panel.ignoresMouseEvents = (style == .classic)

        let scheme = appearance.swiftUIColorScheme
        let displayFraction = Float(max(0, min(1, sliderFraction)))
        let onSliderChange: (Float) -> Void = { [weak self] newFraction in
            self?.volumeWriter?(Double(newFraction))
        }
        let onHoverChange: (Bool) -> Void = { [weak self] hovering in
            self?.handleHoverChange(hovering)
        }
        let root: AnyView
        let size: NSSize
        switch style {
        case .tahoe:
            root = AnyView(
                TahoeStyleHUD(
                    sliderFraction: displayFraction,
                    mute: mute,
                    deviceName: deviceName,
                    onSliderChange: onSliderChange,
                    onHoverChange: onHoverChange
                )
                .preferredColorScheme(scheme)
            )
            size = NSSize(width: 300, height: 72)
            backdrop?.cornerRadius = TahoeStyleHUD.cornerRadius
        case .classic:
            root = AnyView(
                ClassicStyleHUD(sliderFraction: displayFraction, mute: mute)
                    .preferredColorScheme(scheme)
            )
            size = NSSize(width: 200, height: 200)
            backdrop?.cornerRadius = ClassicStyleHUD.cornerRadius
        }

        if let existing = hostingView {
            existing.rootView = root
        } else {
            let hv = NSHostingView(rootView: root)
            hv.frame = NSRect(origin: .zero, size: size)
            backdrop?.setContent(hv)
            hostingView = hv
        }
        showDidUpdatePanel = true

        place(panel, size: size, style: style)
        present(panel)

        shownDevice = DeviceState(sliderFraction: sliderFraction, mute: mute, deviceName: deviceName)
        // Under the pointer, the HUD stays until the pointer leaves it
        if !isHovering {
            scheduleHide(for: style)
        }
        postAccessibilityAnnouncement(panel: panel, sliderFraction: sliderFraction, mute: mute, deviceName: deviceName)
    }

    func showPerAppVolumeHUD(app: AudioApp, sliderFraction: Double) {
        presentPerApp(
            icon: app.icon,
            title: app.name,
            content: .volume(sliderFraction: max(0, min(1, sliderFraction)))
        )
    }

    func showPerAppMuteHUD(app: AudioApp, isMuted: Bool) {
        presentPerApp(
            icon: app.icon,
            title: app.name,
            content: .mute(isMuted: isMuted)
        )
    }

    func showPerAppNotControlledHUD(displayName: String?, bundleID: String?, icon: NSImage?) {
        let title = displayName?.nilIfEmpty
            ?? bundleID?.nilIfEmpty
            ?? "FineTune isn't controlling this app yet"
        presentPerApp(
            icon: icon,
            title: title,
            content: .notControlled
        )
    }

    /// Hotkey-triggered per-app HUDs bypass the fullscreen guard because the user explicitly invoked them.
    private func presentPerApp(icon: NSImage?, title: String, content: PerAppHUDContent) {
        showCallCount += 1
        showDidUpdatePanel = false
        shownDevice = nil
        isHovering = false

        guard !panelVisibility.isVisible else {
            logger.debug("Skipping per-app HUD: menu bar panel is visible")
            return
        }

        let appearance = settingsManager.appSettings.appearance
        styleAtLastShow = .tahoe
        let panel = ensurePanel()
        ensureBackdrop(in: panel)
        panel.appearance = appearance.nsAppearance
        panel.ignoresMouseEvents = true

        let scheme = appearance.swiftUIColorScheme
        let root = AnyView(
            PerAppHUD(icon: icon, title: title, content: content)
                .preferredColorScheme(scheme)
        )
        let size = NSSize(width: 300, height: 72)
        backdrop?.cornerRadius = PerAppHUD.cornerRadius

        if let existing = hostingView {
            existing.rootView = root
        } else {
            let hv = NSHostingView(rootView: root)
            hv.frame = NSRect(origin: .zero, size: size)
            backdrop?.setContent(hv)
            hostingView = hv
        }
        showDidUpdatePanel = true

        place(panel, size: size, style: .tahoe)
        present(panel)

        scheduleHide(for: .tahoe)
        postPerAppAccessibilityAnnouncement(panel: panel, title: title, content: content)
    }

    /// Keeps a device HUD on screen up to date with its device, whatever changes it: the
    /// device's own buttons, another app, macOS. `read` gives the default output device's state
    /// and is observed; a change shows in the HUD only while it is on screen for that device.
    func followDeviceState(_ read: @escaping @MainActor () -> DeviceState?) {
        deviceStateReader = read
        observeDeviceState()
    }

    private func observeDeviceState() {
        guard let read = deviceStateReader else { return }
        withObservationTracking {
            _ = read()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshShownDevice()
                self.observeDeviceState()
            }
        }
    }

    private func refreshShownDevice() {
        guard let shown = shownDevice, let panel, panel.isVisible,
              let state = deviceStateReader?(), state.deviceName == shown.deviceName else { return }
        // The level FineTune itself just set comes back through the gain, a hair off
        guard state.mute != shown.mute || abs(state.sliderFraction - shown.sliderFraction) >= 0.001 else { return }
        // Shown again with the new state, which also keeps it up a moment longer
        show(sliderFraction: state.sliderFraction, mute: state.mute, deviceName: state.deviceName)
    }

    /// Called when the monitor swallows a keypress; used to detect if the native HUD still fired.
    func swallowObserved() {
        lastSwallowedKeyTime = DispatchTime.now()
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        shownDevice = nil
        isHovering = false
        guard let panel, panel.isVisible else { return }
        let fadingOut = presentation
        let duration = reduceMotionEnabled() ? 0.08 : 0.11
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Shown again meanwhile: it stays
                guard self?.presentation == fadingOut else { return }
                panel.orderOut(nil)
            }
        })
    }

    /// Sizes the window around the HUD, with room for the glass's edge, at the HUD's place
    private func place(_ panel: NSPanel, size: NSSize, style: HUDStyle) {
        let inset = backdrop?.inset ?? 0
        let origin = position(for: style, size: size)
        let frame = NSRect(
            x: origin.x - inset, y: origin.y - inset,
            width: size.width + inset * 2, height: size.height + inset * 2
        )
        panel.setFrame(frame, display: false)
        refreshShadow(of: panel)
    }

    /// Puts the HUD on screen, or keeps it there, and hands it to the window server at once, so
    /// it doesn't wait for the volume change the caller makes next. It shows whole from its first
    /// frame, with no fade-in, so it is drawn before it is ordered in: the window still holds the
    /// last HUD it showed.
    private func present(_ panel: NSPanel) {
        presentation += 1
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        if !panel.isVisible {
            panel.alphaValue = 1.0
        } else if panel.alphaValue < 1 {
            // Takes over a fade-out still running, which setting the alpha wouldn't stop
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.05
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1.0
            }
        }
        panel.orderFrontRegardless()
        CATransaction.flush()
    }

    // MARK: - Position Math

    /// Tahoe: top-right. Classic: bottom-center. Under suppression-degraded,
    /// Tahoe shifts left so it doesn't overlap the native top-right HUD.
    static func computePosition(
        style: HUDStyle,
        size: NSSize,
        visibleFrame: NSRect,
        suppressionDegraded: Bool
    ) -> NSPoint {
        switch style {
        case .tahoe:
            if suppressionDegraded {
                let x = visibleFrame.minX + visibleFrame.width * 0.25 - size.width / 2
                let y = visibleFrame.maxY - size.height - 8
                return NSPoint(x: x, y: y)
            } else {
                let x = visibleFrame.maxX - size.width - 8
                let y = visibleFrame.maxY - size.height - 8
                return NSPoint(x: x, y: y)
            }
        case .classic:
            let x = visibleFrame.midX - size.width / 2
            let y = visibleFrame.minY + 140
            return NSPoint(x: x, y: y)
        }
    }

    private func position(for style: HUDStyle, size: NSSize) -> NSPoint {
        let frame = frameProvider() ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return Self.computePosition(
            style: style,
            size: size,
            visibleFrame: frame,
            suppressionDegraded: mediaKeyStatus.suppressionDegraded
        )
    }

    // MARK: - Panel construction

    private func ensurePanel() -> NSPanel {
        if let existing = panel { return existing }

        let p = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        // Needed for Tahoe hover/drag on a non-activating panel.
        p.acceptsMouseMovedEvents = true
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.isReleasedWhenClosed = false
        // Initial appearance; refreshed on every show() so preference flips
        // between invocations propagate.
        p.appearance = settingsManager.appSettings.appearance.nsAppearance
        // The panel never takes the keyboard, so it is never active: without this its glass
        // would be gray frost
        p.keepActiveAppearance()

        panel = p
        return p
    }

    /// Puts the HUD on Liquid Glass or on a blur, as the settings say, moving the HUD's content
    /// over when that changed
    private func ensureBackdrop(in panel: NSPanel) {
        let kind: HUDBackdropView.Kind = settingsManager.appSettings.hudLiquidGlass ? .glass : .blur
        guard backdrop?.kind != kind else { return }
        let backdrop = HUDBackdropView(kind: kind)
        panel.contentView = backdrop
        // Liquid Glass draws its own edge. A blur gets the window server's shadow around the
        // HUD's rounded shape, as macOS's own HUDs did before it.
        panel.hasShadow = !backdrop.isGlass
        if let hostingView {
            hostingView.removeFromSuperview()
            backdrop.setContent(hostingView)
        }
        self.backdrop = backdrop
    }

    /// The shadow follows what the window shows, so it is worked out again once SwiftUI has
    /// drawn the HUD in its new size or style
    private func refreshShadow(of panel: NSPanel) {
        panel.invalidateShadow()
        Task { @MainActor in
            panel.invalidateShadow()
        }
    }

    private func scheduleHide(for style: HUDStyle) {
        hideTask?.cancel()
        let delay = hideDelay(for: style)
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func handleHoverChange(_ hovering: Bool) {
        isHovering = hovering
        if hovering {
            hideTask?.cancel()
            hideTask = nil
        } else {
            scheduleHide(for: styleAtLastShow)
        }
    }

    // MARK: - Accessibility

    private func postAccessibilityAnnouncement(panel: NSPanel, sliderFraction: Double, mute: Bool, deviceName: String) {
        let description = accessibilityDescription(sliderFraction: sliderFraction, mute: mute, deviceName: deviceName)
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: description,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    private func accessibilityDescription(sliderFraction: Double, mute: Bool, deviceName: String) -> String {
        let device = deviceName.isEmpty ? "Unknown device" : deviceName
        if mute { return "\(device), muted" }
        let clamped = max(0, min(1, sliderFraction))
        return "\(device), volume \(Int((clamped * 100).rounded())) percent"
    }

    private func postPerAppAccessibilityAnnouncement(panel: NSPanel, title: String, content: PerAppHUDContent) {
        let description: String
        switch content {
        case .volume(let sliderFraction):
            description = "\(title), volume \(Int((sliderFraction * 100).rounded())) percent"
        case .mute(let isMuted):
            description = isMuted ? "\(title), muted" : "\(title), unmuted"
        case .notControlled:
            description = "\(title), not controlled by FineTune"
        }
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: description,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    private func reduceMotionEnabled() -> Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - Fullscreen guard

    private func isForegroundAppFullscreen() -> Bool {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return false }
        let pid = frontmostApp.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        guard let mainScreen = NSScreen.main else { return false }
        let screenFrame = mainScreen.frame
        for windowInfo in windowList {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                  let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
                  let boundsRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }
            if boundsRect.width >= screenFrame.width && boundsRect.height >= screenFrame.height {
                return true
            }
        }
        return false
    }

    // MARK: - Suppression-degraded detection

    private func subscribeToSettingsChangedNotification() {
        settingsChangedObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.sound.settingsChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSettingsChangedNotification()
            }
        }
    }

    private func handleSettingsChangedNotification() {
        guard let lastSwallow = lastSwallowedKeyTime else { return }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- lastSwallow.uptimeNanoseconds
        let elapsedMs = elapsed / 1_000_000
        if elapsedMs <= 500 && !mediaKeyStatus.suppressionDegraded {
            mediaKeyStatus.suppressionDegraded = true
            logger.warning("Suppression degraded: native sound handler fired within \(elapsedMs)ms of our swallow")
        }
    }
}

// MARK: - Window

/// The HUD's window. On Liquid Glass it reaches past the HUD for the glass's edge, so the corner
/// HUD's window rises into the menu bar's height, and AppKit would move it down below the menu
/// bar, the HUD with it.
private final class HUDPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

// MARK: - Backdrop

/// What the HUD floats on: Liquid Glass on macOS 26 and later, else a blur of what lies
/// behind the window, like macOS's own HUDs, cut to the HUD's rounded shape. AppKit draws it,
/// since SwiftUI's material and glass only see the HUD's own window, which is empty and clear.
private final class HUDBackdropView: NSView {
    enum Kind {
        /// The see-through Liquid Glass of the Dock and Control Center, on macOS 26 and later;
        /// the blur before
        case glass
        /// A blur in the HUD material, which isn't the menu bar panel's
        case blur
    }

    let kind: Kind

    private let effectView: NSView

    var isGlass: Bool {
        !(effectView is NSVisualEffectView)
    }

    /// Room around the glass for its edge and shadow, which it draws past its shape
    var inset: CGFloat {
        isGlass ? 16 : 0
    }

    var cornerRadius: CGFloat = 0 {
        didSet {
            guard cornerRadius != oldValue else { return }
            applyCornerRadius()
        }
    }

    init(kind: Kind) {
        self.kind = kind
        effectView = Self.makeEffectView(kind)
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 72))
        effectView.frame = bounds.insetBy(dx: inset, dy: inset)
        effectView.autoresizingMask = [.width, .height]
        addSubview(effectView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The SwiftUI HUD, drawn over the glass or the blur
    func setContent(_ view: NSView) {
        // Sized with the window from here on
        view.frame = effectView.bounds
        view.autoresizingMask = [.width, .height]
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = effectView as? NSGlassEffectView {
            glass.contentView = view
            return
        }
        #endif
        effectView.addSubview(view)
    }

    private func applyCornerRadius() {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = effectView as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
            return
        }
        #endif
        (effectView as? NSVisualEffectView)?.maskImage = Self.roundedMask(radius: cornerRadius)
    }

    private static func makeEffectView(_ kind: Kind) -> NSView {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), kind == .glass {
            let glass = NSGlassEffectView()
            glass.style = .clear
            return glass
        }
        #endif
        return makeBlurView()
    }

    private static func makeBlurView() -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        // The HUD's window never becomes key: without this the blur looks inactive, flat
        view.state = .active
        return view
    }

    /// A stretchable rounded rectangle, the shape the blur is cut to
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

// MARK: - Per-app HUD content

private enum PerAppHUDContent {
    case volume(sliderFraction: Double)
    case mute(isMuted: Bool)
    case notControlled
}

private struct PerAppHUD: View {
    let icon: NSImage?
    let title: String
    let content: PerAppHUDContent

    private static let frameWidth: CGFloat = 300
    private static let frameHeight: CGFloat = 72
    static let cornerRadius: CGFloat = 22
    private static let percentageWidth: CGFloat = 36
    private static let iconSize: CGFloat = 28
    private static let barHeight: CGFloat = 4

    private var subtitleText: String? {
        if case .notControlled = content { return "Not controlled by FineTune" }
        return nil
    }

    private var displayLevel: Double {
        switch content {
        case .volume(let sliderFraction): return max(0, min(1, sliderFraction))
        case .mute(let isMuted): return isMuted ? 0 : 1
        case .notControlled: return 0
        }
    }

    private var displayedPercent: Int {
        Int((displayLevel * 100).rounded())
    }

    private var isMutedDisplay: Bool {
        switch content {
        case .mute(let isMuted): return isMuted
        case .volume: return displayedPercent == 0
        case .notControlled: return false
        }
    }

    private var waveIconName: String {
        switch displayedPercent {
        case 0:        return "speaker.fill"
        case 1...33:   return "speaker.wave.1.fill"
        case 34...66:  return "speaker.wave.2.fill"
        default:       return "speaker.wave.3.fill"
        }
    }

    private var percentageText: String {
        "\(displayedPercent)%"
    }

    private var accessibilityDescription: String {
        switch content {
        case .volume:
            return "\(title), volume \(Int((displayLevel * 100).rounded())) percent"
        case .mute(let isMuted):
            return isMuted ? "\(title), muted" : "\(title), unmuted"
        case .notControlled:
            return "\(title), not controlled by FineTune"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            iconView
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(TahoeStyleHUD.nameFont)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailingRow
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: Self.frameWidth, height: Self.frameHeight)
        .hudOutline(cornerRadius: Self.cornerRadius)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: Self.iconSize, height: Self.iconSize)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .frame(width: Self.iconSize, height: Self.iconSize)
        }
    }

    @ViewBuilder
    private var trailingRow: some View {
        switch content {
        case .volume:
            HStack(spacing: 8) {
                Image(systemName: isMutedDisplay ? "speaker.slash.fill" : waveIconName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isMutedDisplay
                                     ? DesignTokens.Colors.mutedIndicator
                                     : DesignTokens.Colors.hudTileActive)
                    .frame(width: 18, height: 18, alignment: .center)

                progressBar
                    .opacity(isMutedDisplay ? 0.5 : 1.0)

                Text(percentageText)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .frame(width: Self.percentageWidth, alignment: .trailing)
            }
        case .mute(let isMuted):
            HStack(spacing: 8) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isMuted
                                     ? DesignTokens.Colors.mutedIndicator
                                     : DesignTokens.Colors.hudTileActive)
                    .frame(width: 18, height: 18, alignment: .center)
                Text(isMuted ? "Muted" : "Unmuted")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                Spacer(minLength: 0)
            }
        case .notControlled:
            if let subtitleText {
                Text(subtitleText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DesignTokens.Colors.textSecondary.opacity(0.25))
                    .frame(height: Self.barHeight)
                Capsule()
                    .fill(DesignTokens.Colors.hudTileActive)
                    .frame(width: geo.size.width * CGFloat(displayLevel), height: Self.barHeight)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: Self.barHeight + 8)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
