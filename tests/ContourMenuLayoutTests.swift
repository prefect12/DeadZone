import Foundation
import CoreGraphics

@main struct ContourTests {
    static func main() {
        let screen = CGRect(x: -800, y: 40, width: 800, height: 600)
        let dead = [CGRect(x: -800, y: 0, width: 200, height: 120),
                    CGRect(x: -600, y: 0, width: 200, height: 220),
                    CGRect(x: -400, y: 0, width: 200, height: 340)]
        let left = ContourMenuLayout.itemFrame(range: -780 ... -700, screen: screen, dead: dead, height: 28)!
        let middle = ContourMenuLayout.itemFrame(range: -570 ... -500, screen: screen, dead: dead, height: 28)!
        let right = ContourMenuLayout.itemFrame(range: -380 ... -300, screen: screen, dead: dead, height: 28)!
        assert(left.minY == 123 && middle.minY == 223 && right.minY == 343,
               "Items must follow the local contour, not the global maximum")
        let spanning = ContourMenuLayout.itemFrame(range: -620 ... -560, screen: screen, dead: dead, height: 28)!
        assert(spanning.minY == 223, "An intact label must clear the entire width")
        for frame in [left, middle, right, spanning] {
            assert(screen.contains(frame))
            assert(!dead.contains { $0.intersects(frame) })
        }
        let bottomDead = [CGRect(x: -800, y: 40, width: 800, height: 590)]
        assert(ContourMenuLayout.itemFrame(range: -780 ... -700, screen: screen, dead: bottomDead, height: 28) == nil)
        assert(ContourMenuLayout.itemFrame(range: -1000 ... -900, screen: screen, dead: [], height: 28) == nil)
        let clean = ContourMenuLayout.itemFrame(range: -100 ... -20, screen: screen, dead: dead, height: 28)!
        assert(clean.minY == 43, "An undamaged column should stay at its own top")

        print("PASS: contour following, intact labels, collision avoidance, display offsets, insufficient space")
    }
}
