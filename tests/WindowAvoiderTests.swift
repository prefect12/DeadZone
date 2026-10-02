// Regressions: tall share hosts, partially off-screen windows and refused AX resizing.
let avoider = WindowAvoider()
let screen = CGRect(x: 0, y: 25, width: 1280, height: 775)
let dead = [CGRect(x: 800, y: 25, width: 480, height: 320)]
for frame in [CGRect(x: 700, y: 100, width: 500, height: 1000),
              CGRect(x: 950, y: 100, width: 500, height: 500),
              CGRect(x: 600, y: -100, width: 450, height: 600),
              CGRect(x: 700, y: 600, width: 500, height: 350)] {
    guard let target = avoider.plan(frame, dead: dead, screen: screen) ?? avoider.maxRect(dead: dead, screen: screen) else { fatalError("No safe target") }
    precondition(screen.contains(target), "Tall/edge window must remain fully on-screen: \(target)")
    precondition(!dead.contains { overlaps($0, target) }, "Target overlaps dead zone")
    if let placed = avoider.place(frame, dead: dead, screen: screen) {
        precondition(screen.contains(placed) && placed.size == frame.size)
    }
}
// Secondary screen left/above the primary: global coordinates can be negative.
let secondary = CGRect(x: -1440, y: -900, width: 1440, height: 900)
let secondaryDead = [CGRect(x: -400, y: -900, width: 400, height: 200)]
let secondWindow = CGRect(x: -300, y: -800, width: 600, height: 700)
let secondTarget = avoider.plan(secondWindow, dead: secondaryDead, screen: secondary)!
precondition(secondary.contains(secondTarget) && !secondaryDead.contains { overlaps($0, secondTarget) })
// Preserve-size dialogs that cannot fit must not be moved off-screen to avoid a bad region.
precondition(avoider.place(CGRect(x: 400, y: 100, width: 360, height: 1000), dead: dead, screen: screen) == nil)
let refusedResize = CGRect(x: 900, y: 650, width: 600, height: 500)
let bounded = CGRect(origin: WindowAvoider.boundedOrigin(of: refusedResize, screen: screen), size: refusedResize.size)
precondition(screen.contains(bounded))
let oversized = CGRect(x: 900, y: 650, width: 1600, height: 1000)
precondition(WindowAvoider.boundedOrigin(of: oversized, screen: screen) == screen.origin)
precondition(WindowAvoider.isSystemSharingHost("com.apple.share.AirDrop.send"))
precondition(!WindowAvoider.isSystemSharingHost("com.apple.Preview"))
precondition(WindowAvoider.isSystemSharingDialog(title: "AirDrop", subrole: "AXSystemDialog"))
precondition(!WindowAvoider.isSystemSharingDialog(title: "AirDrop", subrole: kAXStandardWindowSubrole))
precondition(!WindowAvoider.isSystemSharingDialog(title: "Save", subrole: "AXDialog"))
print("Window avoidance regressions passed")
