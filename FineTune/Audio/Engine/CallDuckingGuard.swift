// FineTune/Audio/Engine/CallDuckingGuard.swift
//
// Approach from CharlieBaker2002's upstream PR (ronitsingh10/FineTune#482), written anew here.

import AudioToolbox
import Darwin
import os

/// Keeps FineTune's output at full level while a call app ducks the Mac.
///
/// While a call app runs Apple's voice processing (FaceTime, WhatsApp...), coreaudiod turns
/// every other client of the output device down to about -15 dB. FineTune plays every tapped
/// app through its own client, so they all drop with it for the whole call. coreaudiod does not
/// duck a client that holds a duck request of its own: the guard holds one of 0.999 (-0.009 dB,
/// inaudible) on every output device, and withdraws it with exactly 1.0.
///
/// `AudioDeviceDuck` is looked up at run time; without it the guard does nothing.
@MainActor
final class CallDuckingGuard {
    typealias DuckFunction = (AudioObjectID, Float32) -> OSStatus

    nonisolated static let holdLevel: Float32 = 0.999
    nonisolated static let releaseLevel: Float32 = 1.0

    private let duck: DuckFunction?
    private(set) var isEnabled: Bool
    private(set) var heldDeviceIDs: Set<AudioObjectID> = []
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "CallDuckingGuard")

    /// - Parameter duck: the function that sends a duck request; nil makes the guard do nothing.
    init(isEnabled: Bool, duck: DuckFunction?) {
        self.isEnabled = isEnabled
        self.duck = duck
    }

    /// `AudioDeviceDuck` from CoreAudio, or nil when this macOS does not export it.
    nonisolated static func systemDuckFunction() -> DuckFunction? {
        typealias CFunction = @convention(c) (AudioObjectID, Float32, UnsafePointer<AudioTimeStamp>?, Float32) -> OSStatus
        // RTLD_DEFAULT
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AudioDeviceDuck") else { return nil }
        let function = unsafeBitCast(symbol, to: CFunction.self)
        return { device, level in function(device, level, nil, 0) }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if !enabled { releaseAll() }
    }

    /// Holds a request on each of `deviceIDs` and withdraws the ones on devices no longer listed.
    func update(outputDeviceIDs deviceIDs: [AudioObjectID]) {
        let wanted = Set(deviceIDs.filter { $0 != kAudioObjectUnknown })
        for gone in heldDeviceIDs.subtracting(wanted) {
            send(Self.releaseLevel, to: gone)
            heldDeviceIDs.remove(gone)
        }
        guard isEnabled else { return }
        for device in wanted.subtracting(heldDeviceIDs) {
            if send(Self.holdLevel, to: device) {
                heldDeviceIDs.insert(device)
            }
        }
    }

    func releaseAll() {
        for device in heldDeviceIDs {
            send(Self.releaseLevel, to: device)
        }
        heldDeviceIDs.removeAll()
    }

    @discardableResult
    private func send(_ level: Float32, to device: AudioObjectID) -> Bool {
        guard let duck else { return false }
        let status = duck(device, level)
        if status != noErr {
            logger.debug("AudioDeviceDuck(\(device), \(level)) failed: \(status)")
        }
        return status == noErr
    }
}
