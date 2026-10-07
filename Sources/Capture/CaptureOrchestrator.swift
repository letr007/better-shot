import AppKit
import SwiftUI

/// Coordinates the full capture pipeline: hide window -> capture -> sound -> preview/editor.
@MainActor
@Observable
final class CaptureOrchestrator {
    static let shared = CaptureOrchestrator()

    private(set) var lastCaptureURL: URL?
    private var captureInProgress = false
    private var pendingCaptures: [(ShortcutService.Action, NSScreen?)] = []
    private var captureScreen: NSScreen?

    private init() {}

    func performCapture(_ action: ShortcutService.Action, on screen: NSScreen? = nil) async {
        if captureInProgress {
            pendingCaptures.append((action, screen))
            return
        }
        captureInProgress = true
        captureScreen = screen
        await executeCapture(action)
        while let (next, nextScreen) = pendingCaptures.first {
            pendingCaptures.removeFirst()
            captureScreen = nextScreen
            await executeCapture(next)
        }
        captureScreen = nil
        captureInProgress = false
    }

    private func executeCapture(_ action: ShortcutService.Action) async {
        do {
            switch action {
            case .region:
                if AppPreferences.regionCaptureMode == .frozen {
                    try await captureRegionFrozen(on: captureScreen)
                } else {
                    await captureAndProcess { try await ScreenCapture.shared.captureRegion() }
                }
            case .fullscreen:
                await captureAndProcess { try await ScreenCapture.shared.captureFullscreen() }
            case .window:
                await captureAndProcess { try await ScreenCapture.shared.captureWindow() }
            case .longScreenshot:
                try await captureLongScreenshot(on: captureScreen)
            case .ocr:
                await performOCR()
            case .colorPicker:
                await performColorPick()
            case .recording:
                break
            }
        } catch {
            showCaptureError(error)
        }
    }

    private func showCaptureError(_ error: Error) {
        print("Capture failed: \(error.localizedDescription)")
        ToastWindow.shared.show(
            title: L10n.string("Screenshot Failed"),
            message: error.localizedDescription,
            systemIcon: "exclamationmark.triangle",
            on: captureScreen
        )
    }

    // MARK: - Private

    private func captureAndProcess(_ capture: () async throws -> URL?) async {
        let delay = AppPreferences.selfTimerDelay
        if delay != .off {
            await CountdownOverlay.shared.showCountdown(seconds: delay.rawValue)
        }

        do {
            guard let url = try await capture() else { return }

            ScreenCapture.shared.playShutterSound()

            guard let record = HistoryStore.shared.importCapture(from: url) else { return }
            let capturedURL = HistoryStore.shared.urlForRecord(record)
            lastCaptureURL = capturedURL
            await galleryApplyAndSave(capturedURL, recordID: record.id)
        } catch {
            showCaptureError(error)
        }
    }


    /// Freeze-then-select region capture: grab a non-interactive full-screen frame,
    /// let the user pick a region on the frozen image, then crop and process.
    private func captureRegionFrozen(on screen: NSScreen?) async throws {
        let delay = AppPreferences.selfTimerDelay
        if delay != .off {
            await CountdownOverlay.shared.showCountdown(seconds: delay.rawValue)
        }

        let targetScreen = screen
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let targetScreen else { return }

        MenuBarPopoverController.shared.closePopover()
        try await Task.sleep(for: .milliseconds(200))

        let displayCapture = try await ScreenCapture.shared.prepareDisplayCapture(on: targetScreen)
        let frozenImage = try await displayCapture.image()
        let displayImage = NSImage(
            cgImage: frozenImage,
            size: NSSize(width: targetScreen.frame.width, height: targetScreen.frame.height)
        )

        let overlay = RegionSelectionOverlay()
        guard let selection = await overlay.selectRegion(over: displayImage, screens: [targetScreen]) else { return }

        guard let cropped = ScreenCapture.shared.crop(frozenImage, to: selection.localRect, on: targetScreen),
              let tempURL = writePNGToTemp(cropped) else { return }

        ScreenCapture.shared.playShutterSound()

        guard let record = HistoryStore.shared.importCapture(from: tempURL) else {
            print("Capture failed: could not import capture")
            try? FileManager.default.removeItem(at: tempURL)
            return
        }
        let capturedURL = HistoryStore.shared.urlForRecord(record)
        lastCaptureURL = capturedURL
        try? FileManager.default.removeItem(at: tempURL)

        await galleryApplyAndSave(capturedURL, recordID: record.id)
    }

    private func captureLongScreenshot(on screen: NSScreen?) async throws {
        let delay = AppPreferences.selfTimerDelay
        if delay != .off {
            await CountdownOverlay.shared.showCountdown(seconds: delay.rawValue)
        }

        let targetScreen = screen
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let targetScreen else { return }

        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        MenuBarPopoverController.shared.closePopover()
        try await Task.sleep(for: .milliseconds(200))

        let displayCapture = try await ScreenCapture.shared.prepareDisplayCapture(on: targetScreen, excludingOwnApplication: true)
        let frozenCGImage = try await displayCapture.image()
        let frozenImage = NSImage(
            cgImage: frozenCGImage,
            size: NSSize(width: targetScreen.frame.width, height: targetScreen.frame.height)
        )

        let overlay = RegionSelectionOverlay()
        guard let selection = await overlay.selectRegion(over: frozenImage, screens: [targetScreen]) else { return }

        frontmostApplication?.activate(options: [])
        try await Task.sleep(for: .milliseconds(200))
        // Start from the live viewport after selection and application reactivation.
        let initialFrame = try await displayCapture.image(viewport: selection.localRect)
        let session = try LongScreenshotSession(
            initialFrame: initialFrame,
            viewport: selection.localRect,
            screen: targetScreen,
            displayCapture: displayCapture
        )
        guard let stitchedImage = await session.run(),
              let tempURL = writePNGToTemp(stitchedImage) else { return }
        await processCapturedURL(tempURL)
    }

    private func processCapturedURL(_ url: URL) async {
        ScreenCapture.shared.playShutterSound()

        guard let record = HistoryStore.shared.importCapture(from: url) else {
            print("Capture failed: could not import capture")
            try? FileManager.default.removeItem(at: url)
            return
        }
        let capturedURL = HistoryStore.shared.urlForRecord(record)
        lastCaptureURL = capturedURL
        try? FileManager.default.removeItem(at: url)
        await galleryApplyAndSave(capturedURL, recordID: record.id)
    }

    private func writePNGToTemp(_ cgImage: CGImage) -> URL? {
        let dir = NSTemporaryDirectory()
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let path = "\(dir)bettershot_\(stamp).png"
        let url = URL(fileURLWithPath: path)

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1, nil
        ) else { return nil }

        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return url
    }

    private func performColorPick() async {
        let overlay = ColorPickerOverlay()
        guard let hex = await overlay.pickColor() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(hex, forType: .string)
        ScreenCapture.shared.playShutterSound()
        ToastWindow.shared.show(
            title: L10n.string("Copied"),
            message: L10n.format("%@ copied to clipboard", hex),
            systemIcon: "eyedropper",
            on: captureScreen
        )
    }

    private func performOCR() async {
        do {
            guard let text = try await ScreenCapture.shared.captureAndOCR() else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            ScreenCapture.shared.playShutterSound()
            ToastWindow.shared.show(
                title: L10n.string("Copied"),
                message: L10n.string("Text copied to clipboard"),
                systemIcon: "doc.text.viewfinder",
                on: captureScreen
            )
        } catch {
            showCaptureError(error)
        }
    }

    private func galleryApplyAndSave(_ url: URL, recordID: UUID? = nil) async {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }

        let config = AppPreferences.defaultBeautifierConfig
        let rendered = BeautifierRenderer.render(image: cgImage, config: config)

        guard let rendered else { return }

        let savedURL = saveImage(rendered)

        if let savedURL {
            saveBaseImage(rawURL: url, alongside: savedURL)

            if let recordID {
                HistoryStore.shared.setBeautifiedPath(savedURL.path, for: recordID)
            }
        }

        if AppPreferences.copyAfterSave, let savedURL {
            copyToClipboard(savedURL)
        }

        let displayURL = savedURL ?? url

        if savedURL != nil {
            let appIcon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
            ToastWindow.shared.show(
                message: L10n.string(AppPreferences.copyAfterSave ? "Screenshot saved & copied!" : "Screenshot saved!"),
                icon: appIcon,
                on: captureScreen
            )
        }

        PreviewOverlay.shared.show(url: displayURL, on: captureScreen)
    }

    private func saveImage(_ cgImage: CGImage) -> URL? {
        let dir = AppPreferences.saveDirectory
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let ext = AppPreferences.exportFormat.fileExtension
        let path = "\(dir)/bettershot_\(stamp).\(ext)"
        let url = URL(fileURLWithPath: path)

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            AppPreferences.exportFormat.utType as CFString,
            1, nil
        ) else { return nil }

        var options: [CFString: Any] = [:]
        if AppPreferences.exportFormat == .jpeg {
            options[kCGImageDestinationLossyCompressionQuality] = AppPreferences.exportQuality
        }

        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else { return nil }
        return url
    }

    private func saveBaseImage(rawURL: URL, alongside beautifiedURL: URL) {
        let baseURL = Self.baseImageURL(for: beautifiedURL)
        try? FileManager.default.copyItem(at: rawURL, to: baseURL)
    }

    private static var baseStorageDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("BetterShot/bases", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func baseImageURL(for url: URL) -> URL {
        let name = url.deletingPathExtension().lastPathComponent
        return baseStorageDir.appendingPathComponent("\(name).base.png")
    }

    static func resolveRawSource(for url: URL) -> URL {
        let baseURL = baseImageURL(for: url)
        if FileManager.default.fileExists(atPath: baseURL.path) {
            return baseURL
        }
        // Legacy: check alongside the file for old .base.png files
        let legacyDir = url.deletingLastPathComponent()
        let legacyName = url.deletingPathExtension().lastPathComponent
        let legacyURL = legacyDir.appendingPathComponent("\(legacyName).base.png")
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            return legacyURL
        }
        return url
    }

    private func copyToClipboard(_ url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([nsImage])
    }
}
