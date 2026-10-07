import Foundation
import SwiftUI

@main
enum DefaultLookMappingCheck {
    static func main() throws {
        var config = BeautifierConfig()
        config.padding = 0.18
        config.cornerRadius = 0.18
        config.shadowStrength = 0.5
        config.style = .solid(SolidColor(id: "cobalt", name: "Cobalt", red: 0.16, green: 0.50, blue: 0.88))
        config.alignment = .bottomLeading
        config.aspectRatio = .sixteenNine

        let settings = config.annotationBackgroundSettings
        assert(settings.padding == 0.18, "padding must carry over")
        assert(settings.cornerRadius == 0.18, "corner radius must carry over")
        assert(settings.shadow == 0.5, "shadow must map from shadowStrength")
        assert(settings.alignment == .bottomLeading, "alignment must carry over")
        assert(settings.aspectRatio == .sixteenNine, "aspect ratio must carry over")
        guard case .solid(let color) = settings.style else { fatalError("expected solid style") }
        assert(color.id == "cobalt" && abs(color.red - 0.16) < 0.0001 && color.alpha == 1, "solid color must carry over with default opaque alpha")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let legacyColorJSON = Data(#"{"id":"cobalt","name":"Cobalt","red":0.16,"green":0.50,"blue":0.88}"#.utf8)
        let legacyColor = try decoder.decode(SolidColor.self, from: legacyColorJSON)
        assert(legacyColor.alpha == 1 && config.style == .solid(legacyColor), "legacy RGB-only colors must decode as opaque")
        var legacyConfigJSON = try JSONSerialization.jsonObject(with: encoder.encode(config)) as! [String: Any]
        legacyConfigJSON["style"] = ["solid": ["_0": try JSONSerialization.jsonObject(with: legacyColorJSON)]]
        let legacyConfig = try decoder.decode(BeautifierConfig.self, from: JSONSerialization.data(withJSONObject: legacyConfigJSON))
        assert(legacyConfig == config, "legacy config JSON without solid color alpha must preserve the opaque look")
        assert(legacyConfig.annotationBackgroundSettings.style == settings.style, "legacy config must map to opaque annotation colors")

        assert(SolidColor.presets.map(\.id) == [
            "obsidian", "chalk", "slate", "ember", "tangerine", "saffron",
            "fern", "cobalt", "iris", "rose", "seafoam", "cloud"
        ], "the ordinary solid preset list must remain unchanged")
        assert(AnnotationBackgroundColor.plainPresets.map(\.id) == [
            "black", "white", "graphite", "red", "orange", "yellow", "green", "blue",
            "purple", "blush", "mint", "sky", "lavender", "peach", "sage", "sand"
        ], "the ordinary annotation preset list must remain unchanged")
        assert(SolidColor.presets.allSatisfy { $0.alpha == 1 }, "ordinary solid presets must remain opaque")
        assert(AnnotationBackgroundColor.plainPresets.allSatisfy { $0.alpha == 1 }, "ordinary annotation presets must remain opaque")

        for alpha in [0.0, 0.5] {
            let alphaColor = SolidColor(id: "alpha-color", name: "Alpha Color", red: 0.2, green: 0.4, blue: 0.6, alpha: alpha)
            let restoredColor = try decoder.decode(SolidColor.self, from: encoder.encode(alphaColor))
            assert(restoredColor == alphaColor, "solid color JSON must preserve RGB and alpha")
            assert(alphaColor.color.cgColor?.alpha == CGFloat(alpha), "SwiftUI colors must preserve alpha")
            assert(alphaColor.nsColor.alphaComponent == alpha, "AppKit colors must preserve alpha")
            assert(alphaColor.cgColor.alpha == alpha, "CoreGraphics colors must preserve alpha")

            var alphaConfig = config
            alphaConfig.style = .solid(alphaColor)
            let restoredConfig = try decoder.decode(BeautifierConfig.self, from: encoder.encode(alphaConfig))
            assert(restoredConfig == alphaConfig, "config JSON must preserve transparent and translucent solid colors")
            let alphaSettings = restoredConfig.annotationBackgroundSettings
            guard case .solid(let annotationColor) = alphaSettings.style else {
                fatalError("transparent and translucent backgrounds must use the solid style")
            }
            assert(annotationColor.alpha == alpha, "Default Look mapping must preserve solid alpha")
            assert(alphaSettings.style.captureBackgroundStyle == alphaConfig.style, "annotation-to-capture mapping must preserve solid color and alpha")
            assert(alphaSettings.isEnabled && alphaSettings.usesCanvasLayout && alphaSettings.requiresCanvasLayout && alphaSettings.hasRenderableContent,
                   "solid colors must keep canvas framing enabled even at zero alpha")
            assert(alphaSettings.padding == settings.padding && alphaSettings.cornerRadius == settings.cornerRadius && alphaSettings.shadow == settings.shadow,
                   "transparent and translucent backgrounds must retain padding, corners, and shadow")
            assert(alphaSettings.alignment == settings.alignment && alphaSettings.aspectRatio == settings.aspectRatio,
                   "transparent and translucent backgrounds must retain alignment and aspect ratio")

            let customAlpha = AnnotationBackgroundColor.custom(from: Color(.sRGB, red: 0.2, green: 0.4, blue: 0.6, opacity: alpha))
            assert(abs(customAlpha.red - 0.2) < 0.0001 && abs(customAlpha.green - 0.4) < 0.0001 && abs(customAlpha.blue - 0.6) < 0.0001 && customAlpha.alpha == alpha,
                   "custom background colors must preserve sRGB components and alpha")
            var customAlphaConfig = config
            customAlphaConfig.style = AnnotationBackgroundStyle.solid(customAlpha).captureBackgroundStyle
            assert(customAlphaConfig.annotationBackgroundSettings.style == .solid(customAlpha), "annotation solid alpha must survive both mapping directions")
        }

        assert(SolidColor.transparent.id == "transparent" && SolidColor.transparent.name == "Transparent Background", "transparent solid preset must have a stable identifier and title")
        assert(AnnotationBackgroundColor.transparent.id == "transparent" && AnnotationBackgroundColor.transparent.title == "Transparent Background", "transparent annotation preset must have a stable identifier and title")
        assert(SolidColor.transparent.alpha == 0 && SolidColor.transparent.cgColor.alpha == 0 && SolidColor.transparent.color.cgColor?.alpha == 0,
               "transparent solid preset must produce transparent colors")
        assert(AnnotationBackgroundColor.transparent.alpha == 0 && AnnotationBackgroundColor.transparent.nsColor.cgColor.alpha == 0,
               "transparent annotation preset must produce transparent colors")
        var transparentConfig = config
        transparentConfig.style = .solid(.transparent)
        let transparentSettings = transparentConfig.annotationBackgroundSettings
        assert(transparentSettings.style == .solid(.transparent), "transparent preset must map to the annotation transparent solid preset")
        assert(transparentSettings.style.captureBackgroundStyle == transparentConfig.style, "transparent preset must survive the capture mapping")
        assert(transparentSettings.isEnabled && transparentSettings.usesCanvasLayout, "transparent preset must enable the existing solid canvas path")
        assert(transparentSettings.padding == settings.padding && transparentSettings.cornerRadius == settings.cornerRadius && transparentSettings.shadow == settings.shadow,
               "transparent preset must retain framing decorations")

        var noneConfig = config
        noneConfig.style = .none
        let noneSettings = noneConfig.annotationBackgroundSettings
        assert(noneSettings.style == .none && noneSettings.style.captureBackgroundStyle == .none, "no background must remain no background in both mappings")
        assert(!noneSettings.isEnabled && !noneSettings.usesCanvasLayout && !noneSettings.requiresCanvasLayout && !noneSettings.hasRenderableContent,
               "no background must keep raw-image layout without padding, rounded corners, or shadow")
        assert(noneSettings.padding == settings.padding && noneSettings.cornerRadius == settings.cornerRadius && noneSettings.shadow == settings.shadow,
               "no background must retain dormant framing preferences for reuse")
        assert(noneSettings.effectiveCanvasAlignment == .center, "no background must not apply canvas alignment")

        let custom = AnnotationBackgroundColor.custom(from: Color(.sRGB, red: 0.2, green: 0.4, blue: 0.6))
        assert(custom.id == "custom" && abs(custom.green - 0.4) < 0.0001 && custom.alpha == 1, "custom color must keep its sRGB components")
        var customConfig = BeautifierConfig()
        customConfig.style = AnnotationBackgroundStyle.solid(custom).captureBackgroundStyle
        guard case .solid(let restoredCustom) = customConfig.annotationBackgroundSettings.style else {
            fatalError("expected custom solid style")
        }
        assert(restoredCustom == custom, "custom color must survive the Default Look round trip")

        let preset = GradientPreset.presets[0]
        var gradientConfig = BeautifierConfig()
        gradientConfig.style = .gradient(preset)
        guard case .gradient(let gradient) = gradientConfig.annotationBackgroundSettings.style else {
            fatalError("expected gradient style")
        }
        assert(gradient.id == preset.id, "gradient id must carry over")
        assert(gradient.colors.count == preset.stops.count, "every gradient stop must map")
        assert(gradient.startPoint == preset.startPoint.unitPoint, "gradient start point must carry over")
        assert(gradient.endPoint == preset.endPoint.unitPoint, "gradient end point must carry over")

        var wallpaperConfig = BeautifierConfig()
        wallpaperConfig.style = .wallpaper(WallpaperSource(path: "/tmp/wall.jpg"))
        let wallpaperSettings = wallpaperConfig.annotationBackgroundSettings
        guard case .customWallpaper(let wallpaper) = wallpaperSettings.style else {
            fatalError("expected custom wallpaper style")
        }
        assert(wallpaper.url.path == "/tmp/wall.jpg", "wallpaper path must carry over")
        assert(wallpaperSettings.customWallpaper == wallpaper, "customWallpaper must mirror the style")

        var bundledConfig = BeautifierConfig()
        bundledConfig.style = .bundledImage("not-a-real-asset")
        assert(bundledConfig.annotationBackgroundSettings.style == .none, "missing bundled asset must fall back to none")

        var portraitConfig = BeautifierConfig()
        portraitConfig.aspectRatio = .nineSixteen
        assert(portraitConfig.annotationBackgroundSettings.aspectRatio == .auto, "9:16 has no editor twin, must fall back to auto")

        assert(BeautifierConfig().annotationBackgroundSettings.style == .none, "default config must map to no background")

        print("Default look mapping preserves alpha, legacy JSON, transparent solid framing, no-background layout, and preset lists")
    }
}
