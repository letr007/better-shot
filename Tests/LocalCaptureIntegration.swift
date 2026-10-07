import AppKit
import Carbon
import Vision
import ImageIO
import UniformTypeIdentifiers
@testable import BetterShot

/// Non-interactive checks for local additions; never requests permissions or writes real preferences.
@main
struct LocalCaptureIntegration {
    @MainActor static func main() throws {
        precondition(ProcessInfo.processInfo.environment["BETTERSHOT_TESTING"] == "1")
        try checkFrozenPixels()
        try checkTransparentBackground()
        try checkOCR()
        try checkShortcutMigration()
        print("PASS frozen-frame pixels, transparent backgrounds, Chinese/English OCR, and local shortcut migration")
    }

    @MainActor static func checkFrozenPixels() throws {
        let width = 80, height = 60
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                bytes[offset] = UInt8(x)
                bytes[offset + 1] = UInt8(y)
                bytes[offset + 2] = 90
            }
        }
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)!
        let frame = ScreenCapture.FrozenRegionFrame(image: image,
            displayRect: CGRect(x: 1440, y: -300, width: 40, height: 30))
        let cropped = try frame.crop(to: CGRect(x: 1450, y: -290, width: 12, height: 10))
        precondition(cropped.width == 24 && cropped.height == 20, "Retina crop retains native resolution")
        let context = CGContext(data: nil, width: cropped.width, height: cropped.height,
            bitsPerComponent: 8, bytesPerRow: cropped.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<cropped.height {
            for x in 0..<cropped.width {
                let offset = y * context.bytesPerRow + x * 4
                precondition(data[offset] == UInt8(20 + x) && data[offset + 1] == UInt8(20 + y),
                    "Selection must crop the saved frame without flipping rows or recapturing")
            }
        }
        do {
            _ = try frame.crop(to: CGRect(x: 2000, y: 0, width: 10, height: 10))
            preconditionFailure("Out-of-display selection must fail")
        } catch ScreenCapture.FrozenCaptureError.invalidRegion {}
        precondition(RegionCaptureMode(rawValue: "frozen") == .frozen)
        precondition(RegionCaptureMode(rawValue: "system") == .system, "Legacy mode key retains its stored value")
        print("PASS saved-frame crop: secondary origin, Retina dimensions, all pixels, and invalid selection")
    }

    @MainActor static func checkTransparentBackground() throws {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let sourceContext = CGContext(data: nil, width: 128, height: 80,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        sourceContext.setFillColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1)
        sourceContext.fill(CGRect(x: 0, y: 0, width: 128, height: 80))
        let source = sourceContext.makeImage()!
        var config = BeautifierConfig()
        config.style = .solid(.transparent)
        config.padding = 0.25
        config.cornerRadius = 0.1
        config.shadowStrength = 0
        let capture = BeautifierRenderer.render(image: source, config: config)!
        let editor = try AnnotationBackgroundRenderer.compose(contentImage: source,
            settings: config.annotationBackgroundSettings, colorSpace: colorSpace)

        for image in [capture, editor] {
            precondition(image.width == 168 && image.height == 120, "Transparent background retains padding")
            let pixels = rgbaPixels(image)
            precondition(alpha(pixels, width: image.width, x: 0, y: 0) == 0, "No preview checkerboard or color is exported")
            precondition(alpha(pixels, width: image.width, x: 84, y: 60) == 255, "Screenshot pixels remain opaque")
            precondition(alpha(pixels, width: image.width, x: 20, y: 20) == 0, "Rounded screenshot corners remain transparent")
            let offset = (60 * image.width + 84) * 4
            precondition(abs(Int(pixels[offset]) - 51) <= 1 && abs(Int(pixels[offset + 1]) - 153) <= 1,
                         "Transparent fill must not recolor the screenshot")
        }

        var shadowConfig = config
        shadowConfig.shadowStrength = 0.6
        let shadowCapture = BeautifierRenderer.render(image: source, config: shadowConfig)!
        let shadowEditor = try AnnotationBackgroundRenderer.compose(contentImage: source,
            settings: shadowConfig.annotationBackgroundSettings, colorSpace: colorSpace)
        for image in [shadowCapture, shadowEditor] {
            let pixels = rgbaPixels(image)
            var hasShadow = false
            for y in 0..<image.height {
                for x in 0..<image.width where x < 20 || x >= 148 || y < 20 || y >= 100 {
                    let value = alpha(pixels, width: image.width, x: x, y: y)
                    if value > 0 && value < 255 { hasShadow = true }
                }
            }
            precondition(hasShadow, "Shadow must remain visible on a transparent canvas")
            precondition(alpha(pixels, width: image.width, x: 0, y: 0) == 0)
        }

        var squareConfig = config
        squareConfig.aspectRatio = .square
        let squareCapture = BeautifierRenderer.render(image: source, config: squareConfig)!
        let squareEditor = try AnnotationBackgroundRenderer.compose(contentImage: source,
            settings: squareConfig.annotationBackgroundSettings, colorSpace: colorSpace)
        precondition(squareCapture.width == 168 && squareCapture.height == 168)
        precondition(squareEditor.width == 168 && squareEditor.height == 168)
        var bare = squareConfig
        bare.style = .none
        precondition(BeautifierRenderer.render(image: source, config: bare) === source, "No Background still returns the source without decorations")
        let bareEditor = try AnnotationBackgroundRenderer.compose(contentImage: source,
            settings: bare.annotationBackgroundSettings, colorSpace: colorSpace)
        precondition(bareEditor.width == source.width && bareEditor.height == source.height)
        precondition(rgbaPixels(bareEditor) == rgbaPixels(source))

        let stored = try JSONDecoder().decode(StoredBackground.self,
            from: JSONEncoder().encode(StoredBackground(shadowConfig.annotationBackgroundSettings)))
        precondition(stored.settings == shadowConfig.annotationBackgroundSettings, "Saved editor presets preserve transparent fill and decorations")

        precondition(Bundle.main.bundleIdentifier != "com.bettershot.app", "Never change real application preferences in a test")
        let defaults = UserDefaults.standard
        let keys = ["bs_defaultBeautifierConfig", "bs_exportFormat"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        AppPreferences.defaultBeautifierConfig = config
        precondition(RecordingStudioDefaults.style.background == .none, "Screenshot transparency does not become an opaque black video frame")
        var opaqueConfig = config
        opaqueConfig.style = .solid(SolidColor.presets[0])
        AppPreferences.defaultBeautifierConfig = opaqueConfig
        precondition(RecordingStudioDefaults.style.background == opaqueConfig.annotationStyle, "Opaque video defaults keep their existing fill")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TransparentBackgroundCheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        AppPreferences.exportFormat = .png
        let captureURL = CaptureOrchestrator.saveImage(shadowCapture, named: "capture.png", in: directory.path)!
        let sourceURL = CaptureOrchestrator.saveImage(source, named: "source.png", in: directory.path)!
        let editorURL = directory.appendingPathComponent("edited.png")
        try AnnotationRenderer.render(sourceURL: sourceURL, shapes: [],
            backgroundSettings: shadowConfig.annotationBackgroundSettings,
            destinationURL: editorURL, contentType: .png)
        for (url, expected) in [(captureURL, shadowCapture), (editorURL, shadowEditor)] {
            let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil)!
            let decoded = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)!
            precondition(rgbaPixels(decoded) == rgbaPixels(expected), "PNG save/reopen must preserve actual transparency pixels")
        }
        print("PASS transparent capture/editor backgrounds: alpha, rounded corners, padding, shadow, aspect ratio, PNG roundtrip, preset persistence, No Background, and video defaults")
    }

    private static func alpha(_ pixels: [UInt8], width: Int, x: Int, y: Int) -> UInt8 {
        pixels[(y * width + x) * 4 + 3]
    }

    private static func rgbaPixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    @MainActor static func checkOCR() throws {
        let request = try ScreenCapture.textRecognitionRequest()
        precondition(request.recognitionLevel == .accurate && request.usesLanguageCorrection)
        precondition(request.recognitionLanguages == ["zh-Hans", "zh-Hant", "en-US"], "Chinese and English must be configured")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1000, pixelsHigh: 180,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        CGRect(x: 0, y: 0, width: 1000, height: 180).fill()
        let font = NSFont(name: "PingFangSC-Regular", size: 48) ?? .systemFont(ofSize: 48)
        NSAttributedString(string: "中文截图测试 繁體中文 English 123", attributes: [
            .font: font, .foregroundColor: NSColor.black
        ]).draw(at: CGPoint(x: 30, y: 70))
        NSGraphicsContext.restoreGraphicsState()
        try VNImageRequestHandler(cgImage: bitmap.cgImage!).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        precondition(text.contains("中文") && text.contains("繁體") && text.contains("English") && text.contains("123"),
            "Mixed Chinese/English recognition failed: \(text)")
        print("PASS mixed OCR: \(text)")
    }

    @MainActor static func checkShortcutMigration() throws {
        func withDefaults(_ check: (UserDefaults) throws -> Void) rethrows {
            let name = "LocalCaptureIntegration-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            try check(defaults)
        }
        let custom = ShortcutService.Shortcut(keyCode: UInt32(kVK_ANSI_6), modifiers: UInt32(cmdKey | shiftKey), enabled: false)
        let window = ShortcutService.Shortcut.defaultRecordingOptions
        let customData = try JSONEncoder().encode(custom)
        let windowData = try JSONEncoder().encode(window)
        withDefaults { defaults in
            defaults.set("frozen", forKey: "bs_regionCaptureMode")
            defaults.set(customData, forKey: "bs_hotkey_7")
            defaults.set(windowData, forKey: "bs_hotkey_3")
            let service = ShortcutService(defaults: defaults)
            precondition(service.loadShortcut(for: .scrollCapture) == custom, "Customized/disabled local scroll binding must move to upstream ID 26")
            precondition(service.loadShortcut(for: .window) == window)
            precondition(service.effectiveShortcut(for: .recordingOptions) == nil, "Options must not steal the existing window shortcut")
            _ = ShortcutService(defaults: defaults)
            precondition(service.loadShortcut(for: .scrollCapture) == custom, "Migration is idempotent")
        }
        withDefaults { defaults in
            defaults.set("frozen", forKey: "bs_regionCaptureMode")
            defaults.set(true, forKey: "bs_captureShortcuts050Restored")
            defaults.set(windowData, forKey: "bs_hotkey_7")
            let service = ShortcutService(defaults: defaults)
            precondition(service.loadShortcut(for: .recordingOptions) == window, "Existing upstream settings must not be reinterpreted")
            precondition(service.loadShortcut(for: .scrollCapture) == nil)
        }
        withDefaults { defaults in
            defaults.set("system", forKey: "bs_regionCaptureMode")
            defaults.set(customData, forKey: "bs_hotkey_7")
            defaults.set(windowData, forKey: "bs_hotkey_26")
            let service = ShortcutService(defaults: defaults)
            precondition(service.loadShortcut(for: .scrollCapture) == window, "Existing destination binding wins")
        }
        withDefaults { defaults in
            let service = ShortcutService(defaults: defaults)
            precondition(service.loadShortcut(for: .recordingOptions) == nil, "New installs retain upstream defaults")
            precondition(service.effectiveShortcut(for: .recordingOptions) == .defaultRecordingOptions)
        }
        print("PASS local shortcut upgrade: ID remap, disabled states, window conflict, idempotence, upstream and fresh installs")
    }
}
