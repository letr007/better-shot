import AppKit
import Carbon
import Vision
@testable import BetterShot

/// Non-interactive checks for local additions; never requests permissions or writes real preferences.
@main
struct LocalCaptureIntegration {
    @MainActor static func main() throws {
        precondition(ProcessInfo.processInfo.environment["BETTERSHOT_TESTING"] == "1")
        try checkFrozenPixels()
        try checkOCR()
        try checkShortcutMigration()
        print("PASS frozen-frame pixels, Chinese/English OCR, and local shortcut migration")
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
