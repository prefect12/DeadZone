import Foundation
import CoreGraphics

/// Coordinates use the display's global top-left origin, as do DeadZone's raster rectangles.
enum ContourMenuLayout {
    static func edge(x0: CGFloat, x1: CGFloat, screen: CGRect, dead: [CGRect]) -> CGFloat {
        dead.filter { $0.maxX > x0 && $0.minX < x1 && $0.intersects(screen) }
            .reduce(screen.minY) { max($0, min($1.maxY, screen.maxY)) } + 3
    }

    static func itemFrame(range: ClosedRange<CGFloat>, screen: CGRect, dead: [CGRect], height: CGFloat) -> CGRect? {
        let x0 = max(screen.minX, range.lowerBound)
        let x1 = min(screen.maxX, range.upperBound)
        guard x1 > x0 else { return nil }
        let y = edge(x0: x0, x1: x1, screen: screen, dead: dead)
        guard y + height <= screen.maxY else { return nil }
        return CGRect(x: x0, y: y, width: x1 - x0, height: height)
    }

}
