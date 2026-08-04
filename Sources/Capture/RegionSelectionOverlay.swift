import AppKit
import ScreenCaptureKit
import QuartzCore

struct RegionSelection {
    let pointsRect: CGRect  // In global display points (top-left origin, matching SCK coordinates)
    let localRect: CGRect   // In screen points, bottom-left origin (view coordinates)
    let scaleFactor: CGFloat
}

@MainActor
final class RegionSelectionOverlay {

    private var overlayWindows: [NSWindow] = []
    private var continuation: CheckedContinuation<RegionSelection?, Never>?

    func selectRegion(over image: NSImage? = nil, screens: [NSScreen]? = nil) async -> RegionSelection? {
        await withCheckedContinuation { cont in
            self.continuation = cont
            showOverlays(background: image, screens: screens)
        }
    }

    private func showOverlays(background: NSImage?, screens: [NSScreen]?) {
        let crosshair = CrosshairCursor.shared.makeCursor()

        let targetScreens: [NSScreen]
        if let screens {
            // A single frozen frame is only meaningful for one display.
            guard background == nil || screens.count <= 1 else {
                continuation?.resume(returning: nil)
                continuation = nil
                return
            }
            targetScreens = screens
        } else if background != nil {
            let mouseLocation = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
                ?? NSScreen.main
                ?? NSScreen.screens.first
            targetScreens = screen.map { [$0] } ?? []
        } else {
            targetScreens = NSScreen.screens
        }

        guard !targetScreens.isEmpty else {
            continuation?.resume(returning: nil)
            continuation = nil
            return
        }

        for screen in targetScreens {
            let window = OverlayWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isOpaque = background != nil
            window.backgroundColor = background != nil ? .black : .clear
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenPrimary]

            let selectionView = SelectionView(screen: screen, cursor: crosshair) { [weak self] rect in
                self?.finishSelection(rect: rect, screen: screen)
            } onCancel: { [weak self] in
                self?.cancelSelection()
            }

            let contentSize = NSSize(width: screen.frame.width, height: screen.frame.height)
            if let background {
                // Freeze frame lives on a static layer so drag-time updates stay cheap.
                let container = NSView(frame: NSRect(origin: .zero, size: contentSize))
                container.autoresizingMask = [.width, .height]

                let bgView = NSImageView(frame: container.bounds)
                bgView.autoresizingMask = [.width, .height]
                bgView.image = background
                bgView.imageScaling = .scaleAxesIndependently
                container.addSubview(bgView)

                selectionView.frame = container.bounds
                selectionView.autoresizingMask = [.width, .height]
                container.addSubview(selectionView)
                window.contentView = container
            } else {
                selectionView.frame = NSRect(origin: .zero, size: contentSize)
                selectionView.autoresizingMask = [.width, .height]
                window.contentView = selectionView
            }
            window.makeKeyAndOrderFront(nil)
            overlayWindows.append(window)
        }

        NSApp.activate(ignoringOtherApps: true)
        crosshair.push()
        crosshair.set()
    }

    private func finishSelection(rect: CGRect, screen: NSScreen) {
        NSCursor.pop()

        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height

        let globalX = screen.frame.origin.x + rect.origin.x
        let globalY = primaryHeight - (screen.frame.origin.y + rect.origin.y + rect.height)

        let pointsRect = CGRect(
            x: globalX,
            y: globalY,
            width: rect.width,
            height: rect.height
        )

        let selection = RegionSelection(
            pointsRect: pointsRect,
            localRect: rect,
            scaleFactor: screen.backingScaleFactor
        )

        closeOverlays()
        continuation?.resume(returning: selection)
        continuation = nil
    }

    private func cancelSelection() {
        NSCursor.pop()
        closeOverlays()
        continuation?.resume(returning: nil)
        continuation = nil
    }

    private func closeOverlays() {
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
    }
}

// MARK: - Custom Crosshair "+" Cursor (matches macOS screenshot tool)

@MainActor
final class CrosshairCursor {
    static let shared = CrosshairCursor()

    func makeCursor() -> NSCursor {
        let size: CGFloat = 40
        let center = size / 2
        let lineLength: CGFloat = 8
        let gap: CGFloat = 2

        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        NSGraphicsContext.current?.shouldAntialias = true

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.shadowBlurRadius = 1.5
        shadow.set()

        NSColor.white.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round

        // Horizontal line (left segment)
        path.move(to: NSPoint(x: center - lineLength, y: center))
        path.line(to: NSPoint(x: center - gap, y: center))
        // Horizontal line (right segment)
        path.move(to: NSPoint(x: center + gap, y: center))
        path.line(to: NSPoint(x: center + lineLength, y: center))
        // Vertical line (bottom segment)
        path.move(to: NSPoint(x: center, y: center - lineLength))
        path.line(to: NSPoint(x: center, y: center - gap))
        // Vertical line (top segment)
        path.move(to: NSPoint(x: center, y: center + gap))
        path.line(to: NSPoint(x: center, y: center + lineLength))

        path.stroke()

        // Draw center "+" cross
        let plusPath = NSBezierPath()
        plusPath.lineWidth = 1.5
        plusPath.lineCapStyle = .round
        let plusSize: CGFloat = 1.25
        plusPath.move(to: NSPoint(x: center - plusSize, y: center))
        plusPath.line(to: NSPoint(x: center + plusSize, y: center))
        plusPath.move(to: NSPoint(x: center, y: center - plusSize))
        plusPath.line(to: NSPoint(x: center, y: center + plusSize))
        plusPath.stroke()

        image.unlockFocus()

        return NSCursor(image: image, hotSpot: NSPoint(x: center, y: center))
    }
}

// MARK: - Overlay Window (prevents AppKit cursor resets)

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cursorUpdate(with event: NSEvent) {
        // Swallow cursor updates — we manage the cursor ourselves in SelectionView
    }
}

// MARK: - Selection View

private final class SelectionView: NSView {
    private var dragStart: NSPoint?
    private var trackingArea: NSTrackingArea?
    private let screen: NSScreen
    private let crosshairCursor: NSCursor
    private let onSelect: (CGRect) -> Void
    private let onCancel: () -> Void

    private let dimmingLayers: [CALayer] = (0..<4).map { _ in CALayer() }
    private let guideLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let labelBackgroundLayer = CALayer()
    private let labelTextLayer = CATextLayer()
    private var guidePoint: NSPoint?
    private var selectionPoint: NSPoint?
    private var isDragging = false
    private var layersConfigured = false

    init(screen: NSScreen, cursor: NSCursor, onSelect: @escaping (CGRect) -> Void, onCancel: @escaping () -> Void) {
        self.screen = screen
        self.crosshairCursor = cursor
        self.onSelect = onSelect
        self.onCancel = onCancel
        super.init(frame: screen.frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureLayers()
        updateLayerFrames()
        updateSelectionLayers(start: nil, current: nil)
        window?.makeFirstResponder(self)
        updateTrackingAreas()
    }

    override func layout() {
        super.layout()
        updateLayerFrames()
        if isDragging {
            updateSelectionLayers(start: dragStart, current: selectionPoint)
        } else {
            updateDimmingLayers(for: nil)
            updateGuide(at: guidePoint)
        }
    }

    override func updateTrackingAreas() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: crosshairCursor)
        crosshairCursor.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        crosshairCursor.set()
    }

    // MARK: - Core Animation Layers

    private func configureLayers() {
        guard !layersConfigured, let layer else { return }
        layersConfigured = true

        layer.backgroundColor = NSColor.clear.cgColor
        layer.masksToBounds = false

        for layer in dimmingLayers {
            layer.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
            layer.masksToBounds = true
        }

        guideLayer.fillColor = nil
        guideLayer.strokeColor = NSColor.white.withAlphaComponent(0.4).cgColor
        guideLayer.lineWidth = 0.5
        guideLayer.lineCap = .butt

        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.white.cgColor
        borderLayer.lineWidth = 1.5

        labelBackgroundLayer.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        labelBackgroundLayer.cornerRadius = 4
        labelBackgroundLayer.masksToBounds = true

        labelTextLayer.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        labelTextLayer.fontSize = 11
        labelTextLayer.foregroundColor = NSColor.white.cgColor
        labelTextLayer.alignmentMode = .center
        labelTextLayer.contentsScale = screen.backingScaleFactor

        for dimmingLayer in dimmingLayers {
            dimmingLayer.contentsScale = screen.backingScaleFactor
            layer.addSublayer(dimmingLayer)
        }
        for sublayer in [guideLayer, borderLayer, labelBackgroundLayer, labelTextLayer] {
            sublayer.contentsScale = screen.backingScaleFactor
            layer.addSublayer(sublayer)
        }

        guideLayer.isHidden = true
        borderLayer.isHidden = true
        labelBackgroundLayer.isHidden = true
        labelTextLayer.isHidden = true
    }

    private func updateLayerFrames() {
        guard layersConfigured else { return }
        guideLayer.frame = bounds
        borderLayer.frame = bounds
    }

    private func updateGuide(at point: NSPoint?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        guard let point else {
            guideLayer.path = nil
            guideLayer.isHidden = true
            CATransaction.commit()
            return
        }

        let path = CGMutablePath()
        path.move(to: CGPoint(x: point.x, y: bounds.minY))
        path.addLine(to: CGPoint(x: point.x, y: bounds.maxY))
        path.move(to: CGPoint(x: bounds.minX, y: point.y))
        path.addLine(to: CGPoint(x: bounds.maxX, y: point.y))
        guideLayer.path = path
        guideLayer.isHidden = false
        CATransaction.commit()
    }

    private func updateSelectionLayers(start: NSPoint?, current: NSPoint?) {
        guard layersConfigured else { return }

        let selectionRect: CGRect?
        if let start, let current {
            let rect = rectFromPoints(start, current)
            selectionRect = rect.width > 2 && rect.height > 2 ? rect : nil
        } else {
            selectionRect = nil
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        updateDimmingLayers(for: selectionRect)

        if let selectionRect {
            let borderPath = CGMutablePath()
            borderPath.addRect(selectionRect)
            borderLayer.path = borderPath
            borderLayer.isHidden = false
            updateSizeLabel(for: selectionRect)
        } else {
            borderLayer.path = nil
            borderLayer.isHidden = true
            labelBackgroundLayer.isHidden = true
            labelTextLayer.isHidden = true
        }

        CATransaction.commit()
    }

    private func updateDimmingLayers(for selectionRect: CGRect?) {
        let regions: [CGRect]
        if let selectionRect {
            regions = [
                CGRect(x: bounds.minX, y: selectionRect.maxY, width: bounds.width, height: bounds.maxY - selectionRect.maxY),
                CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: selectionRect.minY - bounds.minY),
                CGRect(x: bounds.minX, y: selectionRect.minY, width: selectionRect.minX - bounds.minX, height: selectionRect.height),
                CGRect(x: selectionRect.maxX, y: selectionRect.minY, width: bounds.maxX - selectionRect.maxX, height: selectionRect.height),
            ]
        } else {
            regions = [bounds, .zero, .zero, .zero]
        }

        for (layer, region) in zip(dimmingLayers, regions) {
            layer.frame = region.standardized
            layer.isHidden = region.width <= 0 || region.height <= 0
        }
    }

    private func updateSizeLabel(for selectionRect: CGRect) {
        let width = Int(selectionRect.width * screen.backingScaleFactor)
        let height = Int(selectionRect.height * screen.backingScaleFactor)
        let text = "\(width) × \(height)"
        let nsText = text as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = nsText.size(withAttributes: attributes)
        let labelRect = CGRect(
            x: selectionRect.midX - textSize.width / 2 - 6,
            y: selectionRect.minY - textSize.height - 8,
            width: textSize.width + 12,
            height: textSize.height + 4
        )

        labelBackgroundLayer.frame = labelRect
        labelTextLayer.frame = labelRect.insetBy(dx: 6, dy: 2)
        labelTextLayer.string = text
        labelBackgroundLayer.isHidden = false
        labelTextLayer.isHidden = false
    }

    // MARK: - Mouse Events

    override func mouseEntered(with event: NSEvent) {
        crosshairCursor.set()
    }

    override func mouseMoved(with event: NSEvent) {
        crosshairCursor.set()
        let loc = convert(event.locationInWindow, from: nil)
        guidePoint = loc
        updateGuide(at: loc)
    }

    override func mouseDown(with event: NSEvent) {
        crosshairCursor.set()
        let loc = convert(event.locationInWindow, from: nil)
        dragStart = loc
        selectionPoint = loc
        isDragging = true
        guidePoint = nil
        updateGuide(at: nil)
        updateSelectionLayers(start: loc, current: loc)
    }

    override func mouseDragged(with event: NSEvent) {
        crosshairCursor.set()
        let current = convert(event.locationInWindow, from: nil)
        selectionPoint = current
        updateSelectionLayers(start: dragStart, current: current)
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        let rect = rectFromPoints(start, end)
        isDragging = false
        selectionPoint = end

        if rect.width > 3, rect.height > 3 {
            onSelect(rect)
        } else {
            onCancel()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel()
        }
    }

    private func rectFromPoints(_ a: NSPoint, _ b: NSPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }
}
