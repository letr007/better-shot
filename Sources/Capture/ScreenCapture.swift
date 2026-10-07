import AppKit
import Vision
import CoreGraphics
import ScreenCaptureKit

@MainActor
@Observable
final class ScreenCapture {
    static let shared = ScreenCapture()

    private(set) var isCapturing = false

    private init() {}

    // MARK: - Fullscreen 

    func captureFullscreen(on screen: NSScreen? = nil) async throws -> URL? {
        guard !isCapturing else { return nil }
        isCapturing = true
        defer { isCapturing = false }

        try? await Task.sleep(for: .milliseconds(200))

        let tempPath = makeTempPath()
        var args = ["-x", "-t", "png"]
        // Without -D, screencapture always grabs the main display, regardless
        // of which one is actually active -- so on a multi-monitor setup a
        // capture triggered with the mouse on a secondary screen would
        // silently save the wrong display's content while the preview card
        // still showed up on the right one. Resolve the same screen the
        // caller already picked (or fall back to the same follow-mouse /
        // pinned-display resolution the preview card uses) and target it
        // explicitly.
        let targetDisplayID = screen.flatMap(ActiveDisplayResolver.displayID(for:))
            ?? ActiveDisplayResolver.screenForScreenshotCapture().flatMap(ActiveDisplayResolver.displayID(for:))
        if let targetDisplayID, let index = ActiveDisplayResolver.screencaptureDisplayIndex(for: targetDisplayID) {
            args.append(contentsOf: ["-D", String(index)])
        } else {
            // Falling through here means screencapture grabs the main
            // display regardless of which one was actually active -- the
            // exact silent-wrong-display bug this whole fix exists to
            // prevent. Only expected to happen in a narrow race (e.g. the
            // target display disconnected between resolution and the sleep
            // above), but it should be diagnosable if it does.
            print("BetterShot: could not resolve target display for -D; screencapture will fall back to the main display")
        }
        args.append(tempPath)

        let success = try await runScreencapture(args, output: tempPath)
        guard success, FileManager.default.fileExists(atPath: tempPath) else { return nil }
        return URL(fileURLWithPath: tempPath)
    }

    // MARK: - Region

    /// Opens BetterShot's adjustable selector, including the capture-on-release setting.
    func captureRegion() async throws -> URL? {
        guard !isCapturing else { return nil }
        isCapturing = true
        defer { isCapturing = false }

        if AppPreferences.regionCaptureMode == .frozen {
            return try await captureFrozenRegion()
        }

        switch await RegionSelectionOverlay().selectRegion() {
        case .cancelled:
            return nil
        case .window:
            return try await interactiveShot(window: true, includeShadow: false)
        case .region(let selection):
            return try await regionShot(selection.pointsRect)
        }
    }

    /// Selection and cropping share the same snapshots; confirming never captures a later live frame.
    private func captureFrozenRegion() async throws -> URL? {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw FrozenCaptureError.permissionRequired
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let excludedApps = PreviewWindowCaptureExclusion.includesAppWindowsInCaptures
            ? [] : content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        var frames: [CGDirectDisplayID: FrozenRegionFrame] = [:]
        var backgrounds: [CGDirectDisplayID: NSImage] = [:]
        for screen in NSScreen.screens {
            guard let displayID = ActiveDisplayResolver.displayID(for: screen),
                  let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw FrozenCaptureError.displayUnavailable
            }
            let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = Int(screen.frame.width * CGFloat(filter.pointPixelScale))
            configuration.height = Int(screen.frame.height * CGFloat(filter.pointPixelScale))
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            frames[displayID] = FrozenRegionFrame(
                image: image,
                displayRect: RegionGeometry.pointsRect(global: screen.frame, primaryHeight: primaryHeight)
            )
            backgrounds[displayID] = NSImage(cgImage: image, size: screen.frame.size)
        }
        guard !frames.isEmpty else { throw FrozenCaptureError.displayUnavailable }
        switch await RegionSelectionOverlay().selectRegion(backgrounds: backgrounds) {
        case .cancelled:
            return nil
        case .window:
            return try await interactiveShot(window: true, includeShadow: false)
        case .region(let selection):
            guard let frame = frames[selection.displayID] else { throw FrozenCaptureError.displayUnavailable }
            let image = try frame.crop(to: selection.pointsRect)
            let url = URL(fileURLWithPath: makeTempPath())
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: url, options: .atomic)
            return url
        }
    }

    struct FrozenRegionFrame {
        let image: CGImage
        let displayRect: CGRect

        func crop(to pointsRect: CGRect) throws -> CGImage {
            guard let pixelRect = RegionGeometry.pixelRect(
                pointsRect: pointsRect, displayRect: displayRect,
                pixelSize: CGSize(width: image.width, height: image.height)
            ), let cropped = image.cropping(to: pixelRect) else {
                throw FrozenCaptureError.invalidRegion
            }
            return cropped
        }
    }

    enum FrozenCaptureError: LocalizedError {
        case permissionRequired, displayUnavailable, invalidRegion

        var errorDescription: String? {
            switch self {
            case .permissionRequired:
                return NSLocalizedString("Allow BetterShot in Screen & System Audio Recording in System Settings, then quit and reopen BetterShot.", comment: "Screen recording permission")
            case .displayUnavailable:
                return NSLocalizedString("The selected display is no longer available.", comment: "Frozen screenshot display unavailable")
            case .invalidRegion:
                return NSLocalizedString("Could not capture the selected area.", comment: "Invalid frozen screenshot region")
            }
        }
    }

    /// Captures the remembered rectangle straight away, no selection overlay.
    func captureLastRegion() async throws -> URL? {
        guard !isCapturing, let globalRect = AppPreferences.lastRegionRect else { return nil }
        isCapturing = true
        defer { isCapturing = false }
        let pointsRect = RegionGeometry.pointsRect(global: globalRect, primaryHeight: CGDisplayBounds(CGMainDisplayID()).height)
        return try await regionShot(pointsRect)
    }

    private func regionShot(_ pointsRect: CGRect) async throws -> URL? {
        try? await Task.sleep(for: .milliseconds(80))
        let tempPath = makeTempPath()
        let region = RegionGeometry.screencaptureArgument(pointsRect)
        let success = try await runScreencapture(["-R", region, "-x", "-t", "png", tempPath], output: tempPath)
        guard success, FileManager.default.fileExists(atPath: tempPath) else { return nil }
        return URL(fileURLWithPath: tempPath)
    }

    // MARK: - Window

    func captureWindow(includeShadow: Bool = false) async throws -> URL? {
        guard !isCapturing else { return nil }
        isCapturing = true
        defer { isCapturing = false }
        return try await interactiveShot(window: true, includeShadow: includeShadow)
    }

    private func interactiveShot(window: Bool, includeShadow: Bool) async throws -> URL? {
        let tempPath = makeTempPath()
        var arguments = ["-i", "-x", "-t", "png"]
        if window { arguments.append("-w") }
        if !includeShadow { arguments.append("-o") }
        arguments.append(tempPath)
        let success = try await runScreencapture(arguments, output: tempPath)
        guard success, FileManager.default.fileExists(atPath: tempPath) else { return nil }
        return URL(fileURLWithPath: tempPath)
    }

    // MARK: - OCR Region

    func captureAndOCR() async throws -> String? {
        guard !isCapturing else { return nil }
        isCapturing = true
        defer { isCapturing = false }
        guard let url = try await interactiveShot(window: false, includeShadow: false) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }

        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        return try await recognizeContent(in: cgImage)
    }

    private func recognizeContent(in image: CGImage) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let barcodeRequest = VNDetectBarcodesRequest()

            let handler = VNImageRequestHandler(cgImage: image)
            do {
                let textRequest = try Self.textRecognitionRequest()
                try handler.perform([textRequest, barcodeRequest])

                var parts: [String] = []

                // QR/Barcode results first
                if let barcodeResults = barcodeRequest.results {
                    for barcode in barcodeResults {
                        if let payload = barcode.payloadStringValue, !payload.isEmpty {
                            parts.append(payload)
                        }
                    }
                }

                // Text results
                if let textResults = textRequest.results {
                    let text = textResults
                        .compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: "\n")
                    if !text.isEmpty {
                        parts.append(text)
                    }
                }

                continuation.resume(returning: parts.joined(separator: "\n"))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    static func textRecognitionRequest() throws -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"].filter(supported.contains)
        return request
    }

    // MARK: - Sound

    func playShutterSound() {
        guard AppPreferences.playSound else { return }
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        let url = URL(fileURLWithPath: path)
        if let sound = NSSound(contentsOf: url, byReference: true) {
            sound.play()
        }
    }

    // MARK: - Helpers

    private func makeTempPath() -> String {
        ScreenshotFileNaming.scratchURL("Capture", extension: "png").path
    }

    private func runScreencapture(_ arguments: [String], output: String) async throws -> Bool {
        switch try await ScreencaptureRunner.run(arguments, output: output) {
        case .saved: true
        case let .exited(status, diagnostic): try Self.validateCommandResult(status: status, diagnostic: diagnostic)
        }
    }

    /// Interactive cancellation has no diagnostic; actual failures must reach the user.
    nonisolated static func validateCommandResult(status: Int32, diagnostic: String) throws -> Bool {
        if status == 0 { return true }
        let message = diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
        if status == 1 && message.isEmpty { return false }
        throw NSError(domain: "BetterShot.ScreenCapture", code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: "\(message.isEmpty ? "macOS could not create the screenshot." : message) Try again. If this continues, quit and reopen BetterShot and check Screen & System Audio Recording permission in System Settings."
        ])
    }

}
