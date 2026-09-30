// DeadZone — 把显示器上坏掉的区域"挖掉"，让窗口和鼠标都当它不存在。
// 菜单栏常驻应用。坐标约定：内部统一使用 CG 全局坐标（原点在主屏左上角，y 向下）。
// 坏区是一组任意形状（多边形 / 带宽度的线条），可以位于屏幕任何位置，数量不限。

import Cocoa
import ApplicationServices
import ServiceManagement
import SwiftUI

// MARK: - 坐标工具

func primaryHeight() -> CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
func toCG(_ r: NSRect) -> CGRect { CGRect(x: r.minX, y: primaryHeight() - r.maxY, width: r.width, height: r.height) }
func toNS(_ r: CGRect) -> NSRect { NSRect(x: r.minX, y: primaryHeight() - r.maxY, width: r.width, height: r.height) }

/// 两个矩形是否有实质重叠（忽略 1pt 以内的贴边）
func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
    let i = a.intersection(b)
    return !i.isNull && i.width > 1 && i.height > 1
}

func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

// MARK: - 语言（跟随系统 / 中文 / English）

enum Lang {
    static var setting: String { UserDefaults.standard.string(forKey: "language") ?? "system" }
    static var isEnglish: Bool {
        switch setting {
        case "en": return true
        case "zh": return false
        default: return !(Locale.preferredLanguages.first ?? "en").hasPrefix("zh")
        }
    }
}

/// 界面文字：L("中文", "English")
func L(_ zh: String, _ en: String) -> String { Lang.isEnglish ? en : zh }

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    var uuid: String {
        guard let u = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return "\(displayID)" }
        return CFUUIDCreateString(nil, u) as String
    }
    var title: String { "\(localizedName)  (\(Int(frame.width))×\(Int(frame.height)))" }
}

// MARK: - 坏区形状

/// 一个坏区形状。坐标是屏幕内比例（0...1，左上原点），与分辨率无关。
enum Shape {
    case polygon([CGPoint])
    case stroke([CGPoint], width: CGFloat)      // width 为相对屏幕宽度的比例

    /// 把形状放到矩形 f 里（f 为左上原点坐标系，例如 CG 全局坐标里的屏幕、或翻转的视图）
    func path(in f: CGRect) -> CGPath {
        func map(_ p: CGPoint) -> CGPoint { CGPoint(x: f.minX + p.x * f.width, y: f.minY + p.y * f.height) }
        switch self {
        case .polygon(let pts):
            let p = CGMutablePath()
            p.addLines(between: pts.map(map))
            p.closeSubpath()
            return p
        case .stroke(let pts, let w):
            let line = CGMutablePath()
            line.addLines(between: pts.map(map))
            // 方头端点会多出半个线宽，保证贴到屏幕边缘的线条能完全盖住边缘
            return line.copy(strokingWithWidth: max(1, w * f.width), lineCap: .square, lineJoin: .round, miterLimit: 4)
        }
    }

    /// 是否是"细"坏区（平均宽度不超过 limit pt），用于"允许窗口跨过细线"
    func isThin(in f: CGRect, limit: CGFloat = 40) -> Bool {
        switch self {
        case .stroke(_, let w): return w * f.width <= limit
        case .polygon(let rel):
            let pts = rel.map { CGPoint(x: $0.x * f.width, y: $0.y * f.height) }
            guard pts.count >= 3 else { return true }
            var area: CGFloat = 0, perim: CGFloat = 0
            for i in 0..<pts.count {
                let a = pts[i], b = pts[(i + 1) % pts.count]
                area += a.x * b.y - b.x * a.y
                perim += dist(a, b)
            }
            return perim > 0 && abs(area) / perim <= limit   // 2A/P 约等于平均宽度
        }
    }

    var dict: [String: Any] {
        switch self {
        case .polygon(let p): return ["kind": "polygon", "pts": p.flatMap { [Double($0.x), Double($0.y)] }]
        case .stroke(let p, let w): return ["kind": "stroke", "pts": p.flatMap { [Double($0.x), Double($0.y)] }, "w": Double(w)]
        }
    }

    init?(dict d: [String: Any]) {
        guard let kind = d["kind"] as? String, let flat = d["pts"] as? [Double], flat.count % 2 == 0 else { return nil }
        let pts = stride(from: 0, to: flat.count, by: 2).map { CGPoint(x: flat[$0], y: flat[$0 + 1]) }
        switch kind {
        case "polygon" where pts.count >= 3: self = .polygon(pts)
        case "stroke" where pts.count >= 2: self = .stroke(pts, width: CGFloat(d["w"] as? Double ?? 0.004))
        default: return nil
        }
    }
}

func quadPoint(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
    let u = 1 - t
    let k0 = u * u, k1 = 2 * u * t, k2 = t * t
    return CGPoint(x: k0 * a.x + k1 * c.x + k2 * b.x, y: k0 * a.y + k1 * c.y + k2 * b.y)
}

func cubicPoint(_ a: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
    let u = 1 - t
    let k0 = u * u * u, k1 = 3 * u * u * t, k2 = 3 * u * t * t, k3 = t * t * t
    let x: CGFloat = k0 * a.x + k1 * c1.x + k2 * c2.x + k3 * b.x
    let y: CGFloat = k0 * a.y + k1 * c1.y + k2 * c2.y + k3 * b.y
    return CGPoint(x: x, y: y)
}

extension CGPath {
    static func poly(_ pts: [CGPoint]) -> CGPath {
        let p = CGMutablePath(); p.addLines(between: pts); p.closeSubpath(); return p
    }
}

/// 把路径拍平成线段（曲线按采样近似），用于把鼠标投影到坏区边缘
func flatten(_ path: CGPath) -> [(CGPoint, CGPoint)] {
    var segs: [(CGPoint, CGPoint)] = []
    var start = CGPoint.zero, cur = CGPoint.zero
    path.applyWithBlock { el in
        let e = el.pointee, p = e.points
        switch e.type {
        case .moveToPoint: start = p[0]; cur = p[0]
        case .addLineToPoint: segs.append((cur, p[0])); cur = p[0]
        case .addQuadCurveToPoint:
            var prev = cur
            let a = cur, c1 = p[0], b = p[1]
            for i in 1...8 {
                let q = quadPoint(a, c1, b, CGFloat(i) / 8)
                segs.append((prev, q)); prev = q
            }
            cur = b
        case .addCurveToPoint:
            var prev = cur
            let a = cur, c1 = p[0], c2 = p[1], b = p[2]
            for i in 1...8 {
                let q = cubicPoint(a, c1, c2, b, CGFloat(i) / 8)
                segs.append((prev, q)); prev = q
            }
            cur = b
        case .closeSubpath: segs.append((cur, start)); cur = start
        @unknown default: break
        }
    }
    return segs
}

// MARK: - 网格蒙版（窗口避让用：把任意形状栅格化成一组矩形）

struct Mask {
    let cols: Int, rows: Int
    var bits: [UInt8]           // 行优先，第 0 行在顶部；1 = 坏

    init(cols: Int, rows: Int, bits: [UInt8]? = nil) {
        self.cols = cols; self.rows = rows
        self.bits = bits ?? [UInt8](repeating: 0, count: cols * rows)
    }

    subscript(c: Int, r: Int) -> Bool { c >= 0 && r >= 0 && c < cols && r < rows && bits[r * cols + c] == 1 }

    /// 把蒙版合并成尽量少的矩形（网格单位，左上原点，右/下边界不含）
    func gridRects() -> [(c0: Int, r0: Int, c1: Int, r1: Int)] {
        var done: [(Int, Int, Int, Int)] = []
        var open: [Int: (c0: Int, r0: Int, c1: Int)] = [:]     // key = c0 * 100000 + c1
        for r in 0...rows {
            var runs: [(Int, Int)] = []
            if r < rows {
                var c = 0
                while c < cols {
                    if bits[r * cols + c] == 1 {
                        let s = c
                        while c < cols && bits[r * cols + c] == 1 { c += 1 }
                        runs.append((s, c))
                    } else { c += 1 }
                }
            }
            var next: [Int: (c0: Int, r0: Int, c1: Int)] = [:]
            for (s, e) in runs {
                let k = s * 100000 + e
                next[k] = open.removeValue(forKey: k) ?? (s, r, e)
            }
            for (_, v) in open { done.append((v.c0, v.r0, v.c1, r)) }
            open = next
        }
        return done.map { (c0: $0.0, r0: $0.1, c1: $0.2, r1: $0.3) }
    }
}

/// 把路径画进一张 4pt 一格的灰度图，有任何覆盖的格子都算坏（宁多勿少），再合并成矩形
func rasterize(_ paths: [CGPath], frame f: CGRect, cell: CGFloat = 4) -> [CGRect] {
    guard !paths.isEmpty else { return [] }
    let cols = Int((f.width / cell).rounded(.up)), rows = Int((f.height / cell).rounded(.up))
    guard let ctx = CGContext(data: nil, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: cols,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
          let data = ctx.data else { return [] }
    // CG 全局坐标（y 向下）-> 位图（内存第 0 行是顶部）
    ctx.translateBy(x: 0, y: CGFloat(rows))
    ctx.scaleBy(x: 1 / cell, y: -1 / cell)
    ctx.translateBy(x: -f.minX, y: -f.minY)
    ctx.setShouldAntialias(true)
    ctx.setFillColor(gray: 1, alpha: 1)
    for p in paths { ctx.addPath(p); ctx.fillPath() }

    let buf = data.bindMemory(to: UInt8.self, capacity: cols * rows)
    var m = Mask(cols: cols, rows: rows)
    for i in 0..<(cols * rows) where buf[i] > 8 { m.bits[i] = 1 }
    return m.gridRects().map {
        CGRect(x: f.minX + CGFloat($0.c0) * cell, y: f.minY + CGFloat($0.r0) * cell,
               width: CGFloat($0.c1 - $0.c0) * cell, height: CGFloat($0.r1 - $0.r0) * cell).intersection(f)
    }
}

// MARK: - 运行时的坏区（按屏幕汇总）

struct DeadZone {
    let screen: NSScreen
    let screenFrame: CGRect                 // CG 坐标，供后台线程使用（NSScreen 不宜跨线程访问）
    let paths: [CGPath]                     // 每个形状一条路径（CG 全局坐标）
    let edges: [[(CGPoint, CGPoint)]]       // 每个形状的轮廓线段
    let rects: [CGRect]                     // 窗口避让用的栅格矩形
    let bounds: CGRect                      // 所有形状在屏幕内的外接矩形
    let damage: Double                      // 损坏面积占整块屏幕的比例 0...1
    let shapeCount: Int
    let hasLine: Bool
    var visibleFrame: CGRect { toCG(screen.visibleFrame) }

    func contains(_ p: CGPoint) -> Bool { bounds.contains(p) && paths.contains { $0.contains(p) } }
}

// MARK: - 配置存储（按显示器 UUID 存比例坐标，分辨率变化后仍有效）

enum Store {
    static let key = "deadShapes"
    static let legacyKey = "deadMasks"      // 1.0 版本的"右上方死区"蒙版
    static var defaults: UserDefaults { .standard }

    static func shapes(for s: NSScreen) -> [Shape] {
        if let all = defaults.dictionary(forKey: key), let list = all[s.uuid] as? [[String: Any]] {
            return list.compactMap(Shape.init(dict:))
        }
        return migrateLegacy(for: s)
    }

    static func set(_ shapes: [Shape], for s: NSScreen) {
        var all = defaults.dictionary(forKey: key) ?? [:]
        all[s.uuid] = shapes.map(\.dict)
        defaults.set(all, forKey: key)
    }

    static func clearAll() {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: legacyKey)
    }

    /// 1.0 版本只支持"分界线右上方"的死区，存的是蒙版：把每行最左侧的坏格连成分界线，转成多边形
    private static func migrateLegacy(for s: NSScreen) -> [Shape] {
        guard let all = defaults.dictionary(forKey: legacyKey), let d = all[s.uuid] as? [String: Any],
              let cols = d["cols"] as? Int, let rows = d["rows"] as? Int,
              let data = d["bits"] as? Data, data.count == cols * rows else { return [] }
        let m = Mask(cols: cols, rows: rows, bits: [UInt8](data))
        var pts: [CGPoint] = []
        var lastRow = -1
        for r in 0..<rows {
            guard let c = (0..<cols).first(where: { m[$0, r] }) else { continue }
            let x = CGFloat(c) / CGFloat(cols)
            if pts.isEmpty { pts.append(CGPoint(x: x, y: 0)) }
            pts.append(CGPoint(x: x, y: (CGFloat(r) + 0.5) / CGFloat(rows)))
            lastRow = r
        }
        guard lastRow >= 0 else { return [] }
        pts.append(CGPoint(x: 1, y: CGFloat(lastRow + 1) / CGFloat(rows)))
        let shapes = [Shape.polygon(simplify(pts, 0.001) + [CGPoint(x: 1, y: 0)])]
        set(shapes, for: s)
        return shapes
    }

    static func zones(windowsCrossThin: Bool) -> [DeadZone] {
        NSScreen.screens.compactMap { s -> DeadZone? in
            let shapes = shapes(for: s)
            guard !shapes.isEmpty else { return nil }
            let f = toCG(s.frame)
            let paths = shapes.map { $0.path(in: f) }
            let solid = zip(shapes, paths).filter { !(windowsCrossThin && $0.0.isThin(in: f)) }.map { $0.1 }
            let bounds = paths.reduce(CGRect.null) { $0.union($1.boundingBoxOfPath) }.intersection(f)
            let hasLine = shapes.contains { if case .stroke = $0 { return true } else { return false } }
            return DeadZone(screen: s, screenFrame: f, paths: paths, edges: paths.map(flatten),
                            rects: rasterize(solid, frame: f), bounds: bounds,
                            damage: damageOf(shapes, frame: f), shapeCount: shapes.count, hasLine: hasLine)
        }
    }

    static func bool(_ k: String, default d: Bool) -> Bool {
        defaults.object(forKey: k) == nil ? d : defaults.bool(forKey: k)
    }
}

/// Douglas-Peucker 折线简化
func simplify(_ pts: [CGPoint], _ eps: CGFloat) -> [CGPoint] {
    guard pts.count > 2 else { return pts }
    let a = pts.first!, b = pts.last!
    let dx = b.x - a.x, dy = b.y - a.y, len = max(hypot(dx, dy), 0.0000001)
    var maxD: CGFloat = 0, idx = 0
    for i in 1..<(pts.count - 1) {
        let d = abs(dy * pts[i].x - dx * pts[i].y + b.x * a.y - b.y * a.x) / len
        if d > maxD { maxD = d; idx = i }
    }
    if maxD <= eps { return [a, b] }
    return Array(simplify(Array(pts[...idx]), eps).dropLast()) + simplify(Array(pts[idx...]), eps)
}

// MARK: - 不受屏幕约束的无边框窗口

class FreeWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
final class KeyableWindow: FreeWindow {
    override var canBecomeKey: Bool { true }
}

// MARK: - 黑色遮罩（形状与坏区一致）

final class ShapeView: NSView {
    var paths: [CGPath] = []                // 已平移到视图坐标（左上原点）
    override var isFlipped: Bool { true }
    override func draw(_ dirty: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        c.setFillColor(NSColor.black.cgColor)
        for p in paths { c.addPath(p); c.fillPath() }
    }
}

final class OverlayManager {
    private var windows: [NSWindow] = []

    func rebuild(zones: [DeadZone], visible: Bool) {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        guard visible else { return }
        for z in zones where !z.bounds.isNull {
            let b = z.bounds.insetBy(dx: -1, dy: -1).intersection(z.screenFrame)
            let frame = toNS(b)
            let w = FreeWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.setFrame(frame, display: false)
            w.backgroundColor = .clear
            w.isOpaque = false
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            let v = ShapeView(frame: NSRect(origin: .zero, size: frame.size))
            var t = CGAffineTransform(translationX: -b.minX, y: -b.minY)
            v.paths = z.paths.compactMap { $0.copy(using: &t) }
            w.contentView = v
            w.orderFrontRegardless()
            windows.append(w)
        }
    }
}

// MARK: - 窗口避让（Accessibility API）

final class WindowAvoider {
    private let minW: CGFloat = 240, minH: CGFloat = 160
    /// 记录挪不动的窗口，避免反复拉扯：窗口 hash -> (上次看到的位置, 尝试次数)
    private var attempts: [CFHashCode: (CGRect, Int)] = [:]
    /// 被推开的窗口次数（成就统计用，主线程读取后清零）
    var moves = 0
    /// 刚被我们退出全屏的窗口，等动画结束后放到"最大可用矩形"
    private var pendingMax: [(win: AXUIElement, since: Date)] = []

    /// 截图工具的冻结桌面/选区窗口属于屏幕级画面，移动它们会让桌面出现重影。
    static func isCaptureHost(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return ["com.chitaner.Longshot", "com.apple.screencaptureui",
                "com.apple.screenshot.launcher"].contains(bundleIdentifier)
    }

    private static let dockLayer = Int(CGWindowLevelForKey(.dockWindow))
    private static let movableLayers = Set(0..<Int(CGWindowLevelForKey(.screenSaverWindow))).subtracting([dockLayer])

    func tick(zones: [DeadZone]) {
        guard !zones.isEmpty, AXIsProcessTrusted() else { return }
        // 用户正在拖动时不抢，松手后再处理
        if NSEvent.pressedMouseButtons != 0 { return }

        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return }
        let me = getpid()
        var pids = Set<pid_t>()
        for info in list {
            // 普通窗口之外，浮动面板、模态弹窗（Wi-Fi 密码、钥匙串、"要打开吗"之类）也要推出坏区；
            // 高层分享面板也要发现；随后只处理 AXWindow / AXSheet，不移动菜单控件
            guard let layer = info[kCGWindowLayer as String] as? Int, Self.movableLayers.contains(layer),
                  (info[kCGWindowOwnerName as String] as? String) != "Dock",
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b) else { continue }
            if hit(r, zones) != nil { pids.insert(pid) }
        }
        // 全屏切换与分享服务有时不出现在本轮 CGWindowList 中；同时检查前台应用。
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != me {
            pids.insert(pid)
        }
        for pid in pids { fix(pid: pid, zones: zones) }
        finishPending(zones: zones)
        fixOwnWindows(zones: zones)
    }

    /// 自己的普通窗口（主窗口等）也要避开坏区；遮罩、编辑器、提示这些无边框窗口不管
    private func fixOwnWindows(zones: [DeadZone]) {
        let all = zones.flatMap { $0.rects }
        for w in NSApp.windows where w.isVisible && w.styleMask.contains(.titled) && !w.isMiniaturized {
            let frame = toCG(w.frame)
            guard let z = hit(frame, zones) else { continue }
            let key = CFHashCode(bitPattern: w.windowNumber)
            if let (last, n) = attempts[key], last == frame, n >= 3 { continue }
            let S = z.visibleFrame
            let maximized = frame.width >= S.width * 0.95 && frame.height >= S.height * 0.9
            guard let target = (maximized ? nil : plan(frame, dead: all, screen: S)) ?? maxRect(dead: all, screen: S) else { continue }
            w.setFrame(toNS(target), display: true, animate: true)
            moves += 1
            let after = toCG(w.frame)
            let n = (attempts[key]?.0 == frame ? attempts[key]!.1 : 0) + 1
            attempts[key] = (after, n)
        }
    }

    private func finishPending(zones: [DeadZone]) {
        let all = zones.flatMap { $0.rects }
        pendingMax = pendingMax.filter { item in
            let elapsed = Date().timeIntervalSince(item.since)
            if elapsed > 10 { return false }
            // AXFullScreen 在动画结束前就会变为 false；太早调整会被恢复动画覆盖。
            if elapsed < 1.5 { return true }
            if boolAttr(item.win, "AXFullScreen") {
                // 切换动画中设置可能暂时失败，后续 tick 重试，且只保留有限时间。
                AXUIElementSetAttributeValue(item.win, "AXFullScreen" as CFString, kCFBooleanFalse)
                return true
            }
            guard let frame = frameOf(item.win),
                  let z = zones.first(where: { $0.screenFrame.intersects(frame) }),
                  let target = maxRect(dead: all, screen: z.visibleFrame) else { return true }
            setFrame(item.win, target)
            // 动画可能还没完全结束，位置没到就下个 tick 再来
            guard let after = frameOf(item.win) else { return false }
            return abs(after.minX - target.minX) > 2 || abs(after.minY - target.minY) > 2
                || abs(after.width - target.width) > 2 || abs(after.height - target.height) > 2
        }
    }

    /// 屏幕可用区域里避开所有坏区后面积最大的矩形——相当于这块"异形屏"上的最大化
    func maxRect(dead: [CGRect], screen S: CGRect) -> CGRect? {
        let ds = dead.filter { overlaps($0, S) }
        if ds.isEmpty { return S }
        // 候选的上下边：屏幕边缘 + 各坏区的上下沿（按 8pt 取整去重，控制计算量）
        func q(_ v: CGFloat) -> CGFloat { (v / 8).rounded() * 8 }
        let inner = { (v: CGFloat) in v > S.minY && v < S.maxY }
        let tops = Array(Set([S.minY] + ds.map { q($0.maxY) }.filter(inner))).sorted()
        let bottoms = Array(Set([S.maxY] + ds.map { q($0.minY) }.filter(inner))).sorted()
        var best: CGRect?
        for top in tops {
            for bottom in bottoms where bottom - top >= minH {
                let blocked = ds.filter { $0.minY < bottom - 1 && $0.maxY > top + 1 }.map { ($0.minX, $0.maxX) }
                for (a, b) in free(S.minX, S.maxX, blocked) where b - a >= minW {
                    let r = CGRect(x: a, y: top, width: b - a, height: bottom - top)
                    if best == nil || r.width * r.height > best!.width * best!.height { best = r }
                }
            }
        }
        // 取整可能让边缘稍微压到坏区，最后再收紧一次
        if var r = best {
            for d in ds where overlaps(d, r) {
                if d.maxY <= r.midY { r.size.height -= d.maxY - r.minY; r.origin.y = d.maxY }
                else if d.minY >= r.midY { r.size.height = d.minY - r.minY }
            }
            best = r
        }
        return best
    }

    private func hit(_ w: CGRect, _ zones: [DeadZone]) -> DeadZone? {
        zones.first { overlaps($0.bounds, w) && $0.rects.contains { overlaps($0, w) } }
    }

    private func fix(pid: pid_t, zones: [DeadZone]) {
        // 在统一入口过滤，覆盖 CGWindowList 与前台应用两条发现路径。
        guard !Self.isCaptureHost(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier) else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)   // 卡死的应用最多等 0.3s
        let wins = windowElements(app)
        let all = zones.flatMap { $0.rects }
        for win in wins {
            if boolAttr(win, kAXMinimizedAttribute) { continue }
            guard let frame = frameOf(win), let z = hit(frame, zones) else { continue }

            // 系统全屏：退出全屏，改成"避开坏区的最大化"
            if boolAttr(win, "AXFullScreen") {
                if !pendingMax.contains(where: { CFEqual($0.win, win) }) {
                    AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, kCFBooleanFalse)
                    // 异步切换可能返回 cannotComplete 但仍然执行；按实际状态确认。
                    pendingMax.append((win, Date()))
                }
                continue
            }
            if pendingMax.contains(where: { CFEqual($0.win, win) }) { continue }

            // 无法移动的嵌入式控件不当成独立窗口，避免反复尝试。
            guard isSettable(win, kAXPositionAttribute) else { continue }
            // 最大化 / 铺满（双击标题栏、⌥+绿色按钮等）：放到最大可用矩形
            let S = z.visibleFrame
            if frame.width >= S.width * 0.95 && frame.height >= S.height * 0.9,
               let target = maxRect(dead: all, screen: S) {
                setFrame(win, target)
                continue
            }

            let key = CFHash(win)
            if let (last, n) = attempts[key], last == frame, n >= 3 { continue }   // 放弃这个倔强的窗口

            // 弹窗、对话框一般不能改大小：只挪位置，找一个整块放得下的地方
            let target: CGRect?
            var roleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXRoleAttribute as CFString, &roleValue)
            let isPopover = (roleValue as? String) == "AXPopover"
            if !isPopover && isSettable(win, kAXSizeAttribute) {
                target = plan(frame, dead: all, screen: S) ?? maxRect(dead: all, screen: S)
            } else {
                target = place(frame, dead: all, screen: S)
            }
            guard let target else { continue }
            if isPopover {
                var point = target.origin
                if let value = AXValueCreate(.cgPoint, &point) {
                    AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, value)
                }
            } else { setFrame(win, target) }
            moves += 1
            let after = frameOf(win) ?? target
            let n = (attempts[key]?.0 == frame ? attempts[key]!.1 : 0) + 1
            attempts[key] = (after, n)
        }
        if attempts.count > 500 { attempts.removeAll() }
    }

    /// 分享服务和 sheet 不一定列在 AXWindows；有限遍历附属窗口与焦点祖先。
    private func windowElements(_ app: AXUIElement) -> [AXUIElement] {
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
        var roots = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        if let value = attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
            roots.append(value as! AXUIElement)
        }
        if let value = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
            var element = value as! AXUIElement
            for _ in 0..<8 {
                let role = attribute(element, kAXRoleAttribute) as? String
                if role == kAXWindowRole || role == kAXSheetRole || role == "AXPopover" { roots.append(element) }
                guard let parent = attribute(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                element = parent as! AXUIElement
            }
        }
        var seen = Set<CFHashCode>(), result: [AXUIElement] = []
        var queue = roots.map { ($0, 0) }, index = 0
        while index < queue.count && index < 120 {
            let (element, depth) = queue[index]; index += 1
            guard seen.insert(CFHash(element)).inserted else { continue }
            let role = attribute(element, kAXRoleAttribute) as? String
            if role == kAXWindowRole || role == kAXSheetRole || role == "AXPopover" { result.append(element) }
            guard depth < 3 else { continue }
            for name in ["AXSheets", kAXChildrenAttribute] {
                let children = attribute(element, name) as? [AXUIElement] ?? []
                queue.append(contentsOf: children.prefix(max(0, 120 - queue.count)).map { ($0, depth + 1) })
            }
        }
        return result
    }

    /// 在 [lo, hi] 中扣掉被占用的区间，返回空闲区间
    private func free(_ lo: CGFloat, _ hi: CGFloat, _ blocked: [(CGFloat, CGFloat)]) -> [(CGFloat, CGFloat)] {
        var out: [(CGFloat, CGFloat)] = [], cur = lo
        for (a, b) in blocked.sorted(by: { $0.0 < $1.0 }) {
            if a > cur { out.append((cur, min(a, hi))) }
            cur = max(cur, b)
            if cur >= hi { break }
        }
        if cur < hi { out.append((cur, hi)) }
        return out.filter { $0.1 > $0.0 }
    }

    /// 计算一个不与坏区重叠的新位置：保持高度左右挪 / 保持宽度上下挪，放不下就缩小，取改动最小的
    func plan(_ w: CGRect, dead: [CGRect], screen S: CGRect, keepSize: Bool = false) -> CGRect? {
        var cands: [CGRect] = []

        // 水平方向：与窗口同高度范围内的坏区投影到 x 轴
        let hb = dead.filter { $0.minY < w.maxY - 1 && $0.maxY > w.minY + 1 }.map { ($0.minX, $0.maxX) }
        for (a, b) in free(S.minX, S.maxX, hb) {
            let nw = min(w.width, b - a)
            cands.append(CGRect(x: min(max(w.minX, a), b - nw), y: w.minY, width: nw, height: w.height))
        }
        // 垂直方向：与窗口同宽度范围内的坏区投影到 y 轴
        let vb = dead.filter { $0.minX < w.maxX - 1 && $0.maxX > w.minX + 1 }.map { ($0.minY, $0.maxY) }
        for (a, b) in free(S.minY, S.maxY, vb) {
            let nh = min(w.height, b - a)
            cands.append(CGRect(x: w.minX, y: min(max(w.minY, a), b - nh), width: w.width, height: nh))
        }

        func cost(_ c: CGRect) -> CGFloat {
            hypot(c.minX - w.minX, c.minY - w.minY) + 2 * (w.width - c.width) + 2 * (w.height - c.height)
        }
        return cands
            .filter { c in keepSize ? c.size == w.size : c.width >= minW && c.height >= minH }
            .filter { c in !dead.contains { overlaps($0, c) } }
            .min { cost($0) < cost($1) }
    }

    /// 不改尺寸，只移动：优先左右 / 上下平移，都不行就放到最大可用矩形的中央
    func place(_ w: CGRect, dead: [CGRect], screen S: CGRect) -> CGRect? {
        if let r = plan(w, dead: dead, screen: S, keepSize: true) { return r }
        guard let m = maxRect(dead: dead, screen: S), m.width >= w.width, m.height >= w.height else { return nil }
        return CGRect(x: m.midX - w.width / 2, y: m.midY - w.height / 2, width: w.width, height: w.height).integral
    }

    private func isSettable(_ e: AXUIElement, _ a: String) -> Bool {
        var ok: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(e, a as CFString, &ok) == .success && ok.boolValue
    }

    private func boolAttr(_ e: AXUIElement, _ a: String) -> Bool {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success && (v as? Bool) == true
    }

    private func frameOf(_ e: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &sv) == .success,
              let pv, let sv else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    private func setFrame(_ e: AXUIElement, _ r: CGRect) {
        var p = r.origin, s = r.size
        guard let pv = AXValueCreate(.cgPoint, &p), let sv = AXValueCreate(.cgSize, &s) else { return }
        // 先移后缩再移：有些应用在尺寸改变时会自己调整位置
        AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, pv)
        AXUIElementSetAttributeValue(e, kAXSizeAttribute as CFString, sv)
        AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, pv)
    }
}

// MARK: - 鼠标拦截（CGEventTap：在事件送达前修正位置）
// - 窄的坏区（细线、裂纹）：沿运动方向直接跳到另一侧，就像它不存在
// - 大块坏区：贴着边缘滑动
// tap 跑在独立线程上：主线程做窗口操作时即使被某个应用卡住，也不会拖慢鼠标。

final class MouseGuard {
    private let lock = NSLock()
    private var _zones: [DeadZone] = []
    private var _screens: [CGRect] = []
    private var lastGood: CGPoint?
    private let jumpMax: CGFloat = 48           // 小于这个厚度的坏区直接跳过
    private var lastBlockedAt: TimeInterval = -.infinity
    private let blockGap: TimeInterval = 0.5    // 距上次被挡超过这么久才算新的一次撞墙
    private var _blocks = 0                     // 撞墙次数（成就统计用）

    /// 取走累计的撞墙次数
    func takeBlocks() -> Int { lock.lock(); defer { _blocks = 0; lock.unlock() }; return _blocks }

    func update(zones: [DeadZone], screens: [CGRect]) {
        lock.lock(); _zones = zones; _screens = screens; lock.unlock()
    }
    private func snapshot() -> ([DeadZone], [CGRect]) {
        lock.lock(); defer { lock.unlock() }; return (_zones, _screens)
    }

    var onMouseUp: (() -> Void)?
    fileprivate var tap: CFMachPort?
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    var running: Bool { tap != nil }

    func start() {
        guard tap == nil else { return }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .leftMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: mouseTapCallback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        tap = t
        // warp 之后系统默认会压住本地鼠标事件约 0.25s，这是"卡一下"的来源，关掉它
        CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0
        CGEventSource(stateID: .hidSystemState)?.localEventsSuppressionInterval = 0

        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        let th = Thread { [weak self] in
            self?.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            CFRunLoopRun()
        }
        th.name = "DeadZone.MouseTap"
        th.qualityOfService = .userInteractive
        th.start()
        thread = th
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let rl = runLoop { CFRunLoopStop(rl) }
        tap = nil; thread = nil; runLoop = nil
    }

    fileprivate func handle(_ type: CGEventType, _ e: CGEvent) {
        if type == .leftMouseUp {
            if let cb = onMouseUp { DispatchQueue.main.async(execute: cb) }
            return
        }
        let (zones, screens) = snapshot()
        let p = e.location
        guard let z = zones.first(where: { $0.contains(p) }) else { lastGood = p; return }
        // 贴边滑动时光标会在边缘内外反复横跳，按"出去再进来"计数会暴涨；
        // 改为按时间去抖：持续顶墙或贴边滑动只算一次
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastBlockedAt > blockGap { lock.lock(); _blocks += 1; lock.unlock() }
        lastBlockedAt = now

        func valid(_ q: CGPoint) -> Bool {
            screens.contains { $0.contains(q) } && !zones.contains { $0.contains(q) }
        }
        guard let q = resolve(p, z, valid) ?? lastGood.flatMap({ valid($0) ? $0 : nil }) else { return }
        lastGood = q
        e.location = q
        CGWarpMouseCursorPosition(q)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func resolve(_ p: CGPoint, _ z: DeadZone, _ valid: (CGPoint) -> Bool) -> CGPoint? {
        // 1. 窄坏区：沿运动方向往前找出口，近的话直接跳过去
        if let l = lastGood {
            let dx = p.x - l.x, dy = p.y - l.y, n = hypot(dx, dy)
            if n > 0.01 {
                let ux = dx / n, uy = dy / n
                var s: CGFloat = 1
                while s <= jumpMax {
                    let q = CGPoint(x: p.x + ux * s, y: p.y + uy * s)
                    if valid(q) { return CGPoint(x: q.x + ux, y: q.y + uy) }
                    s += 1
                }
            }
        }
        // 2. 大坏区：投影到所在形状的最近边缘 + 按轴向滑动，取离 p 最近的合法点
        var cands: [CGPoint] = []
        for (i, path) in z.paths.enumerated() where path.contains(p) {
            var best = p, bd = CGFloat.greatestFiniteMagnitude
            for (a, b) in z.edges[i] {
                let dx = b.x - a.x, dy = b.y - a.y, l2 = dx * dx + dy * dy
                let t = l2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
                let q = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
                let d = dist(p, q)
                if d < bd { bd = d; best = q }
            }
            let n = max(bd, 0.001)
            for push: CGFloat in [0.5, 1, 2, 4, 8] {
                cands.append(CGPoint(x: best.x + (best.x - p.x) / n * push, y: best.y + (best.y - p.y) / n * push))
            }
        }
        if let l = lastGood { cands += [CGPoint(x: p.x, y: l.y), CGPoint(x: l.x, y: p.y)] }
        return cands.filter(valid).min { dist($0, p) < dist($1, p) }
    }
}

private func mouseTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let me = Unmanaged<MouseGuard>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
    } else {
        me.handle(type, event)
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - 坏区编辑器
// 坏区里常常什么都看不见，所以所有工具都是在"看得见的一侧"沿边缘操作；
// 贯穿全屏的绿色十字线帮助判断鼠标进了黑区后的位置。
// 屏幕上有一个浮动工具栏：切换工具、调线宽、撤销/清空、保存，并实时提示下一步该做什么。

enum EditorTool: String, CaseIterable, Identifiable {
    case split, polygon, rect, line
    var id: String { rawValue }
    var title: String {
        switch self {
        case .split: return L("分割", "Split")
        case .polygon: return L("多边形", "Polygon")
        case .rect: return L("矩形", "Rectangle")
        case .line: return L("线条", "Line")
        }
    }
    var icon: String {
        switch self {
        case .split: return "square.split.diagonal"
        case .polygon: return "pentagon"
        case .rect: return "rectangle"
        case .line: return "line.diagonal"
        }
    }
    /// 引导卡片：什么样的坏法用这个工具
    var situation: String {
        switch self {
        case .split: return L("角落或一整边黑了", "A corner or a whole side is dark")
        case .line: return L("中间有一条竖线 / 横线 / 裂纹", "A vertical / horizontal line or a crack")
        case .polygon: return L("中间有一块不规则的斑", "An irregular blotch in the middle")
        case .rect: return L("一块规整的矩形", "A neat rectangular area")
        }
    }
    var advice: String {
        switch self {
        case .split: return L("如左上角、右下角、半边屏：沿黑区边界画一条线，再选黑的那一边", "e.g. top-left, bottom-right, half the screen: draw a line along the edge, then pick the dark side")
        case .line: return L("在线的两端各点一下；端点点在屏幕边缘，线就会贯穿整屏", "Click both ends of the line; ends on the screen edge make it span the screen")
        case .polygon: return L("沿斑的边缘点一圈，把它围起来", "Click around its edge to enclose it")
        case .rect: return L("按住鼠标，直接拖出一个矩形", "Just drag out a rectangle")
        }
    }
    static let guideOrder: [EditorTool] = [.split, .line, .polygon, .rect]

    var key: String {
        switch self {
        case .split: return "1"
        case .polygon: return "2"
        case .rect: return "3"
        case .line: return "4"
        }
    }
    var usage: String {
        switch self {
        case .split: return L("一边全黑看不清：画分界线，选一边", "One side is black: draw a dividing line, pick a side")
        case .polygon: return L("任意形状的斑块、角落", "Blobs and corners of any shape")
        case .rect: return L("规整的矩形区域", "Rectangular areas")
        case .line: return L("竖线、横线、裂纹", "Dead lines and cracks")
        }
    }
}

/// 编辑器与工具栏共享的状态
final class EditorState: ObservableObject {
    @Published var tool: EditorTool = .split
    @Published var splitLabels: [String] = []    // 分割后两边的名字，非空表示正在选边
    @Published var hoverSide: Int?
    @Published var lineWidth: CGFloat = 8
    @Published var points = 0
    @Published var dragging = false
    @Published var shapeCount = 0
    @Published var canUndo = false
    @Published var screenLabel = ""
    @Published var multiScreen = false
    @Published var showGuide = true             // 开场引导：先问是哪种坏法

    var drawing: Bool { points > 0 || dragging || !splitLabels.isEmpty }

    var step: (icon: String, text: String) {
        switch tool {
        case .split:
            if !splitLabels.isEmpty { return ("4.circle.fill", L("选择哪一边是坏区：点下面的按钮（鼠标移上去可以预览），或直接点击那一边", "Pick the dead side: click a button below (hover to preview), or click that side directly")) }
            if points == 0 { return ("1.circle.fill", L("沿着黑区的边界画一条分界线：先在线的一端单击（不用点到屏幕边缘，会自动延伸过去）", "Draw a line along the edge of the black area: click one end first (no need to reach the screen edge, it extends automatically)")) }
            if points < 2 { return ("2.circle.fill", L("继续沿边界单击，或按住拖动描出分界线", "Keep clicking along the edge, or drag to trace the line")) }
            return ("3.circle.fill", L("双击 或 按回车，完成分界线 · 已放 \(points) 个点", "Double-click or press Return to finish the line · \(points) points"))
        case .polygon:
            if points == 0 { return ("1.circle.fill", L("在坏区边缘单击，放下第一个点（在看得见的一侧；也可以按住拖动描边）", "Click on the edge of the dead area to place the first point (from the visible side; you can also drag to trace)")) }
            if points < 3 { return ("2.circle.fill", L("继续沿边缘单击，把坏区围起来 · 已放 \(points) 个点，至少要 3 个", "Keep clicking along the edge to enclose it · \(points) points, at least 3 needed")) }
            return ("3.circle.fill", L("双击 或 按回车，完成这一块 · 已放 \(points) 个点", "Double-click or press Return to finish this area · \(points) points"))
        case .rect:
            return dragging ? ("2.circle.fill", L("松开鼠标完成这一块", "Release to finish this area")) : ("1.circle.fill", L("按住鼠标，拖出一个盖住坏区的矩形", "Drag out a rectangle that covers the dead area"))
        case .line:
            if points == 0 { return ("1.circle.fill", L("在坏线的一端单击（点在屏幕边缘，线就会贯穿整块屏幕）", "Click one end of the dead line (click on the screen edge to span the whole screen)")) }
            if points < 2 { return ("2.circle.fill", L("在坏线的另一端单击", "Click the other end of the dead line")) }
            return ("3.circle.fill", L("双击 或 按回车，完成这条线 · 可以继续点击画折线", "Double-click or press Return to finish · keep clicking for a polyline"))
        }
    }

    // 工具栏上的操作，由 EditorView 实现
    var setTool: (EditorTool) -> Void = { _ in }
    var chooseSide: (Int) -> Void = { _ in }
    var toggleGuide: (Bool) -> Void = { _ in }
    var hoverChanged: () -> Void = {}
    var undo: () -> Void = {}
    var clear: () -> Void = {}
    var finishShape: () -> Void = {}
    var save: () -> Void = {}
    var cancel: () -> Void = {}
    var nextScreen: () -> Void = {}
    var widthChanged: () -> Void = {}
}

struct EditorToolbar: View {
    @ObservedObject var s: EditorState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L("圈选坏区", "Mark Dead Zones") + " · \(s.screenLabel)", systemImage: "display").font(.headline)
                Spacer()
                if !s.showGuide {
                    Button { s.toggleGuide(true) } label: { Label(L("选哪个工具？", "Which tool?"), systemImage: "questionmark.circle") }
                }
                if s.multiScreen {
                    Button { s.nextScreen() } label: { Label(L("下一块屏幕", "Next Screen"), systemImage: "arrow.right.to.line") }
                        .help(L("保存当前屏幕，切换到下一块（Tab）", "Save this screen and switch to the next one (Tab)"))
                }
            }

            if s.showGuide {
                ToolGuide(s: s)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ForEach(EditorTool.allCases) { t in
                        Button { s.setTool(t) } label: {
                            VStack(spacing: 3) {
                                Image(systemName: t.icon).font(.system(size: 18))
                                Text(t.title).font(.caption.bold())
                            }
                            .frame(width: 64, height: 46)
                            .background(s.tool == t ? Color.accentColor : Color.primary.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 9))
                            .foregroundStyle(s.tool == t ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .help("\(t.title): \(t.usage) (\(t.key))")
                    }
                    if s.tool == .line {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("线宽", "Width") + " \(Int(s.lineWidth)) pt").font(.caption).monospacedDigit()
                            Slider(value: Binding(get: { Double(s.lineWidth) },
                                                  set: { s.lineWidth = CGFloat($0); s.widthChanged() }), in: 2...120)
                                .frame(width: 130)
                        }
                        .padding(.leading, 6)
                    } else {
                        Text(s.tool.usage).font(.caption).foregroundStyle(.secondary).padding(.leading, 6)
                    }
                    Spacer(minLength: 8)
                    Button { s.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(!s.canUndo && !s.drawing).help(L("撤销（⌘Z）", "Undo (⌘Z)"))
                    Button { s.clear() } label: { Image(systemName: "trash") }
                        .disabled(s.shapeCount == 0 && !s.drawing).help(L("清空这块屏幕的全部坏区", "Clear all dead zones on this screen"))
                }

                if !s.splitLabels.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(Array(s.splitLabels.enumerated()), id: \.offset) { i, label in
                            Button { s.chooseSide(i) } label: {
                                Text(L("把「\(label)」设为坏区", "Mark \(label) as dead")).font(.system(size: 14, weight: .semibold))
                                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(s.hoverSide == i ? .red : .gray)
                            .onHover { h in
                                if h { s.hoverSide = i } else if s.hoverSide == i { s.hoverSide = nil }
                                s.hoverChanged()
                            }
                        }
                    }
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: s.step.icon).font(.system(size: 18)).foregroundStyle(Color.yellow)
                    Text(s.step.text).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))

                HStack {
                    Text(s.shapeCount == 0 ? L("还没有圈选", "Nothing marked yet") : L("已圈选 \(s.shapeCount) 块 · 右键点红色区域可删除", "\(s.shapeCount) marked · right-click a red area to delete it"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("取消", "Cancel")) { s.cancel() }.keyboardShortcut(.cancelAction)
                    if s.drawing && s.tool != .rect && s.splitLabels.isEmpty {
                        Button(s.tool == .split ? L("完成分界线", "Finish Line") : L("完成这一块", "Finish Area")) { s.finishShape() }
                    }
                    Button(L("保存并退出", "Save & Exit")) { s.save() }.buttonStyle(.borderedProminent)
                }
                }
            }
        }
        .padding(16)
        .frame(width: 600)
        .background(Color(white: 0.11).opacity(0.97), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.15)))
        .environment(\.colorScheme, .dark)
    }
}

/// 开场引导里的示意小图
struct GuideSketch: View {
    let tool: EditorTool
    var body: some View {
        Canvas { ctx, size in
            let W = size.width, H = size.height
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.23, green: 0.45, blue: 0.75)))
            let yellow = GraphicsContext.Shading.color(.yellow)
            func dot(_ p: CGPoint) { ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)), with: yellow) }
            switch tool {
            case .split:
                let a = CGPoint(x: W * 0.42, y: 0), b = CGPoint(x: W, y: H * 0.62), c = CGPoint(x: W * 0.6, y: H * 0.5)
                var p = Path(); p.move(to: a); p.addQuadCurve(to: b, control: c); p.addLine(to: CGPoint(x: W, y: 0)); p.closeSubpath()
                ctx.fill(p, with: .color(.black))
                var l = Path(); l.move(to: a); l.addQuadCurve(to: b, control: c)
                ctx.stroke(l, with: yellow, style: StrokeStyle(lineWidth: 2, dash: [4, 2]))
            case .line:
                let x = W * 0.56
                ctx.fill(Path(CGRect(x: x - 1.5, y: 0, width: 3, height: H)), with: .color(.black))
                dot(CGPoint(x: x, y: 3)); dot(CGPoint(x: x, y: H - 3))
            case .polygon:
                let c = CGPoint(x: W * 0.55, y: H * 0.5)
                let pts = [0.0, 0.9, 1.7, 2.6, 3.5, 4.4, 5.3].enumerated().map { i, a -> CGPoint in
                    let r = [0.30, 0.22, 0.34, 0.26, 0.32, 0.2, 0.28][i]
                    return CGPoint(x: c.x + cos(a) * W * r * 0.8, y: c.y + sin(a) * H * r * 1.1)
                }
                var p = Path(); p.addLines(pts); p.closeSubpath()
                ctx.fill(p, with: .color(.black))
                ctx.stroke(p, with: yellow, lineWidth: 1)
                pts.forEach(dot)
            case .rect:
                let r = CGRect(x: W * 0.14, y: H * 0.5, width: W * 0.42, height: H * 0.34)
                ctx.fill(Path(r), with: .color(.black))
                ctx.stroke(Path(r), with: yellow, lineWidth: 1.5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.black, lineWidth: 2))
    }
}

/// 开场引导：你的屏幕是哪种坏法？
struct ToolGuide: View {
    @ObservedObject var s: EditorState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("你的屏幕是哪种坏法？选一个最像的", "What does the damage look like? Pick the closest match"))
                .font(.system(size: 15, weight: .semibold))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(EditorTool.guideOrder) { t in card(t) }
            }
            HStack {
                Text(L("之后可以随时切换工具，多种工具也能叠加使用", "You can switch tools any time and combine them"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("取消", "Cancel")) { s.cancel() }
            }
        }
    }

    private func card(_ t: EditorTool) -> some View {
        Button { s.setTool(t) } label: {
            HStack(alignment: .top, spacing: 12) {
                GuideSketch(tool: t).frame(width: 92, height: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Text(t.situation).font(.system(size: 13, weight: .semibold))
                    Text(t.advice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Label("\(t.title) · \(t.key)", systemImage: t.icon).font(.caption2.bold())
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.35), in: Capsule())
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

final class EditorView: NSView {
    var shapes: [Shape]
    let state = EditorState()
    var onFinish: (([Shape]?) -> Void)?
    var onNextScreen: (([Shape]) -> Void)?      // Tab：保存并切到下一块屏幕

    private var tool: EditorTool { state.tool }
    private var lineWidth: CGFloat { state.lineWidth }
    private var pts: [CGPoint] = []            // 正在画的点（视图坐标，左上原点）
    private var dragStart: CGPoint?
    private var dragRect: CGRect?
    private var cursor: CGPoint?
    private var undoStack: [[Shape]] = []
    private let snapDist: CGFloat = 16
    private var toolbar: NSHostingView<EditorToolbar>!
    private var sides: [[CGPoint]] = []         // 分割后的两边（视图坐标）
    private var sideNames: [String] = []
    private var splitLine: [CGPoint] = []

    init(frame: NSRect, shapes: [Shape]) {
        self.shapes = shapes
        super.init(frame: frame)
        state.setTool = { [weak self] t in self?.setTool(t) }
        state.chooseSide = { [weak self] i in self?.choose(i) }
        state.toggleGuide = { [weak self] on in
            self?.state.showGuide = on
            self?.relayout()
        }
        state.hoverChanged = { [weak self] in self?.needsDisplay = true }
        state.undo = { [weak self] in self?.undo() }
        state.clear = { [weak self] in self?.clearAll() }
        state.finishShape = { [weak self] in self?.finish() }
        state.save = { [weak self] in self?.save() }
        state.cancel = { [weak self] in self?.cancel() }
        state.nextScreen = { [weak self] in self?.nextScreen() }
        state.widthChanged = { [weak self] in self?.needsDisplay = true }

        toolbar = NSHostingView(rootView: EditorToolbar(s: state))
        addSubview(toolbar)
        sync()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }       // 左上原点，和比例坐标方向一致
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    private var W: CGFloat { bounds.width }
    private var H: CGFloat { bounds.height }
    private var drawing: Bool { !pts.isEmpty || dragRect != nil || !sides.isEmpty }
    private var choosing: Bool { !sides.isEmpty }

    private func rel(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / W, y: p.y / H) }
    private func loc(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    /// 把状态同步给工具栏，并把工具栏放到不挡坏区的地方
    private func sync() {
        state.points = pts.count
        state.splitLabels = sideNames
        if sides.isEmpty { state.hoverSide = nil }
        state.dragging = dragRect != nil
        state.shapeCount = shapes.count
        state.canUndo = !undoStack.isEmpty
        placeToolbar()
        needsDisplay = true
    }

    private func placeToolbar() {
        let size = toolbar.fittingSize
        let paths = shapes.map { $0.path(in: bounds) }
        let spots = [CGPoint(x: (W - size.width) / 2, y: H - size.height - 48),
                     CGPoint(x: (W - size.width) / 2, y: 48),
                     CGPoint(x: 48, y: H - size.height - 48),
                     CGPoint(x: 48, y: 48),
                     CGPoint(x: (W - size.width) / 2, y: (H - size.height) / 2)]
        let pick = spots.first { o in
            let r = CGRect(origin: o, size: size).insetBy(dx: -8, dy: -8)
            let rp = CGPath(rect: r, transform: nil)
            return !paths.contains { !$0.intersection(rp).isEmpty }
        } ?? spots[0]
        let frame = CGRect(origin: pick, size: size)
        if toolbar.frame != frame { toolbar.frame = frame }
    }

    private func refocus() { window?.makeFirstResponder(self) }

    /// 靠近屏幕边缘时吸附到边上（靠近两条边就吸到角上）
    private func snap(_ p: CGPoint) -> CGPoint {
        var q = CGPoint(x: min(max(p.x, 0), W), y: min(max(p.y, 0), H))
        if q.x < snapDist { q.x = 0 }
        if q.y < snapDist { q.y = 0 }
        if W - q.x < snapDist { q.x = W }
        if H - q.y < snapDist { q.y = H }
        return q
    }

    // MARK: 操作

    private func commit(_ s: Shape) {
        undoStack.append(shapes)
        shapes.append(s)
    }

    private func finish() {
        if choosing { NSSound.beep(); return }       // 先选一边
        switch tool {
        case .split where pts.count >= 2:
            if let sd = splitSides(pts) {
                sides = sd
                splitLine = extendLine(pts)
                sideNames = sd.map(sideLabel)
            } else { NSSound.beep() }
        case .polygon where pts.count >= 3: commit(.polygon(pts.map(rel)))
        case .line where pts.count >= 2: commit(.stroke(pts.map(rel), width: lineWidth / W))
        default: if !pts.isEmpty { NSSound.beep() }
        }
        pts.removeAll()
        sync(); refocus()
    }

    /// 工具栏内容变化后，等 SwiftUI 算好尺寸再重新摆放
    private func relayout() {
        sync()
        DispatchQueue.main.async { [weak self] in self?.sync() }
        refocus()
    }

    private func setTool(_ t: EditorTool) {
        if state.showGuide { state.showGuide = false; relayout() }
        clearSplit()
        if !pts.isEmpty { finish() }
        state.tool = t
        sync(); refocus()
    }

    private func undo() {
        if choosing { clearSplit(); sync(); refocus(); return }
        if !pts.isEmpty { pts.removeLast() } else if let s = undoStack.popLast() { shapes = s }
        sync(); refocus()
    }

    private func clearAll() {
        guard !shapes.isEmpty || !pts.isEmpty else { return }
        undoStack.append(shapes)
        shapes.removeAll(); pts.removeAll()
        sync(); refocus()
    }

    private func save() {
        if choosing { NSSound.beep(); return }       // 还没选边
        if tool == .split && pts.count >= 2 { finish(); return }
        if drawing { finish() }
        onFinish?(shapes)
    }

    private func clearSplit() { sides = []; sideNames = []; splitLine = [] }

    private func choose(_ i: Int) {
        guard sides.indices.contains(i) else { return }
        commit(.polygon(sides[i].map(rel)))
        clearSplit()
        sync(); refocus()
    }

    private func cancel() {
        if choosing { clearSplit(); sync(); refocus(); return }
        if drawing { pts.removeAll(); dragRect = nil; dragStart = nil; sync(); refocus() } else { onFinish?(nil) }
    }

    private func nextScreen() {
        clearSplit()
        if drawing { finish() }
        onNextScreen?(shapes)
    }

    // MARK: 分割几何（视图坐标，左上原点）

    private func onBorder(_ p: CGPoint) -> Bool { p.x <= 0.5 || p.y <= 0.5 || p.x >= W - 0.5 || p.y >= H - 0.5 }

    /// 从 p 沿 (dx, dy) 射到屏幕边框
    private func ray(_ p: CGPoint, _ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
        var t = CGFloat.greatestFiniteMagnitude
        if dx > 0 { t = min(t, (W - p.x) / dx) } else if dx < 0 { t = min(t, -p.x / dx) }
        if dy > 0 { t = min(t, (H - p.y) / dy) } else if dy < 0 { t = min(t, -p.y / dy) }
        guard t < .greatestFiniteMagnitude else { return p }
        return CGPoint(x: min(max(p.x + dx * t, 0), W), y: min(max(p.y + dy * t, 0), H))
    }

    /// 两端顺着线的方向延伸到屏幕边缘
    private func extendLine(_ pts: [CGPoint]) -> [CGPoint] {
        guard pts.count >= 2 else { return pts }
        func far(_ seq: [CGPoint]) -> CGPoint { seq.dropFirst().first { dist($0, seq[0]) > 40 } ?? seq[1] }
        var out = pts
        if !onBorder(pts[0]) { let f = far(pts); out.insert(ray(pts[0], pts[0].x - f.x, pts[0].y - f.y), at: 0) }
        let rev = Array(pts.reversed())
        if !onBorder(rev[0]) { let f = far(rev); out.append(ray(rev[0], rev[0].x - f.x, rev[0].y - f.y)) }
        return out
    }

    /// 边框上的点 -> 顺时针周长参数（从左上角开始）
    private func perimeterT(_ p: CGPoint) -> CGFloat {
        if p.y <= 0.5 { return p.x }
        if p.x >= W - 0.5 { return W + p.y }
        if p.y >= H - 0.5 { return W + H + (W - p.x) }
        return 2 * W + H + (H - p.y)
    }

    private func corners(from t0: CGFloat, to t1: CGFloat, clockwise: Bool) -> [CGPoint] {
        let P = 2 * (W + H)
        let cs: [(CGFloat, CGPoint)] = [(0, CGPoint(x: 0, y: 0)), (W, CGPoint(x: W, y: 0)),
                                        (W + H, CGPoint(x: W, y: H)), (2 * W + H, CGPoint(x: 0, y: H))]
        func mod(_ v: CGFloat) -> CGFloat { (v.truncatingRemainder(dividingBy: P) + P).truncatingRemainder(dividingBy: P) }
        let total = clockwise ? mod(t1 - t0) : mod(t0 - t1)
        return cs.compactMap { (t, pt) -> (CGFloat, CGPoint)? in
            let r = clockwise ? mod(t - t0) : mod(t0 - t)
            return r > 0 && r < total ? (r, pt) : nil
        }
        .sorted { $0.0 < $1.0 }
        .map { $0.1 }
    }

    private func polyArea(_ p: [CGPoint]) -> CGFloat {
        guard p.count > 2 else { return 0 }
        var a: CGFloat = 0
        for i in 0..<p.count { let q = p[(i + 1) % p.count]; a += p[i].x * q.y - q.x * p[i].y }
        return abs(a) / 2
    }

    /// 用分界线把屏幕切成两边
    private func splitSides(_ pts: [CGPoint]) -> [[CGPoint]]? {
        let full = extendLine(pts)
        guard full.count >= 2, onBorder(full.first!), onBorder(full.last!) else { return nil }
        let t0 = perimeterT(full.last!), t1 = perimeterT(full.first!)
        let a = full + corners(from: t0, to: t1, clockwise: true)
        let b = full + corners(from: t0, to: t1, clockwise: false)
        guard polyArea(a) > 100, polyArea(b) > 100 else { return nil }
        return [a, b]
    }

    /// 按重心位置给一边起名：右上方 · 29.9%
    private func sideLabel(_ p: [CGPoint]) -> String {
        var a: CGFloat = 0, cx: CGFloat = 0, cy: CGFloat = 0
        for i in 0..<p.count {
            let q = p[(i + 1) % p.count], cr = p[i].x * q.y - q.x * p[i].y
            a += cr; cx += (p[i].x + q.x) * cr; cy += (p[i].y + q.y) * cr
        }
        let c = abs(a) > 0.01 ? CGPoint(x: cx / (3 * a), y: cy / (3 * a)) : p[0]
        let dx = (c.x - W / 2) / W, dy = (c.y - H / 2) / H
        let en = Lang.isEnglish
        let h = dx < -0.03 ? (en ? "left" : "左") : dx > 0.03 ? (en ? "right" : "右") : ""
        let v = dy < -0.03 ? (en ? "top" : "上") : dy > 0.03 ? (en ? "bottom" : "下") : ""
        let name: String
        switch (h.isEmpty, v.isEmpty) {
        case (true, true): name = L("中间", "middle")
        case (false, true): name = en ? h + " side" : h + "侧"
        case (true, false): name = en ? v : v + "方"
        default: name = en ? "\(v)-\(h)" : h + v + "方"
        }
        return "\(name) · \(pct(Double(polyArea(p) / (W * H))))"
    }

    private func shapeIndex(at p: CGPoint) -> Int? {
        shapes.indices.last { shapes[$0].path(in: bounds).contains(p) }
    }

    // MARK: 事件

    override func mouseDown(with e: NSEvent) {
        refocus()
        if choosing {
            // 选边模式：点哪边就把哪边设为坏区
            let q = loc(e)
            if let i = sides.firstIndex(where: { CGPath.poly($0).contains(q) }) { choose(i) }
            return
        }
        let p = snap(loc(e))
        switch tool {
        case .rect:
            dragStart = p
        case .polygon, .line, .split:
            if e.clickCount >= 2 { finish(); return }
            pts.append(p)
        }
        sync()
    }

    override func mouseDragged(with e: NSEvent) {
        let p = snap(loc(e))
        cursor = loc(e)
        switch tool {
        case .rect:
            if let s = dragStart {
                dragRect = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
            }
        case .polygon, .line, .split:
            if choosing { break }
            // 按住拖动 = 自由描边
            if let last = pts.last, dist(last, p) > 6 { pts.append(p) }
        }
        sync()
    }

    override func mouseUp(with e: NSEvent) {
        if tool == .rect, let r = dragRect, r.width > 2, r.height > 2 {
            commit(.polygon([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                             CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map(rel)))
        }
        dragStart = nil; dragRect = nil
        sync()
    }

    override func rightMouseDown(with e: NSEvent) {
        if choosing { return }
        if !pts.isEmpty { finish(); return }
        // 没在画的时候，右键删除鼠标下的坏区
        if let i = shapeIndex(at: loc(e)) {
            undoStack.append(shapes)
            shapes.remove(at: i)
            sync()
        }
    }

    override func mouseMoved(with e: NSEvent) {
        cursor = loc(e)
        if choosing, let c = cursor, !toolbar.frame.contains(c) {
            let i = sides.firstIndex { CGPath.poly($0).contains(c) }
            if state.hoverSide != i { state.hoverSide = i }
        }
        needsDisplay = true
    }

    override func scrollWheel(with e: NSEvent) {
        guard tool == .line else { return }
        state.lineWidth = min(120, max(2, lineWidth + e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 0.2 : 2)))
        needsDisplay = true
    }

    override func keyDown(with e: NSEvent) {
        let chars = (e.charactersIgnoringModifiers ?? "").lowercased()
        let cmd = e.modifierFlags.contains(.command)
        switch e.keyCode {
        case 36, 76: if drawing { finish() } else { save() }; return        // 回车
        case 48: nextScreen(); return                                       // Tab
        case 53: cancel(); return                                           // Esc
        case 51, 117:                                                       // Delete
            if cmd { clearAll() } else if !pts.isEmpty { pts.removeLast(); sync() }
            return
        default: break
        }
        if cmd && chars == "z" { undo(); return }
        switch chars {
        case "1", "s": setTool(.split)
        case "2", "p": setTool(.polygon)
        case "3", "r": setTool(.rect)
        case "4", "l": setTool(.line)
        case "[": state.lineWidth = max(2, lineWidth - (lineWidth > 20 ? 4 : 1)); needsDisplay = true
        case "]": state.lineWidth = min(120, lineWidth + (lineWidth >= 20 ? 4 : 1)); needsDisplay = true
        case "h": toolbar.isHidden.toggle()
        default: super.keyDown(with: e)
        }
    }

    // MARK: 绘制

    override func draw(_ dirty: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        c.setFillColor(NSColor(white: 0, alpha: 0.25).cgColor)
        c.fill(bounds)

        let overToolbar = cursor.map { !toolbar.isHidden && toolbar.frame.contains($0) } ?? false
        // 工具栏下面不画任何东西
        if !toolbar.isHidden {
            c.addRect(bounds); c.addPath(CGPath(roundedRect: toolbar.frame, cornerWidth: 16, cornerHeight: 16, transform: nil))
            c.clip(using: .evenOdd)
        }

        // 已有坏区
        let hover = (drawing || overToolbar) ? nil : cursor.flatMap(shapeIndex(at:))
        for (i, s) in shapes.enumerated() {
            let p = s.path(in: bounds)
            c.addPath(p)
            c.setFillColor((i == hover ? NSColor.systemRed.withAlphaComponent(0.7) : NSColor.systemRed.withAlphaComponent(0.5)).cgColor)
            c.fillPath()
            c.addPath(p)
            c.setStrokeColor(i == hover ? NSColor.white.cgColor : NSColor.systemRed.cgColor)
            c.setLineWidth(i == hover ? 2.5 : 1.5)
            c.strokePath()
        }

        // 分割：选边预览
        if choosing {
            for (i, sd) in sides.enumerated() {
                let p = CGPath.poly(sd)
                let hot = state.hoverSide == i
                c.addPath(p)
                c.setFillColor((hot ? NSColor.systemRed.withAlphaComponent(0.6) : NSColor.white.withAlphaComponent(0.06)).cgColor)
                c.fillPath()
                // 在这一边的中间写上名字
                let r = p.boundingBoxOfPath
                let label = (hot ? L("设为坏区：", "Mark as dead: ") : "") + sideNames[i]
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .bold),
                                                            .foregroundColor: NSColor.white.withAlphaComponent(hot ? 1 : 0.7)]
                var at = CGPoint(x: r.midX, y: r.midY)
                if !p.contains(at) { at = sd.reduce(.zero) { CGPoint(x: $0.x + $1.x / CGFloat(sd.count), y: $0.y + $1.y / CGFloat(sd.count)) } }
                let sz = (label as NSString).size(withAttributes: attrs)
                (label as NSString).draw(at: CGPoint(x: at.x - sz.width / 2, y: at.y - sz.height / 2), withAttributes: attrs)
            }
            let l = CGMutablePath(); l.addLines(between: splitLine)
            c.addPath(l); c.setStrokeColor(NSColor.systemYellow.cgColor); c.setLineWidth(3); c.strokePath()
        }

        // 分割：画线时预览延伸部分
        if tool == .split, !choosing {
            var live = pts
            if let cur = cursor, !pts.isEmpty, !overToolbar { live.append(snap(cur)) }
            if live.count >= 2 {
                let full = extendLine(live)
                let ext = CGMutablePath(); ext.addLines(between: full)
                c.saveGState()
                c.addPath(ext); c.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
                c.setLineWidth(1.5); c.setLineDash(phase: 0, lengths: [6, 5]); c.strokePath()
                c.restoreGState()
                let l = CGMutablePath(); l.addLines(between: live)
                c.addPath(l); c.setStrokeColor(NSColor.systemYellow.cgColor); c.setLineWidth(3); c.strokePath()
            }
        }

        // 正在画的形状
        var live = pts
        if let cur = cursor, !pts.isEmpty, !overToolbar { live.append(snap(cur)) }
        let yellow = NSColor.systemYellow
        if tool == .polygon, live.count >= 2 {
            let p = CGMutablePath(); p.addLines(between: live); p.closeSubpath()
            c.addPath(p); c.setFillColor(yellow.withAlphaComponent(0.25).cgColor); c.fillPath()
            let l = CGMutablePath(); l.addLines(between: live)
            c.addPath(l); c.setStrokeColor(yellow.cgColor); c.setLineWidth(2); c.strokePath()
        }
        if tool == .line, live.count >= 2 {
            let s = Shape.stroke(live.map(rel), width: lineWidth / W).path(in: bounds)
            c.addPath(s); c.setFillColor(yellow.withAlphaComponent(0.45).cgColor); c.fillPath()
            let l = CGMutablePath(); l.addLines(between: live)
            c.addPath(l); c.setStrokeColor(yellow.cgColor); c.setLineWidth(1); c.strokePath()
        }
        for (i, p) in pts.enumerated() {
            let r: CGFloat = i == 0 ? 6 : 4
            c.setFillColor(yellow.cgColor)
            c.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }
        if let r = dragRect {
            c.setFillColor(yellow.withAlphaComponent(0.3).cgColor); c.fill(r)
            c.setStrokeColor(yellow.cgColor); c.setLineWidth(2); c.stroke(r)
        }

        guard let cur = cursor, !overToolbar else { return }

        // 线条工具的笔宽预览
        if tool == .line {
            let s = snap(cur)
            c.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor); c.setLineWidth(1)
            c.strokeEllipse(in: CGRect(x: s.x - lineWidth / 2, y: s.y - lineWidth / 2, width: lineWidth, height: lineWidth))
        }
        // 吸附提示：落点会吸到边上时画一个小方块
        let s = snap(cur)
        if s != cur && (s.x == 0 || s.y == 0 || s.x == W || s.y == H) {
            c.setStrokeColor(NSColor.systemYellow.cgColor); c.setLineWidth(2)
            c.stroke(CGRect(x: s.x - 6, y: s.y - 6, width: 12, height: 12))
        }
        // 贯穿全屏的十字线：鼠标进了黑区也能从可见部分看出它在哪
        c.setFillColor(NSColor.systemGreen.withAlphaComponent(0.9).cgColor)
        c.fill(CGRect(x: 0, y: cur.y - 0.5, width: W, height: 1))
        c.fill(CGRect(x: cur.x - 0.5, y: 0, width: 1, height: H))
    }
}

final class Editor {
    private var window: NSWindow?

    func open(screen: NSScreen, done: @escaping () -> Void) {
        window?.orderOut(nil)
        let f = screen.frame
        let w = KeyableWindow(contentRect: f, styleMask: .borderless, backing: .buffered, defer: false)
        w.setFrame(f, display: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.acceptsMouseMovedEvents = true

        let screens = NSScreen.screens
        let idx = screens.firstIndex(of: screen) ?? 0
        let v = EditorView(frame: NSRect(origin: .zero, size: f.size), shapes: Store.shapes(for: screen))
        v.state.screenLabel = screens.count > 1 ? "\(screen.localizedName)（\(idx + 1)/\(screens.count)）" : screen.localizedName
        v.state.multiScreen = screens.count > 1
        v.onFinish = { [weak self] s in
            if let s { Store.set(s, for: screen); History.add(screen: screen, shapes: s) }
            self?.window?.orderOut(nil)
            self?.window = nil
            done()
        }
        v.onNextScreen = { [weak self] s in
            Store.set(s, for: screen)
            History.add(screen: screen, shapes: s)
            let next = screens[(idx + 1) % screens.count]
            // 把鼠标带到下一块屏幕中央，方便直接开画
            let nf = toCG(next.frame)
            CGWarpMouseCursorPosition(CGPoint(x: nf.midX, y: nf.midY))
            self?.open(screen: next, done: done)
        }
        w.contentView = v
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(v)
    }
}

// MARK: - 菜单栏图标：屏幕轮廓 + 右上角被弧线切掉的实心死区（模板图，自动适配深浅色）

func makeStatusIcon() -> NSImage {
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        let screen = NSRect(x: 1.5, y: 4.5, width: 15, height: 10.5)
        let outline = NSBezierPath(roundedRect: screen, xRadius: 2, yRadius: 2)
        outline.lineWidth = 1.4
        NSColor.black.setStroke(); outline.stroke()
        // 右上死区
        let dead = NSBezierPath()
        dead.move(to: NSPoint(x: 8.5, y: screen.maxY))
        dead.curve(to: NSPoint(x: screen.maxX, y: 8.5),
                   controlPoint1: NSPoint(x: 10, y: 11), controlPoint2: NSPoint(x: 13, y: 9))
        dead.line(to: NSPoint(x: screen.maxX, y: screen.maxY)); dead.close()
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        NSColor.black.setFill(); dead.fill()
        NSGraphicsContext.restoreGraphicsState()
        // 支架
        NSBezierPath(roundedRect: NSRect(x: 6, y: 1.2, width: 6, height: 1.4), xRadius: 0.7, yRadius: 0.7).fill()
        NSRect(x: 8.3, y: 2.4, width: 1.4, height: 2.2).fill()
        return true
    }
    img.isTemplate = true
    img.accessibilityDescription = "DeadZone"
    return img
}

// MARK: - 段位（按损坏面积）

struct Tier {
    let min: Double, emoji: String, name: String, comment: String

    static var all: [Tier] { [
        Tier(min: 0.00, emoji: "🔍", name: L("坏点而已", "Just a Dead Pixel"), comment: L("这点坏，不仔细看都发现不了", "You can barely tell it's broken")),
        Tier(min: 0.05, emoji: "💧", name: L("洒洒水啦", "No Biggie"), comment: L("小场面，照用不误", "Small stuff, carry on")),
        Tier(min: 0.15, emoji: "🩹", name: L("小伤不下火线", "Just a Flesh Wound"), comment: L("轻伤不下火线，屏幕也一样", "A scratch won't take you off the front line")),
        Tier(min: 0.30, emoji: "💪", name: L("身残志坚", "Broken but Unbowed"), comment: L("残缺的屏幕，完整的生产力", "Incomplete screen, complete productivity")),
        Tier(min: 0.50, emoji: "🏯", name: L("半壁江山", "Half an Empire"), comment: L("坏了一半，还剩一半", "Half gone, half still yours")),
        Tier(min: 0.70, emoji: "🧮", name: L("勤俭持家小能手", "Master of Thrift"), comment: L("能用就不换，你是懂过日子的", "If it still works, why replace it?")),
        Tier(min: 0.90, emoji: "🪦", name: L("这就别用了吧", "Please, Just Replace It"), comment: L("求求了，换一块吧", "We're begging you. Get a new one.")),
    ] }

    static func of(_ damage: Double) -> Tier { all.last { damage >= $0.min } ?? all[0] }
}

// MARK: - 全球排名估算（仅供娱乐）
// 总体：屏幕坏了还在继续用的人。依据公开调查的粗略量级：
//  - 约 18% 的美国人正在用碎屏手机，碎屏后约 34% 选择继续用（YouGov）
//  - 约 20–30% 的显示器至少有一个坏点，ISO 13406-2 Class II 允许少量坏点
// 由此假设：坚持用坏屏的人里绝大多数只是坏点/小裂纹，大面积坏区极少。
// 下面的锚点是基于这些量级的主观估计，在 log(损坏面积) 上线性插值。

enum Ranking {
    /// (损坏面积, 超过的坏屏用户比例)
    static let anchors: [(Double, Double)] = [
        (0.0001, 0.40),   // 0.01%：几个坏点
        (0.001, 0.55),
        (0.01, 0.70),     // 1%：一道小裂纹
        (0.05, 0.85),
        (0.15, 0.93),
        (0.30, 0.97),
        (0.50, 0.990),
        (0.70, 0.997),
        (0.90, 0.9995),
        (1.00, 0.9999),
    ]

    /// 你的损坏程度超过了百分之多少的"坚持用坏屏"的人
    static func percentile(_ d: Double) -> Double {
        guard d > anchors[0].0 else { return d <= 0 ? 0 : anchors[0].1 * max(0, log10(d * 1e6)) / 2 }
        for i in 1..<anchors.count where d <= anchors[i].0 {
            let (x0, y0) = anchors[i - 1], (x1, y1) = anchors[i]
            let k = (log10(d) - log10(x0)) / (log10(x1) - log10(x0))
            return y0 + (y1 - y0) * k
        }
        return anchors.last!.1
    }

    static func beat(_ d: Double) -> String {
        let p = percentile(d)
        let v = p >= 0.999 ? String(format: "%.2f%%", p * 100) : String(format: "%.1f%%", p * 100)
        return L("超过全球约 \(v) 的坏屏坚持者", "More damaged than ~\(v) of broken-screen holdouts worldwide")
    }

    static func oneIn(_ d: Double) -> String? {
        let n = 1 / max(1 - percentile(d), 0.0001)
        return n >= 10 ? L("约 \(Int(n.rounded())) 人里才有 1 个比你更狠", "Only 1 in ~\(Int(n.rounded())) is more hardcore than you") : nil
    }

    static func text(_ d: Double) -> String { [beat(d), oneIn(d)].compactMap { $0 }.joined(separator: " · ") }
}

// MARK: - 成就

struct Metrics {
    var days = 0
    var maxDamage = 0.0
    var maxShapes = 0
    var hasLine = false
    var brokenScreens = 0
    var blocks = 0
    var moves = 0
}

struct Achievement: Identifiable {
    let id: String, emoji: String, title: String, desc: String
    let check: (Metrics) -> Bool

    static var all: [Achievement] { [
        Achievement(id: "d1", emoji: "🌱", title: L("初来乍到", "First Steps"), desc: L("第一次标记坏区", "Mark your first dead zone")) { $0.days >= 1 },
        Achievement(id: "d3", emoji: "🔧", title: L("将就着用", "Making Do"), desc: L("用坏屏幕 3 天", "Use a broken screen for 3 days")) { $0.days >= 3 },
        Achievement(id: "d7", emoji: "📅", title: L("坚持一周", "One Week Strong"), desc: L("用坏屏幕 7 天", "Use a broken screen for 7 days")) { $0.days >= 7 },
        Achievement(id: "d10", emoji: "🏅", title: L("你真是个人才", "What a Legend"), desc: L("用坏屏幕 10 天", "Use a broken screen for 10 days")) { $0.days >= 10 },
        Achievement(id: "d30", emoji: "🧱", title: L("一个月了还没换？", "A Month and Still No New One?"), desc: L("用坏屏幕 30 天", "Use a broken screen for 30 days")) { $0.days >= 30 },
        Achievement(id: "d100", emoji: "💯", title: L("百日筑基", "Hundred-Day Foundation"), desc: L("用坏屏幕 100 天", "Use a broken screen for 100 days")) { $0.days >= 100 },
        Achievement(id: "d365", emoji: "👑", title: L("年度钉子户", "Holdout of the Year"), desc: L("用坏屏幕 365 天", "Use a broken screen for 365 days")) { $0.days >= 365 },

        Achievement(id: "a5", emoji: "💧", title: L("洒洒水啦", "No Biggie"), desc: L("屏幕损坏面积达到 5%", "Damaged area reaches 5%")) { $0.maxDamage >= 0.05 },
        Achievement(id: "a30", emoji: "💪", title: L("身残志坚", "Broken but Unbowed"), desc: L("屏幕损坏面积达到 30%", "Damaged area reaches 30%")) { $0.maxDamage >= 0.30 },
        Achievement(id: "a50", emoji: "🏯", title: L("半壁江山", "Half an Empire"), desc: L("屏幕损坏面积达到 50%", "Damaged area reaches 50%")) { $0.maxDamage >= 0.50 },
        Achievement(id: "a70", emoji: "🧮", title: L("勤俭持家小能手", "Master of Thrift"), desc: L("屏幕损坏面积达到 70%", "Damaged area reaches 70%")) { $0.maxDamage >= 0.70 },
        Achievement(id: "a90", emoji: "🪦", title: L("这就别用了吧", "Please, Just Replace It"), desc: L("屏幕损坏面积达到 90%", "Damaged area reaches 90%")) { $0.maxDamage >= 0.90 },

        Achievement(id: "shapes5", emoji: "🧩", title: L("精雕细琢", "Meticulous"), desc: L("一块屏幕上标记 5 块以上坏区", "Mark 5+ dead zones on one screen")) { $0.maxShapes >= 5 },
        Achievement(id: "line", emoji: "📏", title: L("一线之隔", "A Fine Line"), desc: L("标记一条坏线", "Mark a dead line")) { $0.hasLine },
        Achievement(id: "multi", emoji: "🖥️", title: L("难兄难弟", "Brothers in Misfortune"), desc: L("两块以上屏幕都有坏区", "Dead zones on 2+ screens")) { $0.brokenScreens >= 2 },
        Achievement(id: "block100", emoji: "🚧", title: L("此路不通", "Dead End"), desc: L("鼠标撞墙 100 次", "Cursor hits the wall 100 times")) { $0.blocks >= 100 },
        Achievement(id: "block500", emoji: "🛡️", title: L("安全边界", "Safe Boundary"), desc: L("鼠标撞墙 500 次", "Cursor hits the wall 500 times")) { $0.blocks >= 500 },
        Achievement(id: "block1k", emoji: "⚔️", title: L("千次守护", "A Thousand Saves"), desc: L("鼠标撞墙 1000 次", "Cursor hits the wall 1,000 times")) { $0.blocks >= 1_000 },
        Achievement(id: "block2k", emoji: "🏰", title: L("铜墙铁壁", "Iron Wall"), desc: L("鼠标撞墙 2000 次", "Cursor hits the wall 2,000 times")) { $0.blocks >= 2_000 },
        Achievement(id: "block5k", emoji: "💎", title: L("固若金汤", "Unbreakable"), desc: L("鼠标撞墙 5000 次", "Cursor hits the wall 5,000 times")) { $0.blocks >= 5_000 },
        Achievement(id: "block10k", emoji: "🐂", title: L("撞了南墙也不回头", "Stubborn as a Mule"), desc: L("鼠标撞墙 10000 次", "Cursor hits the wall 10,000 times")) { $0.blocks >= 10_000 },
        Achievement(id: "move100", emoji: "📦", title: L("窗口搬运工", "Window Mover"), desc: L("窗口被推开 100 次", "Windows pushed away 100 times")) { $0.moves >= 100 },
    ] }
}

// MARK: - 统计（本地保存，不联网）

enum Stats {
    static var d: UserDefaults { .standard }

    static var days: [String] { d.stringArray(forKey: "statsDays") ?? [] }
    static var blocks: Int { d.integer(forKey: "statsBlocks") }
    static var moves: Int { d.integer(forKey: "statsMoves") }
    static var unlocked: [String: Double] { d.dictionary(forKey: "achievements") as? [String: Double] ?? [:] }

    static func markToday() {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        var list = days
        if !list.contains(today) { list.append(today); d.set(list, forKey: "statsDays") }
    }
    static func add(blocks n: Int) { if n > 0 { d.set(blocks + n, forKey: "statsBlocks") } }
    static func add(moves n: Int) { if n > 0 { d.set(moves + n, forKey: "statsMoves") } }

    static func metrics(_ zones: [DeadZone]) -> Metrics {
        Metrics(days: days.count, maxDamage: zones.map(\.damage).max() ?? 0,
                maxShapes: zones.map(\.shapeCount).max() ?? 0, hasLine: zones.contains { $0.hasLine },
                brokenScreens: zones.count, blocks: blocks, moves: moves)
    }

    /// 检查新解锁的成就，写入并返回
    static func unlockNew(_ m: Metrics) -> [Achievement] {
        var u = unlocked
        let fresh = Achievement.all.filter { u[$0.id] == nil && $0.check(m) }
        guard !fresh.isEmpty else { return [] }
        for a in fresh { u[a.id] = Date().timeIntervalSince1970 }
        d.set(u, forKey: "achievements")
        return fresh
    }
}

// MARK: - 成就解锁提示（避开坏区显示）

struct ToastView: View {
    let a: Achievement
    var body: some View {
        HStack(spacing: 14) {
            AchievementMedal(a: a, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("解锁成就", "Achievement Unlocked")).font(.caption).foregroundStyle(.secondary)
                Text(a.title).font(.title3.bold())
                Text(a.desc).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.yellow.opacity(0.6), lineWidth: 1.5))
    }
}

final class Toaster {
    private var queue: [Achievement] = []
    private var panel: NSPanel?
    var zones: () -> [DeadZone] = { [] }

    func show(_ list: [Achievement]) {
        queue += list
        if panel == nil { next() }
    }

    private func next() {
        guard !queue.isEmpty else { panel = nil; return }
        let a = queue.removeFirst()
        let host = NSHostingView(rootView: ToastView(a: a))
        let size = host.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.ignoresMouseEvents = true
        p.contentView = host
        p.setFrameOrigin(position(for: size))
        p.alphaValue = 0
        p.orderFrontRegardless()
        panel = p
        NSAnimationContext.runAnimationGroup { $0.duration = 0.3; p.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; p.animator().alphaValue = 0 }) {
                p.orderOut(nil)
                self?.next()
            }
        }
    }

    /// 鼠标所在屏幕的顶部中间 / 底部中间 / 正中，取第一个不压坏区的位置
    private func position(for size: NSSize) -> NSPoint {
        let m = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main!
        let v = screen.visibleFrame
        let spots = [NSPoint(x: v.midX - size.width / 2, y: v.maxY - size.height - 24),
                     NSPoint(x: v.midX - size.width / 2, y: v.minY + 24),
                     NSPoint(x: v.midX - size.width / 2, y: v.midY - size.height / 2),
                     NSPoint(x: v.minX + 24, y: v.minY + 24)]
        let dead = zones().flatMap(\.paths)
        return spots.first { o in
            let r = toCG(NSRect(origin: o, size: size))
            return !dead.contains { $0.boundingBoxOfPath.intersects(r) && pathIntersects($0, r) }
        } ?? spots[0]
    }

    private func pathIntersects(_ p: CGPath, _ r: CGRect) -> Bool {
        let rp = CGPath(rect: r, transform: nil)
        return !p.intersection(rp).isEmpty
    }
}

// MARK: - 成就与战绩窗口

struct ScreenReport: Identifiable {
    let id: String, name: String, damage: Double, shapes: Int
}

struct Report {
    var screens: [ScreenReport]
    var days: Int, blocks: Int, moves: Int
    var unlocked: [String: Double]

    static func current(_ zones: [DeadZone]) -> Report {
        Report(screens: zones.map { ScreenReport(id: $0.screen.uuid, name: $0.screen.localizedName,
                                                 damage: $0.damage, shapes: $0.shapeCount) },
               days: Stats.days.count, blocks: Stats.blocks, moves: Stats.moves, unlocked: Stats.unlocked)
    }
    var worst: ScreenReport? { screens.max { $0.damage < $1.damage } }
}

func pct(_ v: Double) -> String { String(format: v > 0 && v < 0.001 ? "%.2f%%" : "%.1f%%", v * 100) }

struct TierLadder: View {
    let damage: Double
    var body: some View {
        let cur = Tier.of(damage)
        HStack(spacing: 4) {
            ForEach(Tier.all, id: \.name) { t in
                VStack(spacing: 4) {
                    Text(t.emoji).font(.system(size: t.name == cur.name ? 22 : 15))
                        .opacity(t.min <= damage ? 1 : 0.3)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(t.name == cur.name ? Color.red : (t.min <= damage ? Color.red.opacity(0.4) : Color.secondary.opacity(0.2)))
                        .frame(height: 5)
                }
                .frame(maxWidth: .infinity)
                .help("\(t.name)（≥ \(Int(t.min * 100))%）")
            }
        }
    }
}

struct DamageCard: View {
    let s: ScreenReport
    var body: some View {
        let t = Tier.of(s.damage)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(s.name).font(.headline)
                Spacer()
                Text(L("\(s.shapes) 块坏区", "\(s.shapes) dead zone(s)")).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .center, spacing: 16) {
                Text(pct(s.damage)).font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(t.emoji) \(t.name)").font(.title3.bold())
                    Text(t.comment).font(.callout).foregroundStyle(.secondary)
                }
            }
            TierLadder(damage: s.damage)
            HStack(spacing: 6) {
                Image(systemName: "globe.asia.australia")
                Text(Ranking.text(s.damage))
            }
            .font(.callout).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct StatTile: View {
    let label: String, value: String
    var body: some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 解锁时间：中文 2026年9月25日 23:38:12，英文按系统格式
func unlockTime(_ d: Date) -> String {
    guard !Lang.isEnglish else { return d.formatted(date: .long, time: .standard) }
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = "yyyy年M月d日 HH:mm:ss"
    return f.string(from: d)
}

// MARK: - 圈选记录

struct HistoryRecord: Identifiable {
    let id: String
    let date: Date
    let uuid: String            // 屏幕 UUID
    let name: String
    let aspect: CGFloat
    let shapes: [Shape]
    let damage: Double

    var dict: [String: Any] {
        ["id": id, "t": date.timeIntervalSince1970, "uuid": uuid, "name": name, "aspect": Double(aspect),
         "shapes": shapes.map(\.dict), "damage": damage]
    }

    init(screen: NSScreen, shapes: [Shape]) {
        id = UUID().uuidString
        date = Date()
        uuid = screen.uuid
        name = screen.localizedName
        aspect = screen.frame.width / max(screen.frame.height, 1)
        self.shapes = shapes
        damage = damageOf(shapes, frame: toCG(screen.frame))
    }

    init?(dict d: [String: Any]) {
        guard let id = d["id"] as? String, let t = d["t"] as? Double, let uuid = d["uuid"] as? String,
              let list = d["shapes"] as? [[String: Any]] else { return nil }
        self.id = id
        date = Date(timeIntervalSince1970: t)
        self.uuid = uuid
        name = d["name"] as? String ?? L("未知屏幕", "Unknown screen")
        aspect = CGFloat(d["aspect"] as? Double ?? 16.0 / 9)
        shapes = list.compactMap(Shape.init(dict:))
        damage = d["damage"] as? Double ?? 0
    }
}

func sameShapes(_ a: [Shape], _ b: [Shape]) -> Bool { (a.map(\.dict) as NSArray).isEqual(to: b.map(\.dict)) }

func damageOf(_ shapes: [Shape], frame f: CGRect) -> Double {
    let area = rasterize(shapes.map { $0.path(in: f) }, frame: f).reduce(0) { $0 + $1.width * $1.height }
    return Double(area / (f.width * f.height))
}

enum History {
    static let key = "history"
    static var d: UserDefaults { .standard }

    static func all() -> [HistoryRecord] {
        (d.array(forKey: key) as? [[String: Any]] ?? []).compactMap(HistoryRecord.init(dict:))
    }

    /// 保存一条记录（与该屏幕最近一条相同则跳过），最多保留 100 条
    static func add(screen: NSScreen, shapes: [Shape]) {
        var list = all()
        if let last = list.first(where: { $0.uuid == screen.uuid }), sameShapes(last.shapes, shapes) { return }
        list.insert(HistoryRecord(screen: screen, shapes: shapes), at: 0)
        d.set(list.prefix(100).map(\.dict), forKey: key)
    }

    static func remove(_ id: String) {
        d.set(all().filter { $0.id != id }.map(\.dict), forKey: key)
    }
}

// MARK: - 主窗口数据

final class AppModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case screens, history, achievements, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .screens: return L("屏幕", "Screens")
            case .history: return L("圈选记录", "History")
            case .achievements: return L("成就与战绩", "Achievements")
            case .settings: return L("设置", "Settings")
            }
        }
        var icon: String {
            switch self {
            case .screens: return "display.2"
            case .history: return "clock.arrow.circlepath"
            case .achievements: return "trophy"
            case .settings: return "gearshape"
            }
        }
    }

    struct ScreenInfo: Identifiable {
        let id: String, name: String, size: CGSize, shapes: [Shape], damage: Double
        var aspect: CGFloat { size.width / max(size.height, 1) }
    }

    @Published var tab: Tab = .screens
    @Published var screens: [ScreenInfo] = []
    @Published var history: [HistoryRecord] = []
    @Published var report = Report(screens: [], days: 0, blocks: 0, moves: 0, unlocked: [:])
    @Published var axTrusted = false
    @Published var loginEnabled = false

    @Published var showOverlay = true { didSet { persist("showOverlay", showOverlay) } }
    @Published var avoidWindows = true { didSet { persist("avoidWindows", avoidWindows) } }
    @Published var windowsCrossThin = false { didSet { persist("windowsCrossThin", windowsCrossThin) } }
    @Published var blockMouse = true { didSet { persist("blockMouse", blockMouse) } }
    @Published var language = "system" {
        didSet {
            guard !loading else { return }
            Store.defaults.set(language, forKey: "language")
            onSettingsChanged()
        }
    }

    var onEdit: (String) -> Void = { _ in }
    var onClear: (String) -> Void = { _ in }
    var onApply: (HistoryRecord) -> Void = { _ in }
    var onSettingsChanged: () -> Void = {}
    var onToggleLogin: () -> Void = {}
    var onOpenAX: () -> Void = {}
    var onClearAll: () -> Void = {}

    private var loading = false
    private func persist(_ k: String, _ v: Bool) {
        guard !loading else { return }
        Store.defaults.set(v, forKey: k)
        onSettingsChanged()
    }

    func refresh(zones: [DeadZone]) {
        loading = true
        defer { loading = false }
        screens = NSScreen.screens.map { s in
            let shapes = Store.shapes(for: s)
            return ScreenInfo(id: s.uuid, name: s.localizedName, size: s.frame.size, shapes: shapes,
                              damage: zones.first { $0.screen.uuid == s.uuid }?.damage ?? 0)
        }
        history = History.all()
        report = Report.current(zones)
        axTrusted = AXIsProcessTrusted()
        loginEnabled = SMAppService.mainApp.status == .enabled
        showOverlay = Store.bool("showOverlay", default: true)
        avoidWindows = Store.bool("avoidWindows", default: true)
        windowsCrossThin = Store.bool("windowsCrossThin", default: false)
        blockMouse = Store.bool("blockMouse", default: true)
        language = Lang.setting
    }

    func currentShapes(for uuid: String) -> [Shape]? { screens.first { $0.id == uuid }?.shapes }
}

// MARK: - 主窗口界面

/// 屏幕缩略图：蓝色屏幕 + 黑色坏区
struct ShapePreview: View {
    let shapes: [Shape]
    let aspect: CGFloat
    var body: some View {
        Canvas { ctx, size in
            let r = CGRect(origin: .zero, size: size)
            ctx.fill(Path(r), with: .linearGradient(Gradient(colors: [Color(red: 0.2, green: 0.62, blue: 0.75),
                                                                       Color(red: 0.25, green: 0.4, blue: 0.85)]),
                                                    startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
            for s in shapes {
                let p = Path(s.path(in: r))
                ctx.fill(p, with: .color(.black))
                ctx.stroke(p, with: .color(.red.opacity(0.85)), lineWidth: 1)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .padding(5)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 7))
    }
}

struct AXBanner: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if !model.axTrusted {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("需要辅助功能权限", "Accessibility permission needed")).font(.headline)
                    Text(L("没有这个权限就无法移动窗口和拦截鼠标", "Without it, DeadZone can't move windows or block the cursor")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("去授权", "Grant Access")) { model.onOpenAX() }
            }
            .padding(12)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct ScreensView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AXBanner(model: model)
                ForEach(model.screens) { s in
                    HStack(alignment: .center, spacing: 18) {
                        ShapePreview(shapes: s.shapes, aspect: s.aspect).frame(width: 220)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(s.name).font(.title3.bold())
                            Text("\(Int(s.size.width)) × \(Int(s.size.height))").font(.caption).foregroundStyle(.secondary)
                            if s.shapes.isEmpty {
                                Text(L("还没有圈选坏区", "No dead zones marked")).foregroundStyle(.secondary)
                            } else {
                                let t = Tier.of(s.damage)
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(pct(s.damage)).font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                                    Text("\(t.emoji) \(t.name)").font(.headline)
                                }
                                Text(L("\(s.shapes.count) 块坏区", "\(s.shapes.count) dead zone(s)")).font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button(s.shapes.isEmpty ? L("圈选坏区", "Mark Dead Zones") : L("编辑坏区", "Edit Dead Zones")) { model.onEdit(s.id) }
                                    .buttonStyle(.borderedProminent)
                                if !s.shapes.isEmpty {
                                    Button(L("清除", "Clear")) { model.onClear(s.id) }
                                }
                            }
                            .padding(.top, 4)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                }
                Text(L("提示：编辑时按 Tab 可以保存并切换到下一块屏幕。每次保存都会自动存一条圈选记录。", "Tip: press Tab while editing to save and move to the next screen. Every save is recorded in History."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(22)
        }
    }
}

struct HistoryView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if model.history.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 40)).foregroundStyle(.secondary)
                Text(L("还没有圈选记录", "No history yet")).font(.headline)
                Text(L("每次在编辑界面保存，都会在这里留下一条记录，可以随时应用回去。", "Every time you save in the editor, a record appears here. You can apply it again any time."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.history) { r in row(r) }
                }
                .padding(22)
            }
        }
    }

    @ViewBuilder private func row(_ r: HistoryRecord) -> some View {
        let current = model.currentShapes(for: r.uuid)
        let connected = current != nil
        let isCurrent = current.map { sameShapes($0, r.shapes) } ?? false
        HStack(spacing: 16) {
            ShapePreview(shapes: r.shapes, aspect: r.aspect).frame(width: 130)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(r.date.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                    if isCurrent {
                        Text(L("当前", "Current")).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.green.opacity(0.2), in: Capsule())
                    }
                }
                Text(r.name + (connected ? "" : L("（未连接）", " (not connected)"))).font(.callout).foregroundStyle(.secondary)
                Text(r.shapes.isEmpty ? L("无坏区", "No dead zones") : L("\(r.shapes.count) 块坏区 · 损坏 \(pct(r.damage))", "\(r.shapes.count) dead zone(s) · \(pct(r.damage)) damaged") + " · \(Tier.of(r.damage).emoji) \(Tier.of(r.damage).name)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("应用", "Apply")) { model.onApply(r) }
                .disabled(!connected || isCurrent)
                .help(connected ? L("把这块屏幕的坏区恢复成这条记录", "Restore this screen's dead zones to this record") : L("这块屏幕现在没有连接", "This screen isn't connected"))
            Button(role: .destructive) { History.remove(r.id); model.history = History.all() } label: {
                Image(systemName: "trash")
            }
            .help(L("删除这条记录", "Delete this record"))
        }
        .padding(12)
        .background(isCurrent ? Color.green.opacity(0.06) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                AXBanner(model: model)
                if model.axTrusted {
                    Label(L("辅助功能权限已开启", "Accessibility permission granted"), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
            }
            Section(L("坏区", "Dead Zones")) {
                Toggle(isOn: $model.showOverlay) {
                    Text(L("黑色遮罩坏区", "Black out dead zones")); Text(L("用纯黑盖住坏区，减少花屏干扰", "Cover dead zones with solid black to hide flicker"))
                }
                Toggle(isOn: $model.avoidWindows) {
                    Text(L("自动把窗口移出坏区", "Move windows out of dead zones")); Text(L("窗口进入坏区后自动推开；最大化和全屏会避开坏区", "Windows are pushed out; maximize and full screen avoid dead zones"))
                }
                Toggle(isOn: $model.windowsCrossThin) {
                    Text(L("允许窗口跨过细线坏区", "Let windows cross thin dead lines")); Text(L("宽度不超过 40pt 的坏线不再阻挡窗口，避免屏幕被一分为二", "Lines up to 40pt wide no longer block windows, so the screen isn't split in two"))
                }
                .disabled(!model.avoidWindows)
                Toggle(isOn: $model.blockMouse) {
                    Text(L("阻止鼠标进入坏区", "Keep the cursor out of dead zones")); Text(L("大块坏区贴边滑动，细线直接跳过", "Slides along large areas, jumps over thin lines"))
                }
            }
            Section(L("通用", "General")) {
                Picker(L("语言", "Language"), selection: $model.language) {
                    Text(L("跟随系统", "System")).tag("system")
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                }
                Toggle(L("开机自动启动", "Launch at login"), isOn: Binding(get: { model.loginEnabled }, set: { _ in model.onToggleLogin() }))
                Button(L("清除全部坏区…", "Clear All Dead Zones…"), role: .destructive) { confirmClear = true }
            }
            Section(L("关于", "About")) {
                LabeledContent(L("版本", "Version"), value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")
                Link("GitHub：prefect12/DeadZone", destination: URL(string: "https://github.com/prefect12/DeadZone")!)
                Text(L("所有数据只保存在本机，不联网。", "All data stays on this Mac. Nothing goes online.")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(L("清除所有屏幕上的坏区？", "Clear dead zones on all screens?"), isPresented: $confirmClear) {
            Button(L("清除", "Clear"), role: .destructive) { model.onClearAll() }
        } message: {
            Text(L("圈选记录会保留，之后可以从记录里恢复。", "History is kept, so you can restore from it later."))
        }
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        NavigationSplitView {
            List(AppModel.Tab.allCases, selection: Binding(get: { model.tab }, set: { if let t = $0 { model.tab = t } })) { t in
                Label(t.title, systemImage: t.icon).tag(t)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            Group {
                switch model.tab {
                case .screens: ScreensView(model: model)
                case .history: HistoryView(model: model)
                case .achievements: StatsView(report: model.report)
                case .settings: SettingsView(model: model)
                }
            }
            .navigationTitle(model.tab.title)
        }
        .frame(minWidth: model.tab == .achievements ? 1120 : 780, minHeight: 560)
    }
}

final class MainWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "DeadZone"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: MainView(model: model))
            w.delegate = self
            w.center()
            window = w
        }
        // 主窗口打开时在程序坞显示图标，关掉后回到纯菜单栏
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func hide() { window?.orderOut(nil) }
    var frameCG: CGRect? { window.map { toCG($0.frame) } }
    func setFrameCG(_ r: CGRect) { window?.setFrame(toNS(r), display: true, animate: true) }
    var isVisible: Bool { window?.isVisible ?? false }

    func windowWillClose(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let overlays = OverlayManager()
    private let avoider = WindowAvoider()
    private let mouse = MouseGuard()
    private let editor = Editor()
    private let toaster = Toaster()
    private let model = AppModel()
    private let mainWindow = MainWindow()
    private var ticks = 0
    private var timer: Timer?
    private var editing = false
    private var zones: [DeadZone] = []

    private var showOverlay: Bool { Store.bool("showOverlay", default: true) }
    private var avoidWindows: Bool { Store.bool("avoidWindows", default: true) }
    private var blockMouse: Bool { Store.bool("blockMouse", default: true) }
    private var windowsCrossThin: Bool { Store.bool("windowsCrossThin", default: false) }

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = makeStatusIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        NotificationCenter.default.addObserver(self, selector: #selector(reload),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(reload),
                                               name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        if !AXIsProcessTrusted() { requestAccessibility() }

        mouse.onMouseUp = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self?.tickWindows() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let trusted = AXIsProcessTrusted()
            if Store.defaults.object(forKey: "axTrusted") as? Bool != trusted { Store.defaults.set(trusted, forKey: "axTrusted") }
            // 刚授权时 tap 还没建起来，补建
            if trusted && !self.mouse.running && self.blockMouse && !self.editing && !self.zones.isEmpty { self.mouse.start() }
            self.tickWindows()
            self.ticks += 1
            if self.ticks % 20 == 0 { self.updateStats() }       // 每 5 秒
        }
        toaster.zones = { [weak self] in self?.zones ?? [] }
        model.onEdit = { [weak self] uuid in
            if let s = NSScreen.screens.first(where: { $0.uuid == uuid }) { self?.startEditing(s) }
        }
        model.onClear = { [weak self] uuid in
            guard let s = NSScreen.screens.first(where: { $0.uuid == uuid }) else { return }
            Store.set([], for: s); History.add(screen: s, shapes: []); self?.reload()
        }
        model.onApply = { [weak self] r in
            guard let s = NSScreen.screens.first(where: { $0.uuid == r.uuid }) else { return }
            Store.set(r.shapes, for: s); self?.reload(); self?.updateStats()
        }
        model.onSettingsChanged = { [weak self] in self?.reload() }
        model.onToggleLogin = { [weak self] in self?.toggleLogin() }
        model.onOpenAX = { [weak self] in self?.openAXSettings() }
        model.onClearAll = { [weak self] in self?.clearAll() }

        // 已有坏区存成第一条圈选记录（与最近一条相同时会自动跳过）
        for scr in NSScreen.screens where !Store.shapes(for: scr).isEmpty { History.add(screen: scr, shapes: Store.shapes(for: scr)) }
        reload()
        showMain(zones.isEmpty ? .screens : nil)
    }

    /// 打开主窗口（可指定页面）
    private func showMain(_ tab: AppModel.Tab?) {
        if let tab { model.tab = tab }
        model.refresh(zones: zones)
        mainWindow.show(model: model)
        // 自己的窗口也要避开坏区
        if let w = mainWindow.frameCG, let z = zones.first(where: { $0.screenFrame.intersects(w) }),
           z.rects.contains(where: { overlaps($0, w) }),
           let target = avoider.plan(w, dead: z.rects, screen: z.visibleFrame) ?? avoider.maxRect(dead: z.rects, screen: z.visibleFrame) {
            mainWindow.setFrameCG(target)
        }
    }

    /// 再次打开 App（例如在访达里双击）时进入编辑，防止菜单栏图标被刘海挤掉后无从下手
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !editing { showMain(nil) }
        return false
    }

    /// 汇总统计、检查成就
    private func updateStats() {
        Stats.add(blocks: mouse.takeBlocks())
        Stats.add(moves: avoider.moves); avoider.moves = 0
        guard !zones.isEmpty, !editing else { return }
        Stats.markToday()
        toaster.show(Stats.unlockNew(Stats.metrics(zones)))
        if mainWindow.isVisible { model.refresh(zones: zones) }
    }

    private func tickWindows() {
        guard !editing, avoidWindows else { return }
        avoider.tick(zones: zones)
    }

    @objc func reload() {
        zones = Store.zones(windowsCrossThin: windowsCrossThin)
        overlays.rebuild(zones: zones, visible: showOverlay && !editing)
        mouse.update(zones: zones, screens: NSScreen.screens.map { toCG($0.frame) })
        if blockMouse && !editing && !zones.isEmpty { mouse.start() } else { mouse.stop() }
        statusItem.button?.appearsDisabled = zones.isEmpty
        model.refresh(zones: zones)
    }

    private func startEditing(_ s: NSScreen) {
        editing = true
        reload()
        editor.open(screen: s) { [weak self] in
            self?.editing = false
            self?.reload()
            self?.updateStats()
        }
    }

    private func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item(L("打开 DeadZone…", "Open DeadZone…"), #selector(openMain), key: ","))
        menu.addItem(.separator())

        let names = zones.map { "\($0.screen.localizedName) (\(Store.shapes(for: $0.screen).count))" }
        menu.addItem(disabled(names.isEmpty ? L("还没有设置坏区", "No dead zones yet") : L("已屏蔽：", "Blocked: ") + names.joined(separator: ", ")))
        if !AXIsProcessTrusted() {
            menu.addItem(item(L("⚠️ 需要辅助功能权限（点此授权）", "⚠️ Accessibility permission needed (click to grant)"), #selector(openAXSettings)))
        }
        menu.addItem(.separator())

        let editItem = NSMenuItem(title: L("编辑坏区…", "Edit Dead Zones…"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (i, s) in NSScreen.screens.enumerated() {
            let it = item(s.title + (Store.shapes(for: s).isEmpty ? "" : "  ●"), #selector(editScreen(_:)))
            it.tag = i
            sub.addItem(it)
        }
        editItem.submenu = sub
        menu.addItem(editItem)
        menu.addItem(item(L("清除全部坏区", "Clear All Dead Zones"), #selector(clearAll)))
        menu.addItem(.separator())
        let worst = zones.map(\.damage).max()
        let head = worst.map { L("成就与战绩…", "Achievements…") + "  \(Tier.of($0).emoji) \(pct($0))" } ?? L("成就与战绩…", "Achievements…")
        menu.addItem(item(head, #selector(showStats)))
        menu.addItem(.separator())

        menu.addItem(toggle(L("黑色遮罩坏区", "Black Out Dead Zones"), "showOverlay", showOverlay))
        menu.addItem(toggle(L("自动把窗口移出坏区", "Move Windows Out of Dead Zones"), "avoidWindows", avoidWindows))
        menu.addItem(toggle(L("允许窗口跨过细线坏区（≤40pt）", "Let Windows Cross Thin Lines (≤40pt)"), "windowsCrossThin", windowsCrossThin))
        menu.addItem(toggle(L("阻止鼠标进入坏区", "Keep Cursor Out of Dead Zones"), "blockMouse", blockMouse))
        let langItem = NSMenuItem(title: L("语言", "Language"), action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        for (code, title) in [("system", L("跟随系统", "System")), ("zh", "中文"), ("en", "English")] {
            let it = item(title, #selector(setLanguage(_:)))
            it.representedObject = code
            it.state = Lang.setting == code ? .on : .off
            langMenu.addItem(it)
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)
        let login = item(L("开机自动启动", "Launch at Login"), #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item(L("退出", "Quit"), #selector(quit), key: "q"))
    }

    private func item(_ t: String, _ a: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: t, action: a, keyEquivalent: key); i.target = self; return i
    }
    private func disabled(_ t: String) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false; return i
    }
    private func toggle(_ t: String, _ key: String, _ on: Bool) -> NSMenuItem {
        let i = item(t, #selector(toggleSetting(_:))); i.representedObject = key; i.state = on ? .on : .off; return i
    }

    @objc func editScreen(_ sender: NSMenuItem) {
        guard NSScreen.screens.indices.contains(sender.tag) else { return }
        startEditing(NSScreen.screens[sender.tag])
    }
    @objc func showStats() {
        updateStats()
        showMain(.achievements)
    }
    @objc func openMain() { showMain(nil) }
    @objc func clearAll() { Store.clearAll(); reload() }
    @objc func toggleSetting(_ sender: NSMenuItem) {
        guard let k = sender.representedObject as? String else { return }
        Store.defaults.set(sender.state != .on, forKey: k)
        reload()
    }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert(); a.messageText = L("设置开机启动失败", "Couldn't change launch at login"); a.informativeText = error.localizedDescription; a.runModal()
        }
    }
    @objc func openAXSettings() {
        requestAccessibility()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func setLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        Store.defaults.set(code, forKey: "language")
        reload()
    }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
