//
//  RecordingInputAuthorization.swift
//  BetterShot
//
//  Resolves camera and microphone authorization before a recording input is
//  persisted. Denied access is surfaced with a direct route to System Settings
//  instead of failing later while the recording stream is starting.
//

import AppKit
import AVFoundation

@MainActor
enum RecordingInputAuthorization {
    enum Input {
        case camera
        case microphone

        fileprivate var mediaType: AVMediaType {
            switch self {
            case .camera:
                .video
            case .microphone:
                .audio
            }
        }

        fileprivate var title: String {
            switch self {
            case .camera:
                L10n.string("Camera")
            case .microphone:
                L10n.string("Microphone")
            }
        }

        fileprivate var settingsURL: URL? {
            let pane: String
            switch self {
            case .camera:
                pane = "Privacy_Camera"
            case .microphone:
                pane = "Privacy_Microphone"
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
        }
    }

    static func status(for input: Input) -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: input.mediaType)
    }

    /// Requests access when it has not been decided yet. Denied or restricted
    /// access is explained immediately so callers never persist an unusable
    /// recording-device selection.
    static func ensureAccess(for input: Input) async -> Bool {
        let currentStatus = status(for: input)
        let granted = await requestAccess(for: input)
        guard !granted else { return true }

        presentDeniedAlert(for: input, isRestricted: currentStatus == .restricted)
        return false
    }

    /// Resolves access without presenting UI. Recording startup uses this to
    /// collect all unavailable optional inputs into one downgrade warning.
    static func requestAccess(for input: Input) async -> Bool {
        switch status(for: input) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: input.mediaType)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private static func presentDeniedAlert(for input: Input, isRestricted: Bool) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.format("%@ access needed", input.title)

        if isRestricted {
            alert.informativeText = L10n.format("BetterShot can't use the %@ because access is restricted on this Mac.", input.title.lowercased())
            alert.addButton(withTitle: L10n.string("OK"))
            alert.runModal()
            return
        }

        alert.informativeText = L10n.format("Allow BetterShot to use the %@ in Privacy & Security, then select it again.", input.title.lowercased())
        alert.addButton(withTitle: L10n.string("Open System Settings"))
        alert.addButton(withTitle: L10n.string("Cancel"))

        if alert.runModal() == .alertFirstButtonReturn,
           let settingsURL = input.settingsURL {
            NSWorkspace.shared.open(settingsURL)
        }
    }
}
