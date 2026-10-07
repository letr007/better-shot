import CoreGraphics
import Foundation

/// Incrementally builds a long screenshot from equal-sized, downward-scrolled frames.
///
/// Alignment strategy (informed by production scroll-capture stitchers such as
/// Snapzy, ScrollShot and PowerToys ZoomIt):
/// 1. Detect the static header/footer band shared by consecutive frames and exclude
///    it from matching, so a fixed toolbar cannot veto the correct overlap.
/// 2. Compute per-row luminance profiles (central columns) and search vertical
///    offsets — first around the previous accepted offset (temporal prior), then
///    across the full feasible range — using 1D MAD for speed.
/// 3. Verify candidate offsets with 2D MAD over several horizontal strips and take
///    the winner. A single moving region (video, ad, loading spinner) cannot veto
///    the majority vote.
/// 4. Refine to pixel precision and composite only the newly revealed rows.
struct LongScreenshotStitcher: Sendable {
    enum Result: Sendable {
        /// The frame contributed new pixels.
        case appended(image: CGImage, overlap: Int)
        /// Consecutive frames are identical; no scroll happened.
        case duplicate
        /// The frame could not be aligned; the session should keep going.
        case skipped(message: String)
    }

    enum StitchError: Error, Equatable, LocalizedError {
        case invalidMaximumHeight
        case maximumHeightExceeded(maximum: Int)
        case imageCreationFailed

        var errorDescription: String? {
            switch self {
            case .invalidMaximumHeight:
                return "The maximum long-screenshot height must be positive."
            case .maximumHeightExceeded(let maximum):
                return "The stitched screenshot would exceed its maximum height of \(maximum) pixels."
            case .imageCreationFailed:
                return "The stitched image could not be created."
            }
        }
    }

    // MARK: - Tunables
    // fileprivate so the OffsetSearch helper (same file) can share them.

    fileprivate static let profileColumnFraction = 0.8
    fileprivate static let stripColumnFraction = 0.7
    fileprivate static let stripHeight = 14
    fileprivate static let stripFractions: [Double] = [0.10, 0.20, 0.30, 0.40, 0.50]
    fileprivate static let staticBandMinRows = 8
    fileprivate static let staticBandMADThreshold = 4.0
    fileprivate static let maximumStaticBandFraction = 0.33
    fileprivate static let minimumTexture = 1.0
    fileprivate static let duplicateMADThreshold = 3.0
    fileprivate static let verifyMADThreshold = 16.0
    fileprivate static let ambiguityRatio = 1.25
    fileprivate static let ambiguityOffsetGap = 12
    fileprivate static let refinementRange = 2
    fileprivate static let topOneDimensionalCandidates = 6
    fileprivate static let temporalPriorHalfRangeFraction = 0.5

    private let frameWidth: Int
    private let frameHeight: Int
    private let maximumHeight: Int
    private var previousFrame: CGImage
    private var headerHeight = 0
    private var footerHeight = 0
    private var staticBandsResolved = false
    private var lastOffset: Int?

    private(set) var image: CGImage

    init(initialImage: CGImage, maximumHeight: Int = 30_000) throws {
        guard maximumHeight > 0 else { throw StitchError.invalidMaximumHeight }
        guard initialImage.height <= maximumHeight else {
            throw StitchError.maximumHeightExceeded(maximum: maximumHeight)
        }
        frameWidth = initialImage.width
        frameHeight = initialImage.height
        self.maximumHeight = maximumHeight
        previousFrame = initialImage
        image = initialImage
    }

    /// Compares `frame` with the preceding frame and appends only its new bottom rows.
    mutating func append(_ frame: CGImage) throws -> Result {
        guard frame.width == frameWidth, frame.height == frameHeight else {
            return .skipped(message: "Frame size changed to \(frame.width)×\(frame.height).")
        }
        guard let previousPixels = try? PixelBuffer(image: previousFrame),
              let currentPixels = try? PixelBuffer(image: frame) else {
            return .skipped(message: "Could not decode frame pixels.")
        }

        guard !Self.isNearIdentical(previous: previousPixels, current: currentPixels) else {
            return .duplicate
        }

        let resolvingStaticBands = !staticBandsResolved
        if resolvingStaticBands {
            resolveStaticBands(previous: previousPixels, current: currentPixels)
        }

        let search = OffsetSearch(
            previous: previousPixels,
            current: currentPixels,
            headerHeight: headerHeight,
            footerHeight: footerHeight,
            expectedOffset: lastOffset
        )
        guard let offset = search.bestOffset else {
            if resolvingStaticBands {
                headerHeight = 0
                footerHeight = 0
            }
            return .skipped(message: "Could not align this frame — scroll slower or pause.")
        }

        let overlap = frameHeight - offset
        guard overlap >= Self.minimumOverlap(for: frameHeight) else {
            if resolvingStaticBands {
                headerHeight = 0
                footerHeight = 0
            }
            return .skipped(message: "Frames barely overlap — scroll slower.")
        }

        let outputHeight = image.height + offset
        guard outputHeight <= maximumHeight else {
            throw StitchError.maximumHeightExceeded(maximum: maximumHeight)
        }
        guard let stitched = Self.composite(
            image,
            with: frame,
            appending: offset,
            footerHeight: footerHeight
        ) else {
            throw StitchError.imageCreationFailed
        }

        staticBandsResolved = true
        lastOffset = offset
        image = stitched
        previousFrame = frame
        return .appended(image: stitched, overlap: overlap)
    }

    fileprivate static func minimumOverlap(for height: Int) -> Int {
        max(48, height / 8)
    }

    // MARK: - Static header/footer detection

    private mutating func resolveStaticBands(previous: PixelBuffer, current: PixelBuffer) {
        let maxBand = max(
            Self.staticBandMinRows,
            Int(Double(frameHeight) * Self.maximumStaticBandFraction)
        )
        headerHeight = Self.staticBandHeight(
            previous: previous,
            current: current,
            fromTop: true,
            limit: maxBand
        )
        footerHeight = Self.staticBandHeight(
            previous: previous,
            current: current,
            fromTop: false,
            limit: maxBand
        )
    }

    /// Rows that are pixel-identical between two frames are static chrome (fixed
    /// header/footer) — they never scroll, so they must not take part in alignment.
    private static func staticBandHeight(
        previous: PixelBuffer,
        current: PixelBuffer,
        fromTop: Bool,
        limit: Int
    ) -> Int {
        var height = 0
        while height + Self.staticBandMinRows <= limit {
            let startRow = fromTop ? height : previous.height - height - Self.staticBandMinRows
            let mad = Self.bandMAD(
                previous: previous,
                current: current,
                startRow: startRow,
                rowCount: Self.staticBandMinRows
            )
            guard mad <= Self.staticBandMADThreshold else { break }
            height += Self.staticBandMinRows
        }
        return height
    }

    private static func bandMAD(
        previous: PixelBuffer,
        current: PixelBuffer,
        startRow: Int,
        rowCount: Int
    ) -> Double {
        let columnStart = Int(Double(previous.width) * (1 - Self.profileColumnFraction) / 2)
        let columnEnd = Int(Double(previous.width) * (1 + Self.profileColumnFraction) / 2)
        guard columnStart < columnEnd, startRow >= 0, startRow + rowCount <= previous.height else {
            return .greatestFiniteMagnitude
        }
        var total = 0
        var count = 0
        for y in startRow..<(startRow + rowCount) {
            for x in columnStart..<columnEnd {
                total += abs(previous.luminance(atX: x, y: y) - current.luminance(atX: x, y: y))
                count += 1
            }
        }
        return count > 0 ? Double(total) / Double(count) : .greatestFiniteMagnitude
    }

    // MARK: - Movement detection

    private static func isNearIdentical(previous: PixelBuffer, current: PixelBuffer) -> Bool {
        let columnStart = Int(Double(previous.width) * (1 - Self.profileColumnFraction) / 2)
        let columnEnd = Int(Double(previous.width) * (1 + Self.profileColumnFraction) / 2)
        var total = 0
        var count = 0
        for y in 0..<previous.height {
            for x in columnStart..<columnEnd {
                total += abs(previous.luminance(atX: x, y: y) - current.luminance(atX: x, y: y))
                count += 1
            }
        }
        return count > 0 ? Double(total) / Double(count) <= Self.duplicateMADThreshold : false
    }

    // MARK: - Composite

    private static func composite(
        _ base: CGImage,
        with frame: CGImage,
        appending offset: Int,
        footerHeight: Int
    ) -> CGImage? {
        let outputHeight = base.height + offset
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        guard let context = CGContext(
            data: nil,
            width: base.width,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.draw(base, in: CGRect(x: 0, y: offset, width: base.width, height: base.height))

        // Pixel rows use the CGImage top-left convention. Keep the original
        // top header, then replace the old bottom footer with the current frame's
        // newly revealed rows and footer.
        context.saveGState()
        context.clip(to: CGRect(
            x: 0,
            y: 0,
            width: frame.width,
            height: offset + footerHeight
        ))
        context.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        context.restoreGState()
        return context.makeImage()
    }
}

// MARK: - Offset search

/// Finds the vertical offset between two consecutive frames.
///
/// `offset` is the number of new rows revealed at the bottom of `current` (the
/// scroll distance in pixels). At the correct offset, `current[r]` equals
/// `previous[offset + r]` for every overlapping row `r`.
private struct OffsetSearch {
    let previous: PixelBuffer
    let current: PixelBuffer
    let headerHeight: Int
    let footerHeight: Int
    let expectedOffset: Int?

    var bestOffset: Int? {
        let minOverlap = LongScreenshotStitcher.minimumOverlap(for: previous.height)
        let maxOffset = previous.height - footerHeight - minOverlap
        guard maxOffset > 0 else { return nil }

        let previousProfile = Self.profile(of: previous)
        let currentProfile = Self.profile(of: current)
        let texture = Self.profileTexture(of: current)

        // Temporal prior: scroll speed does not change abruptly, so try a narrow
        // window around the last accepted offset first.
        if let expectedOffset {
            let center = min(max(expectedOffset, 1), maxOffset)
            let halfRange = max(8, Int(Double(expectedOffset) * LongScreenshotStitcher.temporalPriorHalfRangeFraction))
            let low = max(1, center - halfRange)
            let high = min(maxOffset, center + halfRange)
            if let offset = search(
                previousProfile: previousProfile,
                currentProfile: currentProfile,
                texture: texture,
                lowOffset: low,
                highOffset: high
            ) {
                return offset
            }
        }

        // Full-range fallback.
        return search(
            previousProfile: previousProfile,
            currentProfile: currentProfile,
            texture: texture,
            lowOffset: 1,
            highOffset: maxOffset
        )
    }

    private func search(
        previousProfile: [Double],
        currentProfile: [Double],
        texture: Double,
        lowOffset: Int,
        highOffset: Int
    ) -> Int? {
        guard lowOffset <= highOffset else { return nil }
        // Content too flat to align reliably (e.g. pure white region).
        guard texture >= LongScreenshotStitcher.minimumTexture else { return nil }

        // Phase 1: rank every offset by 1D profile MAD (cheap).
        var scored: [(offset: Int, mad: Double)] = []
        scored.reserveCapacity(highOffset - lowOffset + 1)
        for offset in lowOffset...highOffset {
            scored.append((offset, oneDimensionalMAD(
                previousProfile: previousProfile,
                currentProfile: currentProfile,
                offset: offset
            )))
        }
        scored.sort { $0.mad < $1.mad }

        // Phase 2: verify the top candidates with 2D strips, refining ±2px.
        var verified: [Int: Double] = [:]
        for candidate in scored.prefix(LongScreenshotStitcher.topOneDimensionalCandidates) {
            let low = max(lowOffset, candidate.offset - LongScreenshotStitcher.refinementRange)
            let high = min(highOffset, candidate.offset + LongScreenshotStitcher.refinementRange)
            for offset in low...high where verified[offset] == nil {
                verified[offset] = twoDimensionalMAD(offset: offset)
            }
        }

        guard let best = verified.min(by: { $0.value < $1.value }),
              best.value <= LongScreenshotStitcher.verifyMADThreshold else { return nil }

        // Evaluate ambiguity relative to the final winner, not an intermediate match.
        let runnerUp = verified.filter {
            abs($0.key - best.key) >= LongScreenshotStitcher.ambiguityOffsetGap
        }.map(\.value).min()
        if let runnerUp, runnerUp <= best.value * LongScreenshotStitcher.ambiguityRatio {
            return nil
        }

        return best.key
    }

    private func oneDimensionalMAD(previousProfile: [Double], currentProfile: [Double], offset: Int) -> Double {
        let startRow = headerHeight
        let endRow = previous.height - footerHeight - offset
        guard startRow < endRow else { return .greatestFiniteMagnitude }
        var total = 0.0
        var count = 0
        for row in startRow..<endRow {
            total += abs(previousProfile[offset + row] - currentProfile[row])
            count += 1
        }
        return count > 0 ? total / Double(count) : .greatestFiniteMagnitude
    }

    private func twoDimensionalMAD(offset: Int) -> Double {
        let contentTop = headerHeight
        let contentBottom = previous.height - footerHeight - offset
        guard contentTop < contentBottom else { return .greatestFiniteMagnitude }

        let columnStart = Int(Double(previous.width) * (1 - LongScreenshotStitcher.stripColumnFraction) / 2)
        let columnEnd = Int(Double(previous.width) * (1 + LongScreenshotStitcher.stripColumnFraction) / 2)
        let usable = contentBottom - contentTop
        var total = 0
        var count = 0

        for fraction in LongScreenshotStitcher.stripFractions {
            let startRow = contentTop + Int(Double(usable) * fraction)
            guard startRow + LongScreenshotStitcher.stripHeight <= contentBottom else { continue }
            for dy in 0..<LongScreenshotStitcher.stripHeight {
                let previousRow = offset + startRow + dy
                let currentRow = startRow + dy
                for x in columnStart..<columnEnd {
                    total += abs(previous.luminance(atX: x, y: previousRow) - current.luminance(atX: x, y: currentRow))
                    count += 1
                }
            }
        }
        return count > 0 ? Double(total) / Double(count) : .greatestFiniteMagnitude
    }

    private static func profile(of buffer: PixelBuffer) -> [Double] {
        let columnStart = Int(Double(buffer.width) * (1 - LongScreenshotStitcher.profileColumnFraction) / 2)
        let columnEnd = Int(Double(buffer.width) * (1 + LongScreenshotStitcher.profileColumnFraction) / 2)
        var result: [Double] = []
        result.reserveCapacity(buffer.height)
        for y in 0..<buffer.height {
            var sum = 0
            for x in columnStart..<columnEnd {
                sum += buffer.luminance(atX: x, y: y)
            }
            result.append(Double(sum) / Double(max(columnEnd - columnStart, 1)))
        }
        return result
    }

    private static func profileTexture(of buffer: PixelBuffer) -> Double {
        let profile = Self.profile(of: buffer)
        var total = 0.0
        var count = 0
        for index in 1..<profile.count {
            total += abs(profile[index] - profile[index - 1])
            count += 1
        }
        return count > 0 ? total / Double(count) : 0
    }
}

// MARK: - Pixel buffer

private struct PixelBuffer {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: [UInt8]

    init(image: CGImage) throws {
        width = image.width
        height = image.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw LongScreenshotStitcher.StitchError.imageCreationFailed
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        bytesPerRow = context.bytesPerRow
        guard let data = context.data else {
            throw LongScreenshotStitcher.StitchError.imageCreationFailed
        }
        bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: bytesPerRow * height))
    }

    func luminance(atX x: Int, y: Int) -> Int {
        let offset = y * bytesPerRow + x * 4
        return (Int(bytes[offset]) * 54 + Int(bytes[offset + 1]) * 183 + Int(bytes[offset + 2]) * 19) / 256
    }
}
