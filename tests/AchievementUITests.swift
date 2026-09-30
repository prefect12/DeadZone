import SceneKit
// App definitions are compiled without their event-loop entry point by the test harness.
precondition(WindowAvoider.isCaptureHost("com.chitaner.Longshot"))
precondition(WindowAvoider.isCaptureHost("com.apple.screencaptureui"))
precondition(WindowAvoider.isCaptureHost("com.apple.screenshot.launcher"))
precondition(!WindowAvoider.isCaptureHost(nil) && !WindowAvoider.isCaptureHost("com.apple.finder"))
let allIDs = Set(Achievement.all.map(\.id))
let groupedIDs = AchievementTrack.allCases.flatMap(\.ids) + AchievementTrack.independent.map(\.id)
precondition(groupedIDs.count == 22 && Set(groupedIDs) == allIDs, "Every achievement must occur exactly once")
var sample = Report(screens: [ScreenReport(id: "test", name: "VG270U P", damage: 0.296, shapes: 1)], days: 5, blocks: 102, moves: 952, unlocked: Dictionary(uniqueKeysWithValues: ["d1", "d3", "a5", "block100", "move100"].map { ($0, 1_790_700_000.0) }))
precondition(abs(AchievementTrack.time.progress(sample) - 0.25) < 0.00001)
precondition(abs(AchievementTrack.protection.progress(sample) - 2.0 / 400 / 5) < 0.00001, "102/10000 must not look nearly complete")
precondition(AchievementTrack.time.next(sample)?.id == "d7")
precondition(AchievementTrack.showcase(sample).map(\.id) == ["d3", "a5", "block100", "move100"])
let mouseProgress = MilestoneProgress.of(Achievement.all.first { $0.id == "block500" }!, report: sample)!
precondition(mouseProgress.current == 102 && mouseProgress.remaining == 398 && abs(mouseProgress.fraction - 0.204) < 0.00001)
for threshold in [100, 500, 1000, 2000, 5000, 10000] {
    var metrics = Metrics(); metrics.blocks = threshold
    precondition(AchievementTrack.protection.achievements.filter { $0.check(metrics) }.count == [100, 500, 1000, 2000, 5000, 10000].filter { $0 <= threshold }.count)
}
var empty = Report(screens: [], days: 0, blocks: 0, moves: 0, unlocked: [:])
precondition(AchievementTrack.showcase(empty).isEmpty)
precondition(AchievementTrack.allCases.allSatisfy { $0.progress(empty) == 0 })
var completed = sample
completed.unlocked = Dictionary(uniqueKeysWithValues: Achievement.all.map { ($0.id, 1_790_700_000.0) })
completed.screens = []
precondition(AchievementTrack.allCases.allSatisfy { $0.progress(completed) == 1 && $0.next(completed) == nil }, "Historical unlocks survive disconnected screens")
precondition(AchievementTrack.showcase(completed).count == 7)
for a in Achievement.all { precondition(NSImage(systemSymbolName: a.symbol, accessibilityDescription: nil) != nil, "Missing symbol: \(a.symbol)") }
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let application = NSApplication.shared
@MainActor func render<V: View>(_ content: V, _ name: String) {
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Render failed: \(name)") }
    try! png.write(to: output.appendingPathComponent(name + ".png"))
    print("Rendered \(name): \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
}
Task { @MainActor in
render(ShareCard(r: sample), "share-card")
render(ShareCard(r: empty), "share-empty")
render(ShareCard(r: completed), "share-completed")
let scene = MedalScene.make(Achievement.all.first { $0.id == "block100" }!, unlocked: true)
let renderer3D = SCNRenderer(device: nil, options: nil)
renderer3D.scene = scene
renderer3D.pointOfView = scene.rootNode.childNodes.first { $0.camera != nil }
let medal = scene.rootNode.childNode(withName: "medal", recursively: false)!
precondition((medal.childNodes.first?.geometry as? SCNShape)?.extrusionDepth ?? 0 > 0)
for (name, angle) in [("front", -0.30), ("side", 1.25), ("back", Double.pi)] {
    medal.eulerAngles = SCNVector3(-0.10, angle, 0.035)
    let image = renderer3D.snapshot(atTime: 0, with: CGSize(width: 600, height: 600), antialiasingMode: .multisampling4X)
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("medal-" + name + ".png"))
}
let sceneView = SCNView()
sceneView.scene = scene
MedalScene.rotate(sceneView, enabled: true)
precondition(medal.action(forKey: "turntable") != nil)
MedalScene.rotate(sceneView, enabled: false)
precondition(medal.action(forKey: "turntable") == nil && !sceneView.isPlaying && !sceneView.rendersContinuously)
print("Achievement coverage, thresholds, hover progress, permanence, showcase, symbols, 3D geometry and pause checks passed")

exit(0)
}
application.run()
