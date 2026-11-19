// FineTune/Audio/Plugins/VolumePluginController.swift
// Finds the volume plugins, pairs each device with the plugin chosen for it, and drives the device through it

#if !APP_STORE

import AppKit
import AudioToolbox
import IOKit.hid
import os

/// Volume plugins give hardware volume to DACs that macOS sees without a volume control, by
/// sending the DAC's own commands over its HID interface. A plugin is a `*.finetuneplugin` file in
/// the plugins folder: a script, with a manifest naming the devices it is written for.
///
/// Each device uses the plugin chosen for it in its details, or none. A device FineTune has no
/// choice for yet gets the first plugin, in file name order, that is written for it and takes new
/// DACs; plugins don't by default. A plugin can be chosen for a device it isn't written for: it
/// then talks to that device's HID interface all the same.
///
/// Mirrors `DDCController`: `DeviceVolumeMonitor` asks it whether a device is plugin-backed, and
/// routes that device's volume and mute here.
@Observable
@MainActor
final class VolumePluginController {
    enum Status: Equatable {
        /// The plugin can't be loaded: its manifest or script is missing or wrong
        case invalid(String)
        case unused
        case active(deviceNames: [String])
        case failed(String)
    }

    /// What a device's details show about plugins
    struct DeviceState: Equatable {
        /// nil while neither the user nor a plugin taking new DACs chose for the device
        let choice: VolumePluginChoice?
        /// The usable plugins written for the device, in the order they take new DACs
        let compatiblePluginIDs: [String]
        /// The plugin that drives the device now
        let activePluginID: String?
        /// Why the chosen plugin doesn't drive the device, or what went wrong while it does
        let problem: String?
    }

    /// Every plugin file found, for the plugins list
    private(set) var plugins: [VolumePluginFile] = []
    /// Slider position (0…1) of each device a plugin drives
    private(set) var cachedVolumes: [AudioDeviceID: Float] = [:]
    /// Devices a plugin drives
    private var bindings: [AudioDeviceID: DeviceBinding] = [:]
    /// The last problem of the plugin on each device, until it works again
    private var failures: [AudioDeviceID: Failure] = [:]
    /// The usable plugins written for each device, from the HID interfaces last seen
    private var compatibility: [AudioDeviceID: [String]] = [:]
    /// Devices whose chosen plugin has no HID interface to talk to
    private var unreachable: Set<AudioDeviceID> = []

    /// A device started or stopped being plugin-backed
    @ObservationIgnored var onBindingsChanged: (() -> Void)?
    /// A device changed level or mute by itself (its own buttons)
    @ObservationIgnored var onDeviceStateChanged: ((AudioDeviceID, _ showsHUD: Bool) -> Void)?

    let directory: URL
    private let settingsManager: SettingsManager
    private let deviceProvider: any AudioDeviceProviding
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "VolumePluginController")

    @ObservationIgnored private var hidManager: IOHIDManager?
    @ObservationIgnored private var hidCallbackContext: UnsafeMutableRawPointer?
    /// Bumped each time the HID manager is rebuilt, so a session that finishes starting, or
    /// reports, after that is dropped
    @ObservationIgnored private var generation = 0
    /// HID interfaces whose session is starting (registry entry ID → device and plugin)
    @ObservationIgnored private var starting: [UInt64: Starting] = [:]
    /// Devices whose plugin failed to start, or was stopped: not tried again until the plugins are
    /// reloaded, another plugin is chosen, or the device comes back
    @ObservationIgnored private var givenUp: [AudioDeviceID: String] = [:]
    /// USB devices whose HID interfaces the HID manager also looks for, for plugins chosen for
    /// devices their manifest doesn't match. Only grows until the app quits.
    @ObservationIgnored private var extraUSBProducts: Set<USBProduct> = []
    @ObservationIgnored private var rebindTask: Task<Void, Never>?
    /// Reads the plugins folder away from the main thread
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// A forced reload waiting for the folder read in flight, or the next one
    @ObservationIgnored private var isForceReloadPending = false
    @ObservationIgnored private var isObservingDevices = false

    private struct DeviceBinding {
        let pluginID: String
        let pluginName: String
        let deviceUID: String
        let deviceName: String
        let hidDevice: IOHIDDevice
        let hidEntryID: UInt64
        let session: VolumePluginSession
    }

    private struct Starting {
        let deviceID: AudioDeviceID
        let pluginID: String
        let session: VolumePluginSession
        let hidDevice: IOHIDDevice
    }

    private struct Failure: Equatable {
        let pluginID: String
        let message: String
    }

    private struct UsablePlugin {
        let file: VolumePluginFile
        let manifest: VolumePluginManifest
        let script: String
    }

    private struct USBProduct: Hashable, Comparable {
        let vendorID: Int
        let productID: Int

        static func < (lhs: USBProduct, rhs: USBProduct) -> Bool {
            (lhs.vendorID, lhs.productID) < (rhs.vendorID, rhs.productID)
        }
    }

    init(
        settingsManager: SettingsManager,
        deviceProvider: any AudioDeviceProviding,
        directory: URL = VolumePluginLoader.defaultDirectory
    ) {
        self.settingsManager = settingsManager
        self.deviceProvider = deviceProvider
        self.directory = directory
    }

    // MARK: - Lifecycle

    /// Returns at once: the plugins folder is read away from the main thread, and the HID
    /// interfaces are looked for once it is, so the app's launch doesn't wait for them
    func start() {
        reload(force: true)
        startObservingDevices()
    }

    func stop() {
        isObservingDevices = false
        loadTask?.cancel()
        loadTask = nil
        isForceReloadPending = false
        closeHID()
    }

    /// Reads the plugins folder again, away from the main thread. When a plugin was added,
    /// removed or edited, or with `force`, restarts the plugins in use (they send the device's
    /// level again).
    func reload(force: Bool = false) {
        if force { isForceReloadPending = true }
        // A read in flight may predate the change: start over, keeping a forced restart
        loadTask?.cancel()
        let directory = directory
        loadTask = Task { @MainActor [weak self] in
            let found = await Task.detached(priority: .utility) {
                VolumePluginLoader.loadAll(from: directory)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.loadTask = nil
            let forced = self.isForceReloadPending
            self.isForceReloadPending = false
            self.apply(found, force: forced)
        }
    }

    private func apply(_ found: [VolumePluginFile], force: Bool) {
        guard force || found != plugins else { return }
        plugins = found
        for plugin in plugins {
            if let error = plugin.loadError {
                logger.warning("Plugin '\(plugin.fileURL.lastPathComponent, privacy: .public)' not loaded: \(error, privacy: .public)")
            }
        }
        restartHID()
    }

    // MARK: - Plugins

    /// Whether the plugin takes the new DACs it is written for
    func takesNewDevices(_ pluginID: String) -> Bool {
        settingsManager.isVolumePluginAutomatic(pluginID)
    }

    func setTakesNewDevices(_ takes: Bool, for pluginID: String) {
        guard takes != takesNewDevices(pluginID) else { return }
        settingsManager.setVolumePluginAutomatic(pluginID, takes)
        // Devices FineTune has no choice for yet can take it now
        if takes, hidManager != nil {
            scheduleRebind()
        }
    }

    /// Opens the plugins folder in the Finder, creating it the first time
    func revealPluginsFolder() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    func status(of plugin: VolumePluginFile) -> Status {
        if let error = plugin.loadError { return .invalid(error) }
        if let failure = failures.values.first(where: { $0.pluginID == plugin.id }) { return .failed(failure.message) }
        let names = bindings.values.filter { $0.pluginID == plugin.id }.map(\.deviceName).sorted()
        return names.isEmpty ? .unused : .active(deviceNames: names)
    }

    // MARK: - Devices

    func isPluginBacked(_ deviceID: AudioDeviceID) -> Bool {
        bindings[deviceID] != nil
    }

    func pluginName(for deviceID: AudioDeviceID) -> String? {
        bindings[deviceID]?.pluginName
    }

    func state(for deviceID: AudioDeviceID, uid: String) -> DeviceState {
        let choice = settingsManager.volumePluginChoice(for: uid)
        let binding = bindings[deviceID].flatMap { $0.deviceUID == uid ? $0 : nil }
        var problem: String?
        if let failure = failures[deviceID], choice == .plugin(failure.pluginID) {
            problem = failure.message
        } else if binding == nil, case .plugin(let pluginID)? = choice {
            if let plugin = plugins.first(where: { $0.id == pluginID }) {
                if let error = plugin.loadError {
                    problem = "The plugin can't be loaded: \(error)"
                } else if unreachable.contains(deviceID) {
                    problem = "The device has no HID interface FineTune can reach, so the plugin can't talk to it."
                }
            } else {
                problem = "The plugin is no longer in the plugins folder."
            }
        }
        return DeviceState(
            choice: choice,
            compatiblePluginIDs: compatibility[deviceID] ?? [],
            activePluginID: binding?.pluginID,
            problem: problem
        )
    }

    /// Uses a plugin for a device, or none. A device with no plugin gets nothing from them, not
    /// even a level: FineTune sets it as it would without plugins.
    func choose(_ choice: VolumePluginChoice, deviceID: AudioDeviceID, deviceUID: String) {
        guard choice != settingsManager.volumePluginChoice(for: deviceUID) else { return }
        settingsManager.setVolumePluginChoice(choice, for: deviceUID)
        failures[deviceID] = nil
        givenUp[deviceID] = nil
        if let binding = bindings[deviceID], choice != .plugin(binding.pluginID) {
            // Let go at once, so nothing more reaches the device
            release(deviceID, reason: "the user chose another plugin for it")
            onBindingsChanged?()
        }
        if hidManager == nil {
            restartHID()
        } else {
            scheduleRebind()
        }
    }

    /// The device's level as a slider position (0…1), or nil if no plugin drives it
    func getVolume(for deviceID: AudioDeviceID) -> Float? {
        cachedVolumes[deviceID]
    }

    func isMuted(for deviceID: AudioDeviceID) -> Bool {
        guard let binding = bindings[deviceID] else { return false }
        return settingsManager.getPluginDeviceMuteState(for: binding.deviceUID) ?? false
    }

    /// Sends a level (0…1, the slider's position) to the device. Fast changes are merged.
    func setVolume(for deviceID: AudioDeviceID, to volume: Float) {
        guard let binding = bindings[deviceID] else { return }
        let clamped = volume.isFinite ? min(max(volume, 0), 1) : 0
        cachedVolumes[deviceID] = clamped
        settingsManager.setPluginDeviceVolume(for: binding.deviceUID, to: clamped)
        binding.session.request(volume: Double(clamped))
    }

    func setMute(for deviceID: AudioDeviceID, to muted: Bool) {
        guard let binding = bindings[deviceID] else { return }
        settingsManager.setPluginDeviceMuteState(for: binding.deviceUID, to: muted)
        binding.session.request(muted: muted)
    }

    /// The level a device gets the first time a plugin drives it: where FineTune's software
    /// slider stood, but at most half way, so a DAC that sat low doesn't jump to full volume.
    nonisolated static func firstVolume(softwareVolume: Float?) -> Float {
        guard let softwareVolume else { return 0.5 }
        return min(Float(VolumeMapping.sliderFraction(forSystemGain: softwareVolume, tier: .software)), 0.5)
    }

    // MARK: - HID

    private var usablePlugins: [UsablePlugin] {
        plugins.compactMap { file in
            guard file.loadError == nil, let manifest = file.manifest, let script = file.script else { return nil }
            return UsablePlugin(file: file, manifest: manifest, script: script)
        }
    }

    private func restartHID() {
        let hadBindings = !bindings.isEmpty
        closeHID()
        failures = [:]
        givenUp = [:]
        let pluginMatching = usablePlugins.flatMap { plugin in
            plugin.manifest.match.flatMap { Self.matchingDictionaries(for: $0) }
        }
        let extraMatching: [[String: Any]] = extraUSBProducts.sorted().map { product in
            [kIOHIDVendorIDKey: product.vendorID, kIOHIDProductIDKey: product.productID]
        }
        if pluginMatching.isEmpty {
            // No plugin to use: an empty list would match nothing, but say so plainly
            compatibility = [:]
            unreachable = []
        } else {
            openHID(matching: pluginMatching + extraMatching)
        }
        if hadBindings {
            onBindingsChanged?()
        }
    }

    private func openHID(matching: [[String: Any]]) {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let context = Unmanaged.passRetained(HIDCallbackContext(controller: self)).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, volumePluginHIDDeviceChanged, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, volumePluginHIDDeviceChanged, context)
        IOHIDManagerRegisterInputReportCallback(manager, volumePluginHIDInputReport, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        // An interface macOS refuses (Input Monitoring) fails here, but may not be the one a
        // plugin uses: a refused send reports it on the plugin itself
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            logger.warning("IOHIDManagerOpen returned \(String(format: "0x%08X", UInt32(bitPattern: result)), privacy: .public)")
        }
        hidManager = manager
        hidCallbackContext = context
        scheduleRebind()
    }

    private func closeHID() {
        // Sessions still starting, and events still on their way, belong to the old manager
        generation += 1
        rebindTask?.cancel()
        rebindTask = nil
        for binding in bindings.values {
            binding.session.close()
        }
        bindings = [:]
        cachedVolumes = [:]
        starting = [:]
        guard let manager = hidManager else { return }
        // Unscheduled first, so no callback can run once the context is released
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = nil
        if let context = hidCallbackContext {
            Unmanaged<HIDCallbackContext>.fromOpaque(context).release()
            hidCallbackContext = nil
        }
    }

    /// What the HID manager looks for, for one rule: each listed product, or the whole vendor.
    /// Names and excluded products are checked on each interface it finds.
    nonisolated static func matchingDictionaries(for match: VolumePluginManifest.Match) -> [[String: Any]] {
        var base: [String: Any] = [kIOHIDVendorIDKey: match.vendorID]
        if let usagePage = match.usagePage { base[kIOHIDDeviceUsagePageKey] = usagePage }
        if let usage = match.usage { base[kIOHIDDeviceUsageKey] = usage }
        guard let productIDs = match.productIDs else { return [base] }
        return productIDs.map { productID in
            var dictionary = base
            dictionary[kIOHIDProductIDKey] = productID
            return dictionary
        }
    }

    // MARK: - Pairing

    private func startObservingDevices() {
        guard !isObservingDevices else { return }
        isObservingDevices = true
        observeDevices()
    }

    private func observeDevices() {
        guard isObservingDevices else { return }
        withObservationTracking {
            _ = deviceProvider.outputDevices
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isObservingDevices else { return }
                if self.hidManager != nil {
                    self.scheduleRebind()
                }
                self.observeDevices()
            }
        }
    }

    /// Waits a moment, so CoreAudio and IOKit have both published a device that was just plugged in
    fileprivate func scheduleRebind() {
        rebindTask?.cancel()
        rebindTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.rebind()
        }
    }

    private func rebind() {
        guard let manager = hidManager else { return }
        // A DAC can have several HID interfaces (its controls, and keys it sends to the Mac):
        // the vendor-defined one, where control protocols live, comes first
        let interfaces = ((IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? [])
            .compactMap(HIDInterface.init)
            .sorted { ($0.isVendorDefined ? 0 : 1, $0.entryID) < ($1.isVendorDefined ? 0 : 1, $1.entryID) }
        let audioDevices = deviceProvider.outputDevices
        var identities: [AudioDeviceID: USBIdentity] = [:]
        for device in audioDevices {
            identities[device.id] = VolumePluginMatching.usbIdentity(forAudioDeviceUID: device.uid)
        }
        let owned = Self.interfacesByDevice(interfaces, devices: audioDevices, identities: identities)
        let usable = usablePlugins
        let automaticIDs = Set(usable.map(\.file.id).filter { takesNewDevices($0) })

        // The plugins written for each device, and the plugin and interface each device uses
        var compatibility: [AudioDeviceID: [String]] = [:]
        var unreachable = Set<AudioDeviceID>()
        var wantedProducts = Set<USBProduct>()
        var targets: [AudioDeviceID: (plugin: UsablePlugin, interface: HIDInterface)] = [:]
        for device in audioDevices {
            let own = owned[device.id] ?? []
            let compatible = usable.filter { plugin in own.contains { $0.matches(plugin.manifest.match) } }
            if !compatible.isEmpty {
                compatibility[device.id] = compatible.map(\.file.id)
            }

            var choice = settingsManager.volumePluginChoice(for: device.uid)
            if choice == nil, let newChoice = Self.choiceForNewDevice(
                compatiblePluginIDs: compatibility[device.id] ?? [], automaticPluginIDs: automaticIDs
            ) {
                choice = newChoice
                settingsManager.setVolumePluginChoice(newChoice, for: device.uid)
                logger.info("A plugin takes the new device '\(device.name, privacy: .public)'")
            }
            guard case .plugin(let pluginID)? = choice,
                  let plugin = usable.first(where: { $0.file.id == pluginID }) else { continue }
            // An interface the manifest matches, else the device's first one, for a plugin chosen
            // for a device it isn't written for
            if let interface = own.first(where: { $0.matches(plugin.manifest.match) }) ?? own.first {
                targets[device.id] = (plugin, interface)
            } else {
                unreachable.insert(device.id)
                if let usb = identities[device.id] {
                    wantedProducts.insert(USBProduct(vendorID: usb.vendorID, productID: usb.productID))
                }
            }
        }
        if self.compatibility != compatibility {
            self.compatibility = compatibility
        }
        if self.unreachable != unreachable {
            self.unreachable = unreachable
        }

        // A plugin chosen for a device it isn't written for needs that device's HID interfaces,
        // which the HID manager only finds once it looks for them
        if !wantedProducts.isSubset(of: extraUSBProducts) {
            extraUSBProducts.formUnion(wantedProducts)
            logger.info("Looking for the HID interfaces of \(wantedProducts.count) devices whose plugin isn't written for them")
            restartHID()
            return
        }

        // Forget what failed on devices that went away: they get a new try when they come back
        let present = Set(audioDevices.map(\.id))
        givenUp = givenUp.filter { present.contains($0.key) }

        // Let go of devices whose plugin or interface changed, or that went away
        var changed = false
        for (deviceID, binding) in bindings {
            let stays = targets[deviceID].map { target in
                target.plugin.file.id == binding.pluginID
                    && target.interface.entryID == binding.hidEntryID
                    && audioDevices.contains { $0.id == deviceID && $0.uid == binding.deviceUID }
            } ?? false
            guard !stays else { continue }
            release(deviceID, reason: "its plugin, its HID interface or the device itself changed")
            changed = true
        }

        // Start the others
        let busyDevices = Set(starting.values.map(\.deviceID))
        for (deviceID, target) in targets where bindings[deviceID] == nil {
            guard !busyDevices.contains(deviceID),
                  starting[target.interface.entryID] == nil,
                  givenUp[deviceID] != target.plugin.file.id,
                  let audio = audioDevices.first(where: { $0.id == deviceID }) else { continue }
            startSession(target.plugin, interface: target.interface, audio: audio)
        }

        if changed {
            onBindingsChanged?()
        }
    }

    /// The plugin a device FineTune has no choice for gets: the first one written for it that takes
    /// new DACs, so two such plugins never fight over a device
    nonisolated static func choiceForNewDevice(
        compatiblePluginIDs: [String],
        automaticPluginIDs: Set<String>
    ) -> VolumePluginChoice? {
        compatiblePluginIDs.first { automaticPluginIDs.contains($0) }.map { VolumePluginChoice.plugin($0) }
    }

    /// The HID interfaces of each audio device: those of the same USB device, by USB IDs and port
    /// when they can be read. A USB device's interfaces share its port, so with two identical DACs
    /// each one keeps its own.
    private static func interfacesByDevice(
        _ interfaces: [HIDInterface],
        devices: [AudioDevice],
        identities: [AudioDeviceID: USBIdentity]
    ) -> [AudioDeviceID: [HIDInterface]] {
        var result: [AudioDeviceID: [HIDInterface]] = [:]
        var deviceAtLocation: [Int: AudioDeviceID] = [:]
        for interface in interfaces {
            if let location = interface.locationID, let deviceID = deviceAtLocation[location] {
                result[deviceID, default: []].append(interface)
                continue
            }
            var owner: AudioDevice?
            var fallback: AudioDevice?
            for device in devices {
                let usb = identities[device.id]
                guard VolumePluginMatching.audioMatches(
                    hidVendorID: interface.vendorID, hidProductID: interface.productID, hidProductName: interface.productName,
                    usb: usb, name: device.name, uid: device.uid
                ) else { continue }
                if let audioLocation = usb?.locationID, let hidLocation = interface.locationID {
                    if audioLocation == hidLocation {
                        owner = device
                        break
                    }
                    continue
                }
                if fallback == nil, result[device.id] == nil {
                    fallback = device
                }
            }
            guard let device = owner ?? fallback else { continue }
            result[device.id, default: []].append(interface)
            if let location = interface.locationID {
                deviceAtLocation[location] = device.id
            }
        }
        return result
    }

    private func release(_ deviceID: AudioDeviceID, reason: String) {
        guard let binding = bindings.removeValue(forKey: deviceID) else { return }
        binding.session.close()
        cachedVolumes[deviceID] = nil
        logger.info("Plugin '\(binding.pluginName, privacy: .public)' stopped driving '\(binding.deviceName, privacy: .public)': \(reason, privacy: .public)")
    }

    private func startSession(_ plugin: UsablePlugin, interface: HIDInterface, audio: AudioDevice) {
        // AudioDevice holds an NSImage, so only its plain values go into the closures below
        let deviceID = audio.id
        let uid = audio.uid
        let deviceName = audio.name
        let pluginID = plugin.file.id
        let pluginName = plugin.manifest.name
        let currentGeneration = generation
        let info = VolumePluginSession.DeviceInfo(
            name: audio.name,
            uid: uid,
            vendorID: interface.vendorID ?? 0,
            productID: interface.productID ?? 0,
            productName: interface.productName ?? ""
        )
        let session = VolumePluginSession(
            manifest: plugin.manifest,
            script: plugin.script,
            scriptURL: plugin.file.fileURL,
            transport: HIDDeviceHandle(device: interface.device),
            info: info,
            onEvent: { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handle(event, pluginID: pluginID, deviceID: deviceID, generation: currentGeneration)
                }
            }
        )

        // Never louder than where the user left it: the plugin's last level, else the software slider
        let volume = settingsManager.getPluginDeviceVolume(for: uid)
            ?? Self.firstVolume(softwareVolume: settingsManager.getSoftwareDeviceVolume(for: uid))
        let muted = settingsManager.getPluginDeviceMuteState(for: uid)
            ?? settingsManager.getSoftwareDeviceMuteState(for: uid)
        let entryID = interface.entryID
        let hidDevice = HIDDeviceHandle(device: interface.device)
        starting[entryID] = Starting(deviceID: deviceID, pluginID: pluginID, session: session, hidDevice: hidDevice.device)
        logger.info("Plugin '\(pluginName, privacy: .public)' starting for '\(deviceName, privacy: .public)'")

        // The device only becomes plugin-backed (software gain dropped to unity) once the plugin
        // has set its level, so it never plays loud in between
        session.start(volume: Double(volume), muted: muted) { [weak self] attached in
            guard let self, currentGeneration == self.generation else {
                session.close()
                return
            }
            self.starting[entryID] = nil
            guard let attached else {
                session.close()
                self.givenUp[deviceID] = pluginID
                self.logger.warning("Plugin '\(pluginName, privacy: .public)' failed to start for '\(deviceName, privacy: .public)'")
                return
            }
            guard self.deviceProvider.outputDevices.contains(where: { $0.id == deviceID && $0.uid == uid }),
                  self.bindings[deviceID] == nil else {
                session.close()
                return
            }
            guard self.settingsManager.volumePluginChoice(for: uid) == .plugin(pluginID) else {
                // The user chose another plugin, or none, while this one was starting
                session.close()
                self.scheduleRebind()
                return
            }
            self.failures[deviceID] = nil
            self.bindings[deviceID] = DeviceBinding(
                pluginID: pluginID,
                pluginName: pluginName,
                deviceUID: uid,
                deviceName: deviceName,
                hidDevice: hidDevice.device,
                hidEntryID: entryID,
                session: session
            )
            let level = Float(attached.volume)
            self.cachedVolumes[deviceID] = level
            self.settingsManager.setPluginDeviceVolume(for: uid, to: level)
            self.settingsManager.setPluginDeviceMuteState(for: uid, to: attached.muted)
            self.logger.info("Plugin '\(pluginName, privacy: .public)' drives '\(deviceName, privacy: .public)'")
            self.onBindingsChanged?()
        }
    }

    private func handle(_ event: VolumePluginEvent, pluginID: String, deviceID: AudioDeviceID, generation eventGeneration: Int) {
        guard eventGeneration == generation else { return }
        switch event {
        case .volumeReported(let volume, let showsHUD):
            guard let binding = bindings[deviceID], binding.pluginID == pluginID else { return }
            cachedVolumes[deviceID] = volume
            settingsManager.setPluginDeviceVolume(for: binding.deviceUID, to: volume)
            onDeviceStateChanged?(deviceID, showsHUD)
        case .muteReported(let muted, let showsHUD):
            guard let binding = bindings[deviceID], binding.pluginID == pluginID else { return }
            settingsManager.setPluginDeviceMuteState(for: binding.deviceUID, to: muted)
            onDeviceStateChanged?(deviceID, showsHUD)
        case .failed(let message):
            failures[deviceID] = Failure(pluginID: pluginID, message: message)
        case .recovered:
            if failures[deviceID]?.pluginID == pluginID {
                failures[deviceID] = nil
            }
        case .stopped(let message):
            // The script hung: FineTune sets the device as it would without plugins
            failures[deviceID] = Failure(pluginID: pluginID, message: message)
            givenUp[deviceID] = pluginID
            if bindings[deviceID]?.pluginID == pluginID {
                release(deviceID, reason: "its script was stopped")
                onBindingsChanged?()
            }
        }
    }

    fileprivate func handleInputReport(from device: HIDDeviceHandle, reportID: UInt32, bytes: [UInt8]) {
        for binding in bindings.values where binding.hidDevice === device.device {
            binding.session.handleInputReport(reportID: reportID, bytes: bytes)
        }
        // A plugin still starting may be waiting for the level the device sends back
        for start in starting.values where start.hidDevice === device.device {
            start.session.handleInputReport(reportID: reportID, bytes: bytes)
        }
    }
}

// MARK: - HID interface

/// The properties of a HID interface that pairing needs, read once
private nonisolated struct HIDInterface: @unchecked Sendable {
    let device: IOHIDDevice
    let entryID: UInt64
    let vendorID: Int?
    let productID: Int?
    let productName: String?
    let locationID: Int?
    let usagePairs: [(page: Int, usage: Int)]

    init?(_ device: IOHIDDevice) {
        var entryID: UInt64 = 0
        let service = IOHIDDeviceGetService(device)
        guard service != 0, IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { return nil }
        func number(_ key: String) -> Int? {
            (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
        }
        self.device = device
        self.entryID = entryID
        vendorID = number(kIOHIDVendorIDKey)
        productID = number(kIOHIDProductIDKey)
        productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
        locationID = number(kIOHIDLocationIDKey)
        let pairs = (IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]]) ?? []
        let usagePairs = pairs.compactMap { pair -> (page: Int, usage: Int)? in
            guard let page = (pair[kIOHIDDeviceUsagePageKey] as? NSNumber)?.intValue,
                  let usage = (pair[kIOHIDDeviceUsageKey] as? NSNumber)?.intValue else { return nil }
            return (page: page, usage: usage)
        }
        if usagePairs.isEmpty, let page = number(kIOHIDPrimaryUsagePageKey), let usage = number(kIOHIDPrimaryUsageKey) {
            self.usagePairs = [(page: page, usage: usage)]
        } else {
            self.usagePairs = usagePairs
        }
    }

    /// Has a top-level collection on a vendor-defined usage page (0xFF00 and up)
    var isVendorDefined: Bool {
        usagePairs.contains { $0.page >= 0xFF00 }
    }

    func matches(_ rules: [VolumePluginManifest.Match]) -> Bool {
        VolumePluginMatching.hidMatches(
            anyOf: rules, vendorID: vendorID, productID: productID, productName: productName, usagePairs: usagePairs)
    }
}

// MARK: - HID manager callbacks

/// Weak back-reference passed to the C callbacks
private nonisolated final class HIDCallbackContext {
    weak var controller: VolumePluginController?
    init(controller: VolumePluginController) { self.controller = controller }
}

// The HID manager is scheduled on the main run loop, so these run on main.
private let volumePluginHIDDeviceChanged: IOHIDDeviceCallback = { context, _, _, _ in
    guard let context,
          let controller = Unmanaged<HIDCallbackContext>.fromOpaque(context).takeUnretainedValue().controller else { return }
    MainActor.assumeIsolated {
        controller.scheduleRebind()
    }
}

private let volumePluginHIDInputReport: IOHIDReportCallback = { context, result, sender, _, reportID, report, length in
    guard result == kIOReturnSuccess, let context, let sender, length > 0,
          let controller = Unmanaged<HIDCallbackContext>.fromOpaque(context).takeUnretainedValue().controller else { return }
    let device = HIDDeviceHandle(device: Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue())
    let bytes = Array(UnsafeBufferPointer(start: report, count: length))
    MainActor.assumeIsolated {
        controller.handleInputReport(from: device, reportID: reportID, bytes: bytes)
    }
}

#endif
