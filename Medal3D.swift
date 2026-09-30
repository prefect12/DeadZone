import Cocoa
import SwiftUI
import SceneKit

// An extruded, double-sided collectible medal. SwiftUI exports keep using the static vector face.
enum MedalScene {
    static func make(_ a: Achievement, unlocked: Bool) -> SCNScene {
        let scene = SCNScene()
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = 1.32
        camera.camera?.zNear = 0.1
        camera.camera?.zFar = 30
        camera.position = SCNVector3(0, 0, 7)
        scene.rootNode.addChildNode(camera)
        let color = unlocked ? NSColor(a.tint) : NSColor(white: 0.38, alpha: 1)
        let metal = material(color.blended(withFraction: 0.27, of: .white) ?? color, shine: 100)
        let enamel = material(color.blended(withFraction: 0.38, of: .black) ?? color, shine: 65)
        let edge = material(color.blended(withFraction: 0.48, of: .black) ?? color, shine: 85)
        let medal = SCNNode()
        medal.name = "medal"
        medal.eulerAngles = SCNVector3(-0.10, -0.25, 0.035)
        scene.rootNode.addChildNode(medal)
        let shell = hexagon(radius: 1, depth: 0.23, bevel: 0.045)
        shell.materials = [metal, metal, edge, metal, metal]
        medal.addChildNode(SCNNode(geometry: shell))
        for side: Float in [1, -1] {
            let face = SCNNode()
            face.position.z = CGFloat(side) * 0.15
            if side < 0 { face.eulerAngles.y = .pi }
            let inset = hexagon(radius: 0.865, depth: 0.055, bevel: 0.018)
            inset.materials = [enamel]
            face.addChildNode(SCNNode(geometry: inset))
            // A raised thin metal rim around the enamel inset.
            let ringPath = path(radius: 0.81)
            ringPath.append(path(radius: 0.793).reversed)
            let ring = SCNShape(path: ringPath, extrusionDepth: 0.014)
            ring.materials = [metal]
            let ringNode = SCNNode(geometry: ring)
            ringNode.position.z = 0.035
            face.addChildNode(ringNode)
            if side > 0 {
                let plate = SCNPlane(width: 0.91, height: 0.91)
                let emblem = SCNMaterial()
                emblem.diffuse.contents = symbolTexture(a.symbol)
                emblem.specular.contents = NSColor.white
                emblem.shininess = 75
                emblem.lightingModel = .blinn
                emblem.isDoubleSided = false
                plate.materials = [emblem]
                let symbol = SCNNode(geometry: plate)
                symbol.position.z = 0.065
                face.addChildNode(symbol)
            } else {
                let text = SCNText(string: "DZ", extrusionDepth: 0.028)
                text.font = NSFont.systemFont(ofSize: 0.48, weight: .heavy)
                text.flatness = 0.1
                text.chamferRadius = 0.005
                text.materials = [metal]
                let stamp = SCNNode(geometry: text)
                let box = stamp.boundingBox
                stamp.pivot = SCNMatrix4MakeTranslation((box.min.x + box.max.x) / 2, (box.min.y + box.max.y) / 2, 0)
                stamp.position.z = 0.04
                face.addChildNode(stamp)
                for i in -1...1 {
                    let dot = SCNSphere(radius: 0.025)
                    dot.materials = [metal]
                    let node = SCNNode(geometry: dot)
                    node.position = SCNVector3(CGFloat(i) * 0.14, -0.38, 0.06)
                    face.addChildNode(node)
                }
            }
            medal.addChildNode(face)
        }
        addLight(scene, type: .ambient, color: NSColor(white: 0.7, alpha: 1), intensity: 450, position: SCNVector3(0, 0, 4))
        addLight(scene, type: .omni, color: .white, intensity: 900, position: SCNVector3(-3, 4, 5))
        addLight(scene, type: .omni, color: NSColor(red: 0.55, green: 0.72, blue: 1, alpha: 1), intensity: 650, position: SCNVector3(3, 0.5, 3))
        addLight(scene, type: .omni, color: NSColor(red: 1, green: 0.78, blue: 0.5, alpha: 1), intensity: 900, position: SCNVector3(0, 3, -4))
        return scene
    }
    static func rotate(_ view: SCNView, enabled: Bool) {
        guard let medal = view.scene?.rootNode.childNode(withName: "medal", recursively: false) else { return }
        if enabled && medal.action(forKey: "turntable") == nil {
            let turn = SCNAction.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 9)
            turn.timingMode = .linear
            medal.runAction(.repeatForever(turn), forKey: "turntable")
        } else if !enabled { medal.removeAction(forKey: "turntable") }
        view.isPlaying = enabled
        view.rendersContinuously = enabled
    }
    private static func material(_ color: NSColor, shine: CGFloat) -> SCNMaterial {
        let result = SCNMaterial()
        result.lightingModel = .blinn
        result.diffuse.contents = color
        result.specular.contents = NSColor(white: 0.95, alpha: 1)
        result.shininess = shine
        return result
    }
    private static func path(radius: CGFloat) -> NSBezierPath {
        let result = NSBezierPath()
        for i in 0..<6 {
            let angle = CGFloat(i) * .pi / 3 + .pi / 2
            let point = NSPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            if i == 0 { result.move(to: point) } else { result.line(to: point) }
        }
        result.close()
        return result
    }
    private static func hexagon(radius: CGFloat, depth: CGFloat, bevel: CGFloat) -> SCNShape {
        let shape = SCNShape(path: path(radius: radius), extrusionDepth: depth)
        shape.chamferRadius = bevel
        shape.chamferMode = .both
        return shape
    }
    private static func symbolTexture(_ name: String) -> NSImage {
        let size = NSSize(width: 256, height: 256)
        let result = NSImage(size: size)
        result.lockFocus()
        if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 200, weight: .bold)) {
            let ratio = min(216 / symbol.size.width, 216 / symbol.size.height)
            let rect = NSRect(x: (256 - symbol.size.width * ratio) / 2, y: (256 - symbol.size.height * ratio) / 2, width: symbol.size.width * ratio, height: symbol.size.height * ratio)
            symbol.draw(in: rect)
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        }
        result.unlockFocus()
        return result
    }
    private static func addLight(_ scene: SCNScene, type: SCNLight.LightType, color: NSColor, intensity: CGFloat, position: SCNVector3) {
        let node = SCNNode()
        node.light = SCNLight()
        node.light?.type = type
        node.light?.color = color
        node.light?.intensity = intensity
        node.position = position
        scene.rootNode.addChildNode(node)
    }
}

final class MedalSceneView: SCNView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct Medal3D: NSViewRepresentable {
    let a: Achievement
    var unlocked = true
    var rotating = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    final class Coordinator { var key = "" }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> MedalSceneView {
        let view = MedalSceneView(frame: .zero)
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        return view
    }
    func updateNSView(_ view: MedalSceneView, context: Context) {
        let key = a.id + (unlocked ? ":earned" : ":locked")
        if context.coordinator.key != key {
            view.scene = MedalScene.make(a, unlocked: unlocked)
            context.coordinator.key = key
        }
        MedalScene.rotate(view, enabled: rotating && !reduceMotion)
    }
    static func dismantleNSView(_ view: MedalSceneView, coordinator: Coordinator) {
        MedalScene.rotate(view, enabled: false)
        view.scene = nil
    }
}

struct InteractiveMedal: View {
    let a: Achievement
    var unlocked = true
    var size: CGFloat = 64
    @State private var hovering = false
    var body: some View {
        ZStack {
            if hovering { Medal3D(a: a, unlocked: unlocked).frame(width: size, height: size * 1.08) }
            else { AchievementMedal(a: a, unlocked: unlocked, size: size) }
        }.contentShape(Rectangle()).onHover { hovering = $0 }
    }
}
