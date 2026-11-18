// FineTune/Audio/Plugins/VolumePlugin.swift
// Volume plugins: the manifest format, loading plugins from disk, and matching them to devices

#if !APP_STORE

import Foundation
import IOKit
import IOKit.hid

// MARK: - Manifest

/// The manifest of a plugin: which devices it is written for, and the shape of its HID reports.
/// It is JSON, in a `/* @manifest … */` comment of the plugin's file; the rest of the file is the
/// script that does the talking.
nonisolated struct VolumePluginManifest: Codable, Equatable, Sendable {
    /// One rule of `match`: the devices of one USB vendor, all of them or only some. Each field
    /// after `vendorID` narrows the rule. IDs can be written as numbers or as "0x…" strings.
    struct Match: Codable, Equatable, Sendable {
        var vendorID: Int
        /// Only these products
        var productIDs: [Int]?
        /// Every product but these
        var excludedProductIDs: [Int]?
        /// Only the products with one of these names, compared without case, spaces or
        /// punctuation against the HID interface's product string
        var productNames: [String]?
        /// Only the HID interface with a top-level collection on this usage page
        /// (0xFF00 and up are vendor-defined)
        var usagePage: Int?
        var usage: Int?
    }

    struct HID: Codable, Equatable, Sendable {
        /// When set, every output report is sent with exactly this many bytes, not counting the
        /// report ID byte: shorter ones are padded with zeros, longer ones are refused. Some DACs
        /// lock up when a report has another length. Without it, reports are sent as the plugin
        /// gives them, for a plugin that drives DACs whose reports differ in length.
        var outputReportLength: Int?
        /// Same for feature reports
        var featureReportLength: Int?
    }

    var id: String
    var name: String
    var author: String?
    var version: String?
    var description: String?
    /// The devices the plugin is written for: those any one of the rules allows. The manifest can
    /// hold one rule or a list of them.
    var match: [Match]
    var hid: HID
    /// Shortest gap, in milliseconds, between two volume changes sent to the device (default 20)
    var minimumIntervalMS: Int?

    static let defaultMinimumIntervalMS = 20
    /// Longest report, in bytes, a plugin can send or read
    static let maximumReportLength = 1024
}

extension VolumePluginManifest {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        // One rule, or a list of rules
        if (try? c.nestedUnkeyedContainer(forKey: .match)) != nil {
            match = try c.decode([Match].self, forKey: .match)
        } else {
            match = [try c.decode(Match.self, forKey: .match)]
        }
        hid = try c.decodeIfPresent(HID.self, forKey: .hid) ?? HID()
        minimumIntervalMS = try c.decodeIfPresent(Int.self, forKey: .minimumIntervalMS)
    }
}

extension VolumePluginManifest.Match {
    /// Every key a rule takes. Any other is refused: a misspelled key would leave the rule wider
    /// than meant, up to every product of the vendor.
    static let knownKeys: Set<String> = [
        "vendorID", "productIDs", "excludedProductIDs", "productNames", "usagePage", "usage",
    ]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let keys = try decoder.container(keyedBy: AnyCodingKey.self).allKeys.map(\.stringValue)
        if let unknown = keys.sorted().first(where: { !VolumePluginManifest.Match.knownKeys.contains($0) }) {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: c.codingPath,
                debugDescription: "a rule has no “\(unknown)”. It takes \(VolumePluginManifest.Match.knownKeys.sorted().joined(separator: ", "))."))
        }
        guard let vendorID = try c.decodeIfPresent(ManifestNumber.self, forKey: .vendorID)?.value else {
            throw DecodingError.keyNotFound(CodingKeys.vendorID, DecodingError.Context(
                codingPath: c.codingPath, debugDescription: "vendorID is required"))
        }
        self.vendorID = vendorID
        productIDs = try c.decodeIfPresent([ManifestNumber].self, forKey: .productIDs)?.map(\.value)
        excludedProductIDs = try c.decodeIfPresent([ManifestNumber].self, forKey: .excludedProductIDs)?.map(\.value)
        productNames = try c.decodeIfPresent([String].self, forKey: .productNames)
        usagePage = try c.decodeIfPresent(ManifestNumber.self, forKey: .usagePage)?.value
        usage = try c.decodeIfPresent(ManifestNumber.self, forKey: .usage)?.value
    }
}

/// Any key of a JSON object, to find the ones a manifest doesn't take
private nonisolated struct AnyCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

/// A number in a manifest: a JSON number, or a string holding a decimal or "0x…" hexadecimal number
private nonisolated struct ManifestNumber: Decodable {
    let value: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let number = try? c.decode(Int.self) {
            value = number
            return
        }
        let text = try c.decode(String.self).trimmingCharacters(in: .whitespaces).lowercased()
        let isHex = text.hasPrefix("0x")
        guard let number = Int(isHex ? String(text.dropFirst(2)) : text, radix: isHex ? 16 : 10) else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "expected a number, or a string such as \"0x262A\"")
        }
        value = number
    }
}

// MARK: - Plugin on disk

/// A plugin file found on disk, usable or not.
nonisolated struct VolumePluginFile: Identifiable, Equatable, Sendable {
    /// The manifest's id, or the file name when the manifest can't be read
    let id: String
    let fileURL: URL
    let manifest: VolumePluginManifest?
    /// The whole file, which is the plugin's script: the manifest is a comment to it
    let script: String?
    /// Why the plugin can't be used, in words for the plugins list
    let loadError: String?

    var name: String { manifest?.name ?? fileURL.deletingPathExtension().lastPathComponent }
    var isUsable: Bool { manifest != nil && script != nil && loadError == nil }
}

nonisolated enum VolumePluginLoader {
    static let fileExtension = "finetuneplugin"
    /// Larger files are refused unread: a plugin is a short script
    static let maximumFileSize = 1_000_000

    /// ~/Library/Application Support/FineTune/Plugins
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FineTune")
            .appendingPathComponent("Plugins")
    }

    /// Every `*.finetuneplugin` file in `directory`, sorted by name: the order in which plugins
    /// take new DACs. A missing directory has none.
    static func loadAll(from directory: URL) -> [VolumePluginFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]
        )) ?? []
        var files: [VolumePluginFile] = []
        var seenIDs = Set<String>()
        let found = urls
            .filter { $0.pathExtension == fileExtension }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for url in found {
            let file = load(url)
            if seenIDs.contains(file.id) {
                // Two plugins with one id would share their choices and settings
                files.append(VolumePluginFile(
                    id: "\(file.id) (\(url.lastPathComponent))", fileURL: url, manifest: nil, script: nil,
                    loadError: "Another plugin already uses the id “\(file.id)”."))
                continue
            }
            seenIDs.insert(file.id)
            files.append(file)
        }
        return files
    }

    static func load(_ url: URL) -> VolumePluginFile {
        func broken(_ error: String, manifest: VolumePluginManifest? = nil) -> VolumePluginFile {
            VolumePluginFile(id: manifest?.id ?? url.lastPathComponent, fileURL: url, manifest: manifest, script: nil, loadError: error)
        }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true {
            return broken("This is a folder. A plugin is a single file, its manifest in a /* @manifest … */ comment of its script.")
        }
        if let size = values?.fileSize, size > maximumFileSize {
            return broken("The file is larger than \(maximumFileSize / 1_000_000) MB.")
        }
        guard let data = try? Data(contentsOf: url), let source = String(data: data, encoding: .utf8) else {
            return broken("The file can't be read as UTF-8 text.")
        }
        guard let json = manifestJSON(in: source) else {
            return broken("The file has no /* @manifest … */ comment.")
        }
        let manifest: VolumePluginManifest
        do {
            manifest = try JSONDecoder().decode(VolumePluginManifest.self, from: Data(json.utf8))
        } catch {
            return broken(describe(error))
        }
        if let problem = validate(manifest) {
            return broken(problem, manifest: manifest)
        }
        return VolumePluginFile(id: manifest.id, fileURL: url, manifest: manifest, script: source, loadError: nil)
    }

    /// The manifest's JSON: what follows `@manifest` in the first comment that opens with it, up to
    /// the end of that comment
    static func manifestJSON(in source: String) -> Substring? {
        guard let marker = source.range(of: #"/\*\s*@manifest\b"#, options: .regularExpression),
              let end = source.range(of: "*/", range: marker.upperBound..<source.endIndex) else { return nil }
        return source[marker.upperBound..<end.lowerBound]
    }

    /// What's wrong with a manifest that decoded, or nil
    static func validate(_ manifest: VolumePluginManifest) -> String? {
        if manifest.id.trimmingCharacters(in: .whitespaces).isEmpty {
            return "The manifest's id is empty."
        }
        if manifest.match.isEmpty {
            return "The manifest's match has no rule."
        }
        let usbIDs = 0...0xFFFF
        for rule in manifest.match {
            if !usbIDs.contains(rule.vendorID) {
                return "vendorID must be between 0 and 0xFFFF."
            }
            if rule.productIDs?.isEmpty == true {
                return "productIDs is empty. Leave it out to match every product of the vendor."
            }
            let productIDs = (rule.productIDs ?? []) + (rule.excludedProductIDs ?? [])
            if !productIDs.allSatisfy({ usbIDs.contains($0) }) {
                return "Product IDs must be between 0 and 0xFFFF."
            }
            if let names = rule.productNames,
               names.isEmpty || names.contains(where: { VolumePluginMatching.normalized($0).isEmpty }) {
                return "productNames must list names that have letters or digits."
            }
        }
        let lengths = 1...VolumePluginManifest.maximumReportLength
        if let length = manifest.hid.outputReportLength, !lengths.contains(length) {
            return "outputReportLength must be between 1 and \(VolumePluginManifest.maximumReportLength)."
        }
        if let length = manifest.hid.featureReportLength, !lengths.contains(length) {
            return "featureReportLength must be between 1 and \(VolumePluginManifest.maximumReportLength)."
        }
        if let interval = manifest.minimumIntervalMS, !(0...500).contains(interval) {
            return "minimumIntervalMS must be between 0 and 500."
        }
        return nil
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _):
            return "The manifest has no “\(key.stringValue)”."
        case DecodingError.typeMismatch(_, let context),
             DecodingError.valueNotFound(_, let context),
             DecodingError.dataCorrupted(let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            guard path.isEmpty else { return "The manifest, “\(path)”: \(context.debugDescription)" }
            // JSONSerialization says where the syntax breaks, counting lines from "@manifest"
            let detail = (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
            return detail.map { "The manifest is not valid JSON: \($0)" } ?? "The manifest is not valid JSON."
        default:
            return error.localizedDescription
        }
    }
}

// MARK: - Matching

/// The USB device an audio device belongs to
nonisolated struct USBIdentity: Equatable, Sendable {
    let vendorID: Int
    let productID: Int
    let locationID: Int?
}

nonisolated enum VolumePluginMatching {
    /// Lowercased letters and digits only, so "iBasso-DC06-Pro" and "ibasso dc06 pro" compare equal
    static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Whether a rule allows a HID interface
    static func hidMatches(
        _ match: VolumePluginManifest.Match,
        vendorID: Int?, productID: Int?, productName: String?, usagePairs: [(page: Int, usage: Int)]
    ) -> Bool {
        guard vendorID == match.vendorID else { return false }
        if let wanted = match.productIDs {
            guard let productID, wanted.contains(productID) else { return false }
        }
        if let excluded = match.excludedProductIDs, let productID, excluded.contains(productID) {
            return false
        }
        if let names = match.productNames {
            let name = normalized(productName ?? "")
            guard !name.isEmpty, names.contains(where: { normalized($0) == name }) else { return false }
        }
        if match.usagePage != nil || match.usage != nil {
            let hasCollection = usagePairs.contains { pair in
                (match.usagePage.map { $0 == pair.page } ?? true) && (match.usage.map { $0 == pair.usage } ?? true)
            }
            if !hasCollection { return false }
        }
        return true
    }

    /// Whether any one of a plugin's rules allows a HID interface
    static func hidMatches(
        anyOf rules: [VolumePluginManifest.Match],
        vendorID: Int?, productID: Int?, productName: String?, usagePairs: [(page: Int, usage: Int)]
    ) -> Bool {
        rules.contains { rule in
            hidMatches(rule, vendorID: vendorID, productID: productID, productName: productName, usagePairs: usagePairs)
        }
    }

    /// Whether an audio device is part of the same USB device as a HID interface: by its USB IDs
    /// when they could be read, otherwise by the interface's product name in its name or UID.
    static func audioMatches(
        hidVendorID: Int?, hidProductID: Int?, hidProductName: String?,
        usb: USBIdentity?, name: String, uid: String
    ) -> Bool {
        if let usb {
            return usb.vendorID == hidVendorID && usb.productID == hidProductID
        }
        let wanted = normalized(hidProductName ?? "")
        guard !wanted.isEmpty else { return false }
        return normalized(name).contains(wanted) || normalized(uid).contains(wanted)
    }

    /// The USB IDs of the device behind a CoreAudio UID. USB audio engines publish the UID as
    /// `IOAudioEngineGlobalUniqueID`; the USB device is one of their ancestors in the registry.
    static func usbIdentity(forAudioDeviceUID uid: String) -> USBIdentity? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAudioEngine"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let engineUID = IORegistryEntryCreateCFProperty(entry, "IOAudioEngineGlobalUniqueID" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard engineUID == uid else { continue }

            func ancestorNumber(_ key: String) -> Int? {
                let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
                return (IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key as CFString, kCFAllocatorDefault, options)
                    as? NSNumber)?.intValue
            }
            guard let vendorID = ancestorNumber("idVendor"), let productID = ancestorNumber("idProduct") else { return nil }
            return USBIdentity(vendorID: vendorID, productID: productID, locationID: ancestorNumber("locationID"))
        }
        return nil
    }
}

#endif
