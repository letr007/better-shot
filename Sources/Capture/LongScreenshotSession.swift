import AppKit
import CoreGraphics
import QuartzCore

/// Captures manually scrolled frames for a fixed viewport and stitches them into one image.
@MainActor
final class LongScreenshotSession {
    /// Capture only once the scroll wheel has been quiet this long, so frames are
    /// grabbed while the content is still — mid-motion frames are blurry and
    /// cannot be aligned reliably.
    private static let captureSettleInterval: TimeInterval = 0.10
    /// During continuous (held) scrolling the wheel never goes quiet; force a
    /// capture at least this often so dense frames are still produced.
    private static let maxBurstCaptureDelay: TimeInterval = 0.35
    /// Small pause before grabbing each frame to let rendering settle.
    private static let captureSettleDelay: Duration = .milliseconds(30)
    /// How long after the last scroll event to wait before grabbing the final
    /// stable frame when finishing, so the last stitch overlaps cleanly.
    private static let finalSettleInterval: TimeInterval = 0.32
    /// Allow inertia to decay, but keep continued input from waiting forever on Done.
    /// The same deadline covers retries if scrolling resumes during the final capture.
    private static let maxFinalCaptureDelay: TimeInterval = 2.0

    private let screen: NSScreen
    private let viewport: CGRect
    private let displayCapture: ScreenCapture.DisplayCapture
    private var stitcher: LongScreenshotStitcher
    private var scrollMonitor: Any?
    private var samplingTask: Task<Void, Never>?
    private var controlPanel: LongScreenshotControlPanel?
    private var maskOverlay: LongScreenshotMaskOverlay?
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var isActive = false
    private var isSampling = false
    private var hasPendingSample = false
    private var finishRequested = false
    private var capturedFrameCount = 1
    private var stitchErrorMessage: String?
    private var lastScrollEventDate = Date()
    /// Scroll direction tracking. Locked to the first successful append so
    /// reverse-direction scrolls are ignored from then on.
    private var directionLocked = false
    private var lockedDirection = 0
    private var pendingDirection = 0

    /// Result of an off-main stitch pass.
    private struct StitchOutcome: Sendable {
        var stitcher: LongScreenshotStitcher
        var result: LongScreenshotStitcher.Result?
        var fatalErrorMessage: String?
    }

    init(
        initialFrame: CGImage,
        viewport: CGRect,
        screen: NSScreen,
        displayCapture: ScreenCapture.DisplayCapture
    ) throws {
        self.screen = screen
        self.viewport = viewport
        self.displayCapture = displayCapture
        stitcher = try LongScreenshotStitcher(initialImage: initialFrame)
    }

    func run() async -> CGImage? {
        guard !isActive else { return nil }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            isActive = true
            finishRequested = false
            hasPendingSample = false

            let viewportFrame = viewportOnScreen
            maskOverlay = LongScreenshotMaskOverlay(screen: screen, viewport: viewport)
            maskOverlay?.show()
            controlPanel = LongScreenshotControlPanel(
                viewport: viewportFrame,
                screen: screen,
                onFinish: { [weak self] in self?.finish() },
                onCancel: { [weak self] in self?.cancel() }
            )
            updatePanelStatus()
            controlPanel?.show()
            installScrollMonitor()
            ShortcutService.shared.beginLongScreenshotSession(self)
        }
    }

    func finish() {
        guard isActive, !finishRequested else { return }
        finishRequested = true

        // Always route through the sampling task so the final frame waits for
        // the scroll inertia to settle before capturing.
        if samplingTask == nil {
            samplingTask = Task { [weak self] in
                await self?.samplePendingScrolls()
            }
        }
    }

    func cancel() {
        complete(with: nil)
    }

    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let location = NSEvent.mouseLocation
            let deltaY = event.scrollingDeltaY
            Task { @MainActor in
                self?.receivedScrollEvent(at: location, deltaY: deltaY)
            }
        }
    }

    private func receivedScrollEvent(at location: NSPoint, deltaY: CGFloat) {
        guard isActive, viewportOnScreen.contains(location) else { return }
        // Momentum and reverse scrolls still postpone the final stable capture.
        lastScrollEventDate = Date()
        guard !finishRequested else { return }

        let sign = deltaY > 0 ? 1 : (deltaY < 0 ? -1 : 0)
        guard sign != 0 else { return }

        // Once the direction is locked, ignore reverse scrolls entirely — they
        // would pollute the stitch with already-seen content.
        if directionLocked, sign != lockedDirection {
            if stitchErrorMessage == nil {
                stitchErrorMessage = L10n.string("Continue scrolling in the same direction")
                updatePanelStatus()
            }
            return
        }

        pendingDirection = sign
        hasPendingSample = true
        guard samplingTask == nil else { return }
        samplingTask = Task { [weak self] in
            await self?.samplePendingScrolls()
        }
    }

    /// Samples throughout a scroll gesture. Each frame is captured either once the
    /// wheel goes quiet (preferred — stable frame) or at a forced cadence during
    /// continuous scrolling so no content is skipped.
    private func samplePendingScrolls() async {
        defer { samplingTask = nil }

        while isActive {
            if hasPendingSample {
                hasPendingSample = false
                await waitForCaptureMoment()
                guard isActive else { return }
                let direction = pendingDirection
                let captured = await captureViewport(direction: direction)
                guard isActive, captured else { return }
            } else if finishRequested {
                let deadline = Date().addingTimeInterval(Self.maxFinalCaptureDelay)
                while isActive, finishRequested {
                    let isQuiet = await waitForScrollToQuiet(
                        interval: Self.finalSettleInterval,
                        deadline: deadline
                    )
                    guard isActive else { return }
                    guard isQuiet else {
                        reportSamplingFailure(L10n.string("Scrolling has not stopped. Pause, then press Done again."))
                        return
                    }

                    let scrollEventDate = lastScrollEventDate
                    let direction = pendingDirection
                    let captured = await captureViewport(direction: direction)
                    guard isActive, captured else { return }
                    // An event during either await means the captured frame is no
                    // longer the final viewport. Settle again within the same deadline.
                    if lastScrollEventDate != scrollEventDate {
                        continue
                    }
                    complete(with: stitcher.image)
                    return
                }
                return
            } else {
                return
            }
        }
    }

    /// Waits until the scroll wheel is quiet (stable frame) or until the forced
    /// burst timeout elapses so continuous scrolling still produces frames.
    private func waitForCaptureMoment() async {
        let burstStart = Date()
        while Date().timeIntervalSince(lastScrollEventDate) < Self.captureSettleInterval
            && Date().timeIntervalSince(burstStart) < Self.maxBurstCaptureDelay {
            try? await Task.sleep(for: .milliseconds(40))
            guard isActive else { return }
        }
    }

    private func waitForScrollToQuiet(interval: TimeInterval, deadline: Date) async -> Bool {
        while Date().timeIntervalSince(lastScrollEventDate) < interval {
            guard isActive, Date() < deadline else { return false }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }
        return isActive && Date() < deadline
    }

    private func captureViewport(direction: Int) async -> Bool {
        guard isActive, !isSampling else { return false }
        isSampling = true
        defer { isSampling = false }

        let frame: CGImage
        do {
            try await Task.sleep(for: Self.captureSettleDelay)
            guard isActive else { return false }
            frame = try await displayCapture.image(viewport: viewport)
        } catch {
            guard isActive else { return false }
            reportSamplingFailure("\(L10n.string("Could not capture the selected area.")) \(error.localizedDescription)")
            return false
        }
        guard isActive else { return false }

        // The stitch pass is the heavy part; run it off the main thread so the
        // preview panel and the rest of the UI never stutter.
        let stitcherCopy = stitcher
        let outcome = await Task.detached(priority: .userInitiated) {
            var local = stitcherCopy
            do {
                let result = try local.append(frame)
                return StitchOutcome(stitcher: local, result: result, fatalErrorMessage: nil)
            } catch {
                return StitchOutcome(stitcher: local, result: nil, fatalErrorMessage: error.localizedDescription)
            }
        }.value
        guard isActive else { return false }

        if let fatalErrorMessage = outcome.fatalErrorMessage {
            print("Long screenshot failed: \(fatalErrorMessage)")
            reportSamplingFailure(fatalErrorMessage)
            return false
        }

        switch outcome.result {
        case .appended:
            stitcher = outcome.stitcher
            if !directionLocked, direction != 0 {
                directionLocked = true
                lockedDirection = direction
                if pendingDirection != lockedDirection {
                    hasPendingSample = false
                }
            }
            capturedFrameCount += 1
            stitchErrorMessage = nil
        case .duplicate:
            stitchErrorMessage = L10n.string("No change detected — keep scrolling")
        case .skipped(let message):
            print("Long screenshot skipped frame: \(message)")
            reportSamplingFailure("\(L10n.string("Could not stitch this frame. Scroll again to retry.")) \(message)")
            return false
        case nil:
            reportSamplingFailure(L10n.string("Could not stitch this frame. Scroll again to retry."))
            return false
        }
        updatePanelStatus()
        return true
    }

    private func reportSamplingFailure(_ message: String) {
        finishRequested = false
        stitchErrorMessage = message
        updatePanelStatus()
    }

    private var viewportOnScreen: CGRect {
        CGRect(
            x: screen.frame.minX + viewport.minX,
            y: screen.frame.minY + viewport.minY,
            width: viewport.width,
            height: viewport.height
        )
    }

    private func updatePanelStatus() {
        let dimensions = L10n.format("%d × %d px", stitcher.image.width, stitcher.image.height)
        let count = L10n.format("%d frame(s) captured", capturedFrameCount)
        let detail = stitchErrorMessage ?? L10n.string("Scroll to capture · Return to finish · Esc to cancel")
        controlPanel?.update(
            preview: stitcher.image,
            status: "\(count) · \(dimensions)\n\(detail)"
        )
    }

    private func complete(with image: CGImage?) {
        guard isActive else { return }
        isActive = false
        finishRequested = false
        hasPendingSample = false
        samplingTask?.cancel()
        samplingTask = nil
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        ShortcutService.shared.endLongScreenshotSession(self)
        maskOverlay?.close()
        maskOverlay = nil
        controlPanel?.close()
        controlPanel = nil
        continuation?.resume(returning: image)
        continuation = nil
    }
}

@MainActor
private final class LongScreenshotControlPanel: NSObject {
    private let panel: NSPanel
    private let previewView = NSImageView()
    private let statusField = NSTextField(wrappingLabelWithString: "")
    private let onFinish: () -> Void
    private let onCancel: () -> Void

    init(
        viewport: CGRect,
        screen: NSScreen,
        onFinish: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onFinish = onFinish
        self.onCancel = onCancel

        let size = NSSize(width: 360, height: 200)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .windowBackgroundColor
        panel.isOpaque = true
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false

        let contentView = NSView(frame: NSRect(origin: .zero, size: size))
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        contentView.layer?.cornerRadius = 12
        contentView.layer?.masksToBounds = true

        previewView.frame = NSRect(x: 12, y: 12, width: 220, height: 146)
        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.imageAlignment = .alignCenter
        previewView.wantsLayer = true
        previewView.layer?.borderColor = NSColor.separatorColor.cgColor
        previewView.layer?.borderWidth = 1
        contentView.addSubview(previewView)

        statusField.font = .systemFont(ofSize: 12)
        statusField.textColor = .labelColor
        statusField.maximumNumberOfLines = 2
        statusField.lineBreakMode = .byTruncatingTail
        statusField.frame = NSRect(x: 12, y: 164, width: 336, height: 32)
        contentView.addSubview(statusField)

        let cancelButton = NSButton(title: L10n.string("Cancel"), target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.frame = NSRect(x: 244, y: 34, width: 100, height: 24)
        contentView.addSubview(cancelButton)

        let finishButton = NSButton(title: L10n.string("Done"), target: self, action: #selector(finish))
        finishButton.bezelStyle = .rounded
        finishButton.keyEquivalent = "\r"
        finishButton.frame = NSRect(x: 244, y: 64, width: 100, height: 24)
        contentView.addSubview(finishButton)

        panel.contentView = contentView
        panel.setFrameOrigin(Self.hudOrigin(for: viewport, size: size, in: screen.visibleFrame))
    }

    func update(preview: CGImage, status: String) {
        previewView.image = NSImage(
            cgImage: preview,
            size: NSSize(width: preview.width, height: preview.height)
        )
        statusField.stringValue = status
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
    }

    @objc private func finish() {
        onFinish()
    }

    @objc private func cancel() {
        onCancel()
    }

    private static func hudOrigin(for viewport: CGRect, size: NSSize, in visibleFrame: NSRect) -> NSPoint {
        let padding: CGFloat = 12
        let centeredX = min(
            max(viewport.midX - size.width / 2, visibleFrame.minX),
            visibleFrame.maxX - size.width
        )
        let centeredY = min(
            max(viewport.midY - size.height / 2, visibleFrame.minY),
            visibleFrame.maxY - size.height
        )

        let candidates = [
            // Preferred: flush to the right edge of the capture viewport.
            NSRect(
                x: viewport.maxX + padding,
                y: centeredY,
                width: size.width,
                height: size.height
            ),
            NSRect(
                x: viewport.minX - size.width - padding,
                y: centeredY,
                width: size.width,
                height: size.height
            ),
            NSRect(
                x: centeredX,
                y: viewport.maxY + padding,
                width: size.width,
                height: size.height
            ),
            NSRect(
                x: centeredX,
                y: viewport.minY - size.height - padding,
                width: size.width,
                height: size.height
            ),
        ]

        if let candidate = candidates.first(where: { visibleFrame.contains($0) }) {
            return candidate.origin
        }

        return NSPoint(
            x: centeredX,
            y: min(max(viewport.minY - size.height - padding, visibleFrame.minY), visibleFrame.maxY - size.height)
        )
    }
}

@MainActor
private final class LongScreenshotMaskOverlay {
    private let panel: NSPanel
    private let maskView: LongScreenshotMaskView

    init(screen: NSScreen, viewport: CGRect) {
        panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Force the mask to the top of the window stack so it never falls behind the
        // target application while the user scrolls it underneath the viewport.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        // Mouse-transparent: the user scrolls/clicks straight through to the target app.
        panel.ignoresMouseEvents = true

        maskView = LongScreenshotMaskView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            viewport: viewport,
            backingScale: screen.backingScaleFactor
        )
        panel.contentView = maskView
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
    }
}

/// Dims the whole display except the capture viewport, mirroring the region
/// selection mask, and draws a border around the live viewport hole.
private final class LongScreenshotMaskView: NSView {
    private let dimLayers: [CALayer] = (0..<4).map { _ in CALayer() }
    private let borderLayer = CAShapeLayer()
    private let labelBackgroundLayer = CALayer()
    private let labelTextLayer = CATextLayer()
    private let viewport: CGRect

    init(frame: NSRect, viewport: CGRect, backingScale: CGFloat) {
        self.viewport = viewport
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false

        for dimLayer in dimLayers {
            dimLayer.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
            dimLayer.contentsScale = backingScale
            layer?.addSublayer(dimLayer)
        }

        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.controlAccentColor.cgColor
        borderLayer.lineWidth = 2
        borderLayer.contentsScale = backingScale
        layer?.addSublayer(borderLayer)

        labelBackgroundLayer.backgroundColor = NSColor.controlAccentColor.cgColor
        labelBackgroundLayer.cornerRadius = 4
        labelBackgroundLayer.masksToBounds = true
        labelBackgroundLayer.contentsScale = backingScale
        layer?.addSublayer(labelBackgroundLayer)

        labelTextLayer.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        labelTextLayer.fontSize = 11
        labelTextLayer.foregroundColor = NSColor.white.cgColor
        labelTextLayer.alignmentMode = .center
        labelTextLayer.contentsScale = backingScale
        labelTextLayer.string = L10n.string("Viewport")
        layer?.addSublayer(labelTextLayer)

        layoutMask()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func layoutMask() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let regions = [
            CGRect(x: 0, y: viewport.maxY, width: bounds.width, height: bounds.height - viewport.maxY),
            CGRect(x: 0, y: 0, width: bounds.width, height: viewport.minY),
            CGRect(x: 0, y: viewport.minY, width: viewport.minX, height: viewport.height),
            CGRect(x: viewport.maxX, y: viewport.minY, width: bounds.width - viewport.maxX, height: viewport.height),
        ]
        for (dimLayer, region) in zip(dimLayers, regions) {
            dimLayer.frame = region.standardized
            dimLayer.isHidden = region.width <= 0 || region.height <= 0
        }

        // Draw the border just OUTSIDE the hole so it never falls inside the
        // captured crop and therefore never has to be hidden during sampling.
        borderLayer.frame = bounds
        borderLayer.path = CGPath(
            roundedRect: viewport.insetBy(dx: -1.5, dy: -1.5),
            cornerWidth: 3,
            cornerHeight: 3,
            transform: nil
        )

        // The "Viewport" tag lives above the hole (outside the crop); fall back
        // to below the hole, and hide it only when neither side has room.
        let labelWidth: CGFloat = 78
        let labelHeight: CGFloat = 20
        let labelX = min(max(viewport.minX + 8, 4), max(bounds.width - labelWidth - 4, 4))
        let aboveY = viewport.maxY + 4
        let belowY = viewport.minY - labelHeight - 4
        let labelRect: CGRect
        if aboveY + labelHeight <= bounds.height {
            labelRect = CGRect(x: labelX, y: aboveY, width: labelWidth, height: labelHeight)
        } else if belowY >= 0 {
            labelRect = CGRect(x: labelX, y: belowY, width: labelWidth, height: labelHeight)
        } else {
            labelRect = .zero
        }
        labelBackgroundLayer.frame = labelRect
        labelTextLayer.frame = labelRect.insetBy(dx: 6, dy: 2)
        labelBackgroundLayer.isHidden = labelRect == .zero
        labelTextLayer.isHidden = labelRect == .zero

        CATransaction.commit()
    }
}
