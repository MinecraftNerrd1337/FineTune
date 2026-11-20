// FineTune/Views/Components/AutoEQDeviceMenu.swift
import SwiftUI

/// What the AutoEQ wand of an output device shows and changes, read from the engine. The device
/// rows of the menu bar panel and the EQ Manager's Apply to DAC menu build their wand from it,
/// so both show and change the same settings.
@MainActor
struct AutoEQDeviceMenu {
    let deviceUID: String
    let profileManager: AutoEQProfileManager
    let selection: AutoEQSelection?
    /// Name of the device's preset, if it has one.
    let profileName: String?
    let favoriteIDs: Set<String>
    let preampEnabled: Bool
    let onSelect: (AutoEQProfile?) -> Void
    let onCorrectionToggle: (Bool) -> Void
    let onPreampToggle: () -> Void

    var isCorrectionEnabled: Bool { selection?.isEnabled ?? false }

    /// The preset under the device's name, marked when its correction is off.
    var subtitle: String? {
        guard let profileName else { return nil }
        return isCorrectionEnabled ? profileName : "\(profileName) (off)"
    }

    init(deviceUID: String, audioEngine: AudioEngine) {
        let profileManager = audioEngine.autoEQProfileManager
        let selection = audioEngine.getAutoEQSelection(for: deviceUID)
        self.deviceUID = deviceUID
        self.profileManager = profileManager
        self.selection = selection
        self.profileName = selection.flatMap { selection in
            profileManager.profile(for: selection.profileID)?.name
                ?? profileManager.catalogEntry(for: selection.profileID)?.name
        }
        self.favoriteIDs = audioEngine.settingsManager.favoriteAutoEQProfileIDs
        self.preampEnabled = audioEngine.autoEQPreampEnabled
        self.onSelect = { profile in
            audioEngine.setAutoEQProfile(for: deviceUID, profileID: profile?.id)
        }
        self.onCorrectionToggle = { enabled in
            audioEngine.setAutoEQEnabled(for: deviceUID, enabled: enabled)
        }
        self.onPreampToggle = {
            audioEngine.setAutoEQPreampEnabled(!audioEngine.autoEQPreampEnabled)
        }
    }
}
