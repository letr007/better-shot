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

    func captureFullscreen() async throws -> URL? {
        try requireScreenRecordingPermission()
        guard !isCapturing else { return nil }
        isCapturing = true
        defer { isCapturing = false }

        try? await Task.sleep(for: .milliseconds(200))

        let tempPath = makeTempPath()
        let success = await runScreencapture(["-x", "-t", "png", tempPath])
        guard success, FileManager.default.fileExists(atPath: tempPath) else { return nil }
        return URL(fileURLWithPath: tempPath)
    }

    // MARK: - Display image and viewport crop

    enum CaptureError: LocalizedError {
        case screenRecordingPermissionRequired
        case displayUnavailable
        case invalidViewport

        var errorDescription: String? {
            switch self {
            case .screenRecordingPermissionRequired:
                return L10n.string("Allow BetterShot in Screen & System Audio Recording in System Settings, then quit and reopen BetterShot.")
            case .displayUnavailable:
                return L10n.string("The selected display is no longer available.")
            case .invalidViewport:
                return L10n.string("Could not capture the selected area.")
            }
        }
    }

    func requireScreenRecordingPermission() throws {
        guard CGPreflightScreenCaptureAccess() else {
            // A newly granted permission may require restarting this process.
            // Never treat the desktop-only image available without permission as a capture.
            _ = CGRequestScreenCaptureAccess()
            throw CaptureError.screenRecordingPermissionRequired
        }
    }

    /// Reuses a display filter throughout a scroll session and excludes capture controls.
    func prepareDisplayCapture(on screen: NSScreen, excludingOwnApplication: Bool = false) async throws -> DisplayCapture {
        try requireScreenRecordingPermission()
        guard let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw CaptureError.displayUnavailable
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayNumber.uint32Value }) else {
            throw CaptureError.displayUnavailable
        }
        let excludedApplications = excludingOwnApplication
            ? content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            : []
        let filter = SCContentFilter(display: display, excludingApplications: excludedApplications, exceptingWindows: [])
        return DisplayCapture(filter: filter, pointSize: screen.frame.size, scale: CGFloat(filter.pointPixelScale))
    }

    @MainActor
    struct DisplayCapture {
        fileprivate let filter: SCContentFilter
        fileprivate let pointSize: CGSize
        fileprivate let scale: CGFloat

        /// Viewports are screen-local AppKit points; ScreenCaptureKit uses a top-left origin.
        func image(viewport: CGRect? = nil) async throws -> CGImage {
            let viewport = viewport ?? CGRect(origin: .zero, size: pointSize)
            let pixels = CGRect(
                x: viewport.minX * scale,
                y: (pointSize.height - viewport.maxY) * scale,
                width: viewport.width * scale,
                height: viewport.height * scale
            ).integral.intersection(CGRect(x: 0, y: 0, width: pointSize.width * scale, height: pointSize.height * scale))
            guard !pixels.isNull, pixels.width > 0, pixels.height > 0, scale > 0 else {
                throw CaptureError.invalidViewport
            }
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = CGRect(
                x: pixels.minX / scale, y: pixels.minY / scale,
                width: pixels.width / scale, height: pixels.height / scale
            )
            configuration.width = Int(pixels.width)
            configuration.height = Int(pixels.height)
            configuration.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        }
    }

    /// Crops a screen-local viewport expressed in AppKit points (bottom-left origin).
    func crop(_ image: CGImage, to viewport: CGRect, on screen: NSScreen) -> CGImage? {
        let scaleX = CGFloat(image.width) / screen.frame.width
        let scaleY = CGFloat(image.height) / screen.frame.height
        let rawRect = CGRect(
            x: viewport.minX * scaleX,
            y: (screen.frame.height - viewport.maxY) * scaleY,
            width: viewport.width * scaleX,
            height: viewport.height * scaleY
        ).integral
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let cropRect = rawRect.intersection(bounds)
        guard !cropRect.isNull, cropRect.width > 0, cropRect.height > 0 else { return nil }
        return image.cropping(to: cropRect)
    }

    // MARK: - Region

    func captureRegion() async throws -> URL? {
        try requireScreenRecordingPermission()
        guard !isCapturing else { return nil }
        isCapturing = true
        defer { isCapturing = false }

        let tempPath = makeTempPath()
        let success = await runScreencapture(["-s", "-x", "-t", "png", tempPath])
        guard success, FileManager.default.fileExists(atPath: tempPath) else { return nil }
        return URL(fileURLWithPath: tempPath)
    }

    // MARK: - Window (CLI screencapture -w)

    func captureWindow(includeShadow: Bool = false) async throws -> URL? {
        try requireScreenRecordingPermission()
        guard !isCapturing else { return nil }
        isCapturing = true
        defer { isCapturing = false }

        let tempPath = makeTempPath()
        var args = ["-w"]
        if !includeShadow { args.append("-o") }
        args.append(contentsOf: ["-x", "-t", "png", tempPath])

        let success = await runScreencapture(args)
        guard success, FileManager.default.fileExists(atPath: tempPath) else { return nil }
        return URL(fileURLWithPath: tempPath)
    }

    // MARK: - OCR Region

    func captureAndOCR() async throws -> String? {
        guard let url = try await captureRegion() else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }

        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        return try await recognizeContent(in: cgImage)
    }

    private func recognizeContent(in image: CGImage) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true

            let preferredLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            if let supportedLanguages = try? textRequest.supportedRecognitionLanguages() {
                textRequest.recognitionLanguages = preferredLanguages.filter(supportedLanguages.contains)
            }

            let barcodeRequest = VNDetectBarcodesRequest()

            let handler = VNImageRequestHandler(cgImage: image)
            do {
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
        let dir = NSTemporaryDirectory()
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        return "\(dir)bettershot_\(stamp).png"
    }

    private func runScreencapture(_ arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = arguments
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }
}
