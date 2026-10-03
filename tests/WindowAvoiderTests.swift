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
// Exercise the production collector with a document and a sharing proxy in either order.
// The earlier app-wide return [] loses the document; sharing descendants must stay excluded.
let nodes: [Int: [String: Any]] = [
    1: [kAXRoleAttribute: kAXWindowRole, kAXTitleAttribute: "Photo", kAXSubroleAttribute: kAXStandardWindowSubrole],
    2: [kAXRoleAttribute: kAXWindowRole, kAXTitleAttribute: "AirDrop", kAXSubroleAttribute: "AXSystemDialog", kAXChildrenAttribute: [3]],
    3: [kAXRoleAttribute: kAXWindowRole, kAXTitleAttribute: "Remote view"],
    4: [kAXRoleAttribute: kAXWindowRole, kAXTitleAttribute: "AirDrop", kAXSubroleAttribute: kAXStandardWindowSubrole]
]
for roots in [[1, 2, 4], [2, 1, 4]] {
    let selected = WindowAvoider.collectWindows(roots: roots, identity: { CFHashCode($0) },
                                              attribute: { nodes[$0]?[$1] })
    precondition(selected == [1, 4], "AirDrop must not suppress the photo window or include remote child windows")
}
print("Window avoidance regressions passed")

// Preview exposes unnamed full-screen backing windows alongside the AirDrop root.
// Moving even one backing window displaces the hosted panel below the display.
let sharingOverlay = CGRect(x: 0, y: 0, width: 2560, height: 1440)
let sharingGraph: [Int: [String: Any]] = [
    1: [kAXRoleAttribute: kAXWindowRole, kAXTitleAttribute: "Photo", kAXSubroleAttribute: kAXStandardWindowSubrole],
    2: [kAXRoleAttribute: kAXWindowRole, kAXTitleAttribute: "AirDrop", kAXSubroleAttribute: "AXSystemDialog", kAXChildrenAttribute: [3]],
    3: [kAXRoleAttribute: kAXWindowRole, kAXTitleAttribute: "Remote view"],
    5: [kAXRoleAttribute: kAXWindowRole, kAXTitleAttribute: "", kAXSubroleAttribute: "AXUnknown"],
    6: [kAXRoleAttribute: kAXWindowRole, kAXSubroleAttribute: "AXUnknown"],
    7: [kAXRoleAttribute: kAXWindowRole, kAXTitleAttribute: "", kAXSubroleAttribute: "AXUnknown"],
    8: [kAXRoleAttribute: kAXWindowRole, kAXTitleAttribute: "", kAXSubroleAttribute: kAXStandardWindowSubrole],
    9: [kAXRoleAttribute: kAXWindowRole, kAXSubroleAttribute: "AXUnknown"]
]
let sharingBounds = [2: sharingOverlay, 5: sharingOverlay, 6: sharingOverlay.offsetBy(dx: 0, dy: 792),
                     7: sharingOverlay.offsetBy(dx: 0, dy: 794), 8: sharingOverlay,
                     9: CGRect(x: 0, y: 0, width: 400, height: 300)]
for roots in [[1, 2, 5, 6, 7, 8, 9, 3], [3, 9, 8, 7, 6, 5, 2, 1]] {
    let selected = WindowAvoider.collectWindows(roots: roots, identity: { CFHashCode($0) },
                                              attribute: { sharingGraph[$0]?[$1] }, frame: { sharingBounds[$0] })
    precondition(Set(selected) == [1, 8, 9], "Sharing backdrops and independently rooted remote descendants must be excluded")
}
let withoutSharing = WindowAvoider.collectWindows(roots: [1, 5, 8, 9], identity: { CFHashCode($0) },
                                                  attribute: { sharingGraph[$0]?[$1] }, frame: { sharingBounds[$0] })
precondition(withoutSharing == [1, 5, 8, 9], "No app-wide exclusion: ordinary windows remain movable without AirDrop")
print("AirDrop backing-window regressions passed")
