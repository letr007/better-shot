import CoreGraphics

@main
enum RegionGeometryCheck {
    static func main() {
        let secondScreen = CGRect(x: 1440, y: -200, width: 1920, height: 1080)
        let local = CGRect(x: 100, y: 50, width: 300, height: 200)
        let global = RegionGeometry.globalRect(local: local, screenFrame: secondScreen)
        precondition(global == CGRect(x: 1540, y: -150, width: 300, height: 200))
        precondition(RegionGeometry.localRect(global: global, screenFrame: secondScreen) == local, "global and local must round-trip")

        let points = RegionGeometry.pointsRect(global: CGRect(x: 10, y: 20, width: 100, height: 50), primaryHeight: 900)
        precondition(points == CGRect(x: 10, y: 830, width: 100, height: 50), "top-left flip must use the rect's top edge")

        precondition(RegionGeometry.screencaptureArgument(CGRect(x: 10.4, y: 830.6, width: 100, height: 50)) == "10,831,100,50")

        let displayPoints = RegionGeometry.pointsRect(global: secondScreen, primaryHeight: 900)
        let retinaSize = CGSize(width: 3840, height: 2160)
        let cropPoints = RegionGeometry.pointsRect(global: global, primaryHeight: 900)
        precondition(RegionGeometry.pixelRect(pointsRect: cropPoints, displayRect: displayPoints, pixelSize: retinaSize)
            == CGRect(x: 200, y: 1660, width: 600, height: 400), "secondary display crop uses display-local top-left pixels")
        precondition(RegionGeometry.pixelRect(pointsRect: displayPoints, displayRect: displayPoints, pixelSize: retinaSize)
            == CGRect(origin: .zero, size: retinaSize), "full display keeps native pixel dimensions")
        let aboveScreen = CGRect(x: -1200, y: 900, width: 1200, height: 800)
        let abovePoints = RegionGeometry.pointsRect(global: aboveScreen, primaryHeight: 900)
        precondition(RegionGeometry.pixelRect(pointsRect: CGRect(x: -1180, y: -790, width: 100, height: 50),
            displayRect: abovePoints, pixelSize: CGSize(width: 1200, height: 800))
            == CGRect(x: 20, y: 10, width: 100, height: 50), "negative display origins map without a primary-screen offset")
        precondition(RegionGeometry.pixelRect(pointsRect: CGRect(x: 0.25, y: 0.25, width: 10.25, height: 5.5),
            displayRect: CGRect(x: 0, y: 0, width: 100, height: 100), pixelSize: CGSize(width: 200, height: 200))
            == CGRect(x: 0, y: 0, width: 21, height: 12), "fractional selections round outwards")
        precondition(RegionGeometry.pixelRect(pointsRect: CGRect(x: -10, y: 90, width: 30, height: 30),
            displayRect: CGRect(x: 0, y: 0, width: 100, height: 100), pixelSize: CGSize(width: 200, height: 200))
            == CGRect(x: 0, y: 180, width: 40, height: 20), "cropping clamps to captured pixels")
        precondition(RegionGeometry.pixelRect(pointsRect: CGRect(x: 110, y: 0, width: 10, height: 10),
            displayRect: CGRect(x: 0, y: 0, width: 100, height: 100), pixelSize: CGSize(width: 200, height: 200)) == nil)
        precondition(RegionGeometry.pixelRect(pointsRect: .zero, displayRect: displayPoints, pixelSize: retinaSize) == nil)
        precondition(RegionGeometry.pixelRect(pointsRect: displayPoints, displayRect: .zero, pixelSize: retinaSize) == nil)

        let sel = CGRect(x: 100, y: 100, width: 200, height: 100)
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        precondition(RegionAdjustment.handle(at: CGPoint(x: 303, y: 197), in: sel) == .topRight, "near a corner picks that corner")
        precondition(RegionAdjustment.handle(at: CGPoint(x: 200, y: 101), in: sel) == .bottom, "near an edge midpoint picks that edge")
        precondition(RegionAdjustment.handle(at: CGPoint(x: 150, y: 150), in: sel) == .move, "inside picks move")
        precondition(RegionAdjustment.handle(at: CGPoint(x: 50, y: 50), in: sel) == nil, "outside picks nothing")

        precondition(RegionAdjustment.apply(.right, delta: CGSize(width: 50, height: 999), to: sel, within: screen) == CGRect(x: 100, y: 100, width: 250, height: 100), "edge handle moves only its own edge")
        precondition(RegionAdjustment.apply(.topLeft, delta: CGSize(width: -10, height: 20), to: sel, within: screen) == CGRect(x: 90, y: 100, width: 210, height: 120))
        precondition(RegionAdjustment.apply(.left, delta: CGSize(width: 250, height: 0), to: sel, within: screen) == CGRect(x: 300, y: 100, width: 50, height: 100), "dragging past the opposite edge flips instead of going negative")
        precondition(RegionAdjustment.apply(.bottomLeft, delta: CGSize(width: -500, height: -500), to: sel, within: screen) == CGRect(x: 0, y: 0, width: 300, height: 200), "resize clamps to the screen")
        precondition(RegionAdjustment.apply(.move, delta: CGSize(width: 900, height: -10), to: sel, within: screen) == CGRect(x: 800, y: 90, width: 200, height: 100), "move keeps the size and stays on screen")
        print("RegionGeometryCheck passed")
    }
}
