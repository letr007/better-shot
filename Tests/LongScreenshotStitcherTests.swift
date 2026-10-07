import CoreGraphics
import Foundation
import Darwin

/// Standalone CoreGraphics checks; run with `make test-stitcher`.
@main
struct LongScreenshotStitcherTests {
    static let width = 128
    static let height = 320

    static func frame(scroll: Int, header: Int = 0, footer: Int = 0, height: Int = height, blankAfter: Int? = nil) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value: UInt8
                if y < header {
                    value = UInt8(20 + x % 17)
                } else if y >= height - footer {
                    value = UInt8(225 + x % 17)
                } else {
                    let row = y - header + scroll
                    if let blankAfter, row >= blankAfter {
                        value = 255
                    } else {
                        let rowHash = (row * 73) ^ (row * row * 11)
                        value = UInt8(20 + rowHash % 140 + (x * 17 + row * 5) % 70)
                    }
                }
                let index = (y * width + x) * 4
                bytes[index] = value
                bytes[index + 1] = value
                bytes[index + 2] = value
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    static func pixels(_ image: CGImage) -> [UInt8] {
        let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(
            start: context.data!.assumingMemoryBound(to: UInt8.self),
            count: context.bytesPerRow * image.height
        ))
    }

    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw NSError(domain: "LongScreenshotTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func checkScrolls(_ offsets: [Int], header: Int = 0, footer: Int = 0, blankAfter: Int? = nil) throws {
        var stitcher = try LongScreenshotStitcher(initialImage: frame(scroll: 0, header: header, footer: footer, blankAfter: blankAfter))
        var total = 0
        for offset in offsets {
            total += offset
            let result = try stitcher.append(frame(scroll: total, header: header, footer: footer, blankAfter: blankAfter))
            guard case .appended(let image, let overlap) = result else {
                throw NSError(domain: "LongScreenshotTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected append at offset \(offset), got \(result)"])
            }
            try expect(overlap == height - offset, "Wrong overlap: \(overlap), expected \(height - offset)")
            try expect(image.height == height + total, "Wrong output height: \(image.height)")
            let expected = frame(scroll: 0, header: header, footer: footer, height: height + total, blankAfter: blankAfter)
            try expect(pixels(image) == pixels(expected), "Stitched pixels differ at header=\(header), footer=\(footer), scroll=\(total)")
        }
    }

    static func main() {
        let cases: [(String, () throws -> Void)] = [
            ("downward scroll and variable steps", { try checkScrolls([64, 32, 70]) }),
            ("large overlapping scroll", { try checkScrolls([240]) }),
            ("fixed asymmetric header and footer", { try checkScrolls([64, 32], header: 80, footer: 16) }),
            ("small scroll with fixed footer", { try checkScrolls([16, 20], header: 16, footer: 64) }),
            ("new content ending in blank rows", { try checkScrolls([32], blankAfter: 280) }),
            ("identical frame", {
                let initial = frame(scroll: 0)
                var stitcher = try LongScreenshotStitcher(initialImage: initial)
                guard case .duplicate = try stitcher.append(initial) else {
                    try expect(false, "Identical frame was not a duplicate"); return
                }
                try expect(pixels(stitcher.image) == pixels(initial), "Duplicate changed the image")
            }),
            ("no overlap retains baseline", {
                let initial = frame(scroll: 0)
                var stitcher = try LongScreenshotStitcher(initialImage: initial)
                guard case .skipped = try stitcher.append(frame(scroll: 640)) else {
                    try expect(false, "Non-overlapping frame was accepted"); return
                }
                try expect(pixels(stitcher.image) == pixels(initial), "Skipped frame changed baseline")
                guard case .appended = try stitcher.append(frame(scroll: 32)) else {
                    try expect(false, "Baseline was lost after skipping"); return
                }
            }),
            ("reverse scroll is not appended", {
                var stitcher = try LongScreenshotStitcher(initialImage: frame(scroll: 64))
                guard case .skipped = try stitcher.append(frame(scroll: 0)) else {
                    try expect(false, "Reverse scroll was accepted"); return
                }
            }),
            ("frame size mismatch", {
                var stitcher = try LongScreenshotStitcher(initialImage: frame(scroll: 0))
                guard case .skipped = try stitcher.append(frame(scroll: 32, height: 300)) else {
                    try expect(false, "Size mismatch was accepted"); return
                }
            }),
            ("maximum height retains valid image", {
                var stitcher = try LongScreenshotStitcher(initialImage: frame(scroll: 0), maximumHeight: height + 16)
                do {
                    _ = try stitcher.append(frame(scroll: 64))
                    try expect(false, "Exceeded height was accepted")
                } catch LongScreenshotStitcher.StitchError.maximumHeightExceeded(let maximum) {
                    try expect(maximum == height + 16, "Wrong height limit")
                    try expect(stitcher.image.height == height, "Failed append changed the image")
                }
            })
        ]
        var failures = 0
        for (name, check) in cases {
            do {
                try check()
                print("PASS: \(name)")
            } catch {
                failures += 1
                print("FAIL: \(name): \(error.localizedDescription)")
            }
        }
        if failures > 0 {
            print("\(failures) of \(cases.count) stitcher checks failed.")
            exit(1)
        }
        print("All \(cases.count) stitcher checks passed.")
    }
}
