// DeadZone — 把显示器上坏掉的（不规则）区域"挖掉"，让窗口和鼠标都不进入那里。
// 菜单栏常驻应用。坐标约定：内部统一使用 CG 全局坐标（原点在主屏左上角，y 向下）。
// 坏区用一张网格蒙版表示（每格约 4pt），可以是任意形状。

import Cocoa
import ApplicationServices
import ServiceManagement

// MARK: - 坐标工具

func primaryHeight() -> CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
func toCG(_ r: NSRect) -> CGRect { CGRect(x: r.minX, y: primaryHeight() - r.maxY, width: r.width, height: r.height) }
func toNS(_ r: CGRect) -> NSRect { NSRect(x: r.minX, y: primaryHeight() - r.maxY, width: r.width, height: r.height) }

/// 两个矩形是否有实质重叠（忽略 1pt 以内的贴边）
func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
    let i = a.intersection(b)
    return !i.isNull && i.width > 1 && i.height > 1
}

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

// MARK: - 网格蒙版

struct Mask {
    static let cell: CGFloat = 4
    let cols: Int, rows: Int
    var bits: [UInt8]           // 行优先，第 0 行在顶部；1 = 坏

    init(cols: Int, rows: Int, bits: [UInt8]? = nil) {
        self.cols = cols; self.rows = rows
        self.bits = bits ?? [UInt8](repeating: 0, count: cols * rows)
    }
    init(size: CGSize) {
        self.init(cols: Int((size.width / Mask.cell).rounded(.up)), rows: Int((size.height / Mask.cell).rounded(.up)))
    }

    var isEmpty: Bool { !bits.contains(1) }

    subscript(c: Int, r: Int) -> Bool {
        get { c >= 0 && r >= 0 && c < cols && r < rows && bits[r * cols + c] == 1 }
        set { if c >= 0 && r >= 0 && c < cols && r < rows { bits[r * cols + c] = newValue ? 1 : 0 } }
    }

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

// MARK: - 配置存储（按显示器 UUID 存，网格按比例映射，分辨率变化后仍有效）

struct DeadZone {
    let screen: NSScreen
    let rects: [CGRect]     // CG 全局坐标（网格合并出的矩形，用于窗口避让）
    let bounds: CGRect
    let line: [CGPoint]     // 平滑的分界线（从顶边到右边），用于鼠标贴边滑动
    let shape: CGPath       // 死区多边形
    let screenFrame: CGRect // CG 坐标，供后台线程使用（NSScreen 不宜跨线程访问）
    var visibleFrame: CGRect { toCG(screen.visibleFrame) }
}

/// Douglas-Peucker 折线简化
func simplify(_ pts: [CGPoint], _ eps: CGFloat) -> [CGPoint] {
    guard pts.count > 2 else { return pts }
    let a = pts.first!, b = pts.last!
    let dx = b.x - a.x, dy = b.y - a.y, len = max(hypot(dx, dy), 0.0001)
    var maxD: CGFloat = 0, idx = 0
    for i in 1..<(pts.count - 1) {
        let d = abs(dy * pts[i].x - dx * pts[i].y + b.x * a.y - b.y * a.x) / len
        if d > maxD { maxD = d; idx = i }
    }
    if maxD <= eps { return [a, b] }
    return Array(simplify(Array(pts[...idx]), eps).dropLast()) + simplify(Array(pts[idx...]), eps)
}

/// 从蒙版推出"右上方死区"的平滑分界线：每一行死区最左侧的位置连成线
func boundaryLine(_ m: Mask, frame f: CGRect) -> [CGPoint] {
    let cw = f.width / CGFloat(m.cols), ch = f.height / CGFloat(m.rows)
    var pts: [CGPoint] = []
    var lastRow = -1
    for r in 0..<m.rows {
        guard let c = (0..<m.cols).first(where: { m[$0, r] }) else { continue }
        let x = f.minX + CGFloat(c) * cw
        if pts.isEmpty { pts.append(CGPoint(x: x, y: f.minY)) }
        pts.append(CGPoint(x: x, y: f.minY + (CGFloat(r) + 0.5) * ch))
        lastRow = r
    }
    guard lastRow >= 0 else { return [] }
    pts.append(CGPoint(x: f.maxX, y: f.minY + CGFloat(lastRow + 1) * ch))
    return simplify(pts, 2.5)
}

enum Store {
    static let key = "deadMasks"
    static var defaults: UserDefaults { .standard }

    static func mask(for s: NSScreen) -> Mask? {
        guard let all = defaults.dictionary(forKey: key),
              let d = all[s.uuid] as? [String: Any],
              let cols = d["cols"] as? Int, let rows = d["rows"] as? Int,
              let data = d["bits"] as? Data, data.count == cols * rows else { return nil }
        return Mask(cols: cols, rows: rows, bits: [UInt8](data))
    }

    static func set(_ m: Mask?, for s: NSScreen) {
        var all = defaults.dictionary(forKey: key) ?? [:]
        if let m, !m.isEmpty {
            all[s.uuid] = ["cols": m.cols, "rows": m.rows, "bits": Data(m.bits)]
        } else {
            all[s.uuid] = nil
        }
        defaults.set(all, forKey: key)
    }

    static func clearAll() { defaults.removeObject(forKey: key) }

    static func zones() -> [DeadZone] {
        NSScreen.screens.compactMap { s -> DeadZone? in
            guard let m = mask(for: s), !m.isEmpty else { return nil }
            let f = toCG(s.frame)
            let cw = f.width / CGFloat(m.cols), ch = f.height / CGFloat(m.rows)
            let rects = m.gridRects().map {
                CGRect(x: f.minX + CGFloat($0.c0) * cw, y: f.minY + CGFloat($0.r0) * ch,
                       width: CGFloat($0.c1 - $0.c0) * cw, height: CGFloat($0.r1 - $0.r0) * ch)
            }
            let line = boundaryLine(m, frame: f)
            let shape = CGMutablePath()
            shape.addLines(between: line + [CGPoint(x: f.maxX, y: f.minY)])
            shape.closeSubpath()
            return DeadZone(screen: s, rects: rects, bounds: rects.reduce(CGRect.null) { $0.union($1) },
                            line: line, shape: shape, screenFrame: f)
        }
    }

    static func bool(_ k: String, default d: Bool) -> Bool {
        defaults.object(forKey: k) == nil ? d : defaults.bool(forKey: k)
    }
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
    var rects: [NSRect] = []
    override func draw(_ dirty: NSRect) {
        NSGraphicsContext.current?.shouldAntialias = false
        NSColor.black.setFill()
        rects.forEach { $0.fill() }
    }
}

final class OverlayManager {
    private var windows: [NSWindow] = []

    func rebuild(zones: [DeadZone], visible: Bool) {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        guard visible else { return }
        for z in zones {
            let frame = toNS(z.bounds)
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
            v.rects = z.rects.map { r in
                let n = toNS(r)
                return NSRect(x: n.minX - frame.minX, y: n.minY - frame.minY, width: n.width, height: n.height)
            }
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
    /// 刚被我们退出全屏的窗口，等动画结束后放到"最大可用矩形"
    private var pendingMax: [(win: AXUIElement, since: Date)] = []

    func tick(zones: [DeadZone]) {
        guard !zones.isEmpty, AXIsProcessTrusted() else { return }
        // 用户正在拖动时不抢，松手后再处理
        if NSEvent.pressedMouseButtons != 0 { return }

        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return }
        let me = getpid()
        var pids = Set<pid_t>()
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b) else { continue }
            if hit(r, zones) != nil { pids.insert(pid) }
        }
        for pid in pids { fix(pid: pid, zones: zones) }
        finishPending(zones: zones)
    }

    private func finishPending(zones: [DeadZone]) {
        let all = zones.flatMap { $0.rects }
        pendingMax = pendingMax.filter { item in
            if Date().timeIntervalSince(item.since) > 5 { return false }
            guard !boolAttr(item.win, "AXFullScreen"), let frame = frameOf(item.win),
                  let z = zones.first(where: { $0.screen.frame.intersects(toNS(frame)) }),
                  let target = maxRect(dead: all, screen: z.visibleFrame) else { return true }
            setFrame(item.win, target)
            // 动画可能还没完全结束，位置没到就下个 tick 再来
            guard let after = frameOf(item.win) else { return false }
            return abs(after.minX - target.minX) > 2 || abs(after.minY - target.minY) > 2
        }
    }

    /// 屏幕可用区域里避开所有死区后面积最大的矩形——相当于这块"异形屏"上的最大化
    func maxRect(dead: [CGRect], screen S: CGRect) -> CGRect? {
        let ds = dead.filter { overlaps($0, S) }
        let tops = Set([S.minY] + ds.map { $0.maxY }.filter { $0 > S.minY && $0 < S.maxY })
        let bottoms = Set([S.maxY] + ds.map { $0.minY }.filter { $0 > S.minY && $0 < S.maxY })
        var best: CGRect?
        func consider(_ top: CGFloat, _ bottom: CGFloat) {
            guard bottom - top >= minH else { return }
            let blocked = ds.filter { $0.minY < bottom - 1 && $0.maxY > top + 1 }.map { ($0.minX, $0.maxX) }
            for (a, b) in free(S.minX, S.maxX, blocked) where b - a >= minW {
                let r = CGRect(x: a, y: top, width: b - a, height: bottom - top)
                if best == nil || r.width * r.height > best!.width * best!.height { best = r }
            }
        }
        for t in tops { consider(t, S.maxY) }
        for b in bottoms { consider(S.minY, b) }
        return best
    }

    private func hit(_ w: CGRect, _ zones: [DeadZone]) -> DeadZone? {
        zones.first { overlaps($0.bounds, w) && $0.rects.contains { overlaps($0, w) } }
    }

    private func fix(pid: pid_t, zones: [DeadZone]) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)   // 卡死的应用最多等 0.3s
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let wins = value as? [AXUIElement] else { return }

        let all = zones.flatMap { $0.rects }
        for win in wins {
            if boolAttr(win, kAXMinimizedAttribute) { continue }
            guard let frame = frameOf(win), let z = hit(frame, zones) else { continue }

            // 系统全屏：退出全屏，改成"顶着死区的最大化"
            if boolAttr(win, "AXFullScreen") {
                if !pendingMax.contains(where: { CFEqual($0.win, win) }) {
                    AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, kCFBooleanFalse)
                    pendingMax.append((win, Date()))
                }
                continue
            }
            if pendingMax.contains(where: { CFEqual($0.win, win) }) { continue }

            // 最大化 / 铺满（双击标题栏、⌥+绿色按钮等）：放到最大可用矩形
            let S = z.visibleFrame
            if frame.width >= S.width * 0.95 && frame.height >= S.height * 0.9,
               let target = maxRect(dead: all, screen: S) {
                setFrame(win, target)
                continue
            }

            let key = CFHash(win)
            if let (last, n) = attempts[key], last == frame, n >= 3 { continue }   // 放弃这个倔强的窗口

            guard let target = plan(frame, dead: all, screen: z.visibleFrame) else { continue }
            setFrame(win, target)
            let after = frameOf(win) ?? target
            let n = (attempts[key]?.0 == frame ? attempts[key]!.1 : 0) + 1
            attempts[key] = (after, n)
        }
        if attempts.count > 500 { attempts.removeAll() }
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
    func plan(_ w: CGRect, dead: [CGRect], screen S: CGRect) -> CGRect? {
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
            .filter { c in c.width >= minW && c.height >= minH && !dead.contains { overlaps($0, c) } }
            .min { cost($0) < cost($1) }
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

// MARK: - 鼠标拦截（CGEventTap：在事件送达前修正位置，贴着分界线滑动）
// tap 跑在独立线程上：主线程做窗口操作时即使被某个应用卡住，也不会拖慢鼠标。

final class MouseGuard {
    private let lock = NSLock()
    private var _zones: [DeadZone] = []
    var zones: [DeadZone] {
        get { lock.lock(); defer { lock.unlock() }; return _zones }
        set { lock.lock(); _zones = newValue; lock.unlock() }
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
        let p = e.location
        guard let z = zones.first(where: { $0.bounds.contains(p) && $0.shape.contains(p) }),
              let q = escape(p, z) else { return }
        e.location = q
        CGWarpMouseCursorPosition(q)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// 分界线上离 p 最近的点，再往死区外侧推一点点
    private func escape(_ p: CGPoint, _ z: DeadZone) -> CGPoint? {
        let L = z.line
        guard L.count >= 2 else { return nil }
        var best = L[0], bestD = CGFloat.greatestFiniteMagnitude
        for i in 0..<(L.count - 1) {
            let a = L[i], b = L[i + 1]
            let dx = b.x - a.x, dy = b.y - a.y, l2 = dx * dx + dy * dy
            let t = l2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
            let q = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
            let d = hypot(q.x - p.x, q.y - p.y)
            if d < bestD { bestD = d; best = q }
        }
        // 外侧方向：从 p 指向最近点；若重合则用左下方
        var dir = CGVector(dx: best.x - p.x, dy: best.y - p.y)
        let n = hypot(dir.dx, dir.dy)
        dir = n > 0.01 ? CGVector(dx: dir.dx / n, dy: dir.dy / n) : CGVector(dx: -0.7071, dy: 0.7071)
        let f = z.screenFrame
        for push: CGFloat in [0.5, 1, 2, 4, 8, 16] {
            var q = CGPoint(x: best.x + dir.dx * push, y: best.y + dir.dy * push)
            q.x = min(max(q.x, f.minX), f.maxX - 1)
            q.y = min(max(q.y, f.minY), f.maxY - 1)
            if !z.shape.contains(q) { return q }
        }
        return nil
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

// MARK: - 坏区编辑器：画一条分界线，线的右上方全部是死区
// 坏区里看不见鼠标，所以只需在看得见的一侧沿边界画线（点击或拖动均可）。
// 线的两端会自动沿延长方向延伸到屏幕边缘，再沿屏幕边框绕过右上角闭合。

final class EditorView: NSView {
    var mask: Mask
    var onFinish: ((Mask?) -> Void)?

    private var line: [NSPoint] = []
    private var cursor: NSPoint?
    private var dragging = false

    init(frame: NSRect, mask: Mask) {
        self.mask = mask
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    private var W: CGFloat { bounds.width }
    private var H: CGFloat { bounds.height }

    // MARK: 几何

    private func clamp(_ p: NSPoint) -> NSPoint {
        var q = NSPoint(x: min(max(p.x, 0), W), y: min(max(p.y, 0), H))
        let s: CGFloat = 20     // 离边缘很近就吸附
        if q.x < s { q.x = 0 }
        if q.y < s { q.y = 0 }
        if W - q.x < s { q.x = W }
        if H - q.y < s { q.y = H }
        return q
    }

    private func onBorder(_ p: NSPoint) -> Bool { p.x <= 0 || p.y <= 0 || p.x >= W || p.y >= H }

    /// 从 p 沿方向 d 射到屏幕边框的交点
    private func ray(_ p: NSPoint, _ d: CGVector) -> NSPoint {
        var t = CGFloat.greatestFiniteMagnitude
        if d.dx > 0 { t = min(t, (W - p.x) / d.dx) } else if d.dx < 0 { t = min(t, -p.x / d.dx) }
        if d.dy > 0 { t = min(t, (H - p.y) / d.dy) } else if d.dy < 0 { t = min(t, -p.y / d.dy) }
        if t == .greatestFiniteMagnitude { return p }
        return clamp(NSPoint(x: p.x + d.dx * t, y: p.y + d.dy * t))
    }

    /// 两端延伸到屏幕边缘后的完整分界线
    private func extended(_ pts: [NSPoint]) -> [NSPoint] {
        guard pts.count >= 2 else { return pts }
        var out = pts
        // 用离端点稍远的点定方向，避免手抖
        func dir(_ from: NSPoint, _ to: NSPoint) -> CGVector { CGVector(dx: to.x - from.x, dy: to.y - from.y) }
        func farPoint(_ seq: [NSPoint]) -> NSPoint {
            let e = seq[0]
            return seq.dropFirst().first { hypot($0.x - e.x, $0.y - e.y) > 40 } ?? seq[1]
        }
        if !onBorder(out[0]) { out.insert(ray(out[0], dir(farPoint(pts), pts[0])), at: 0) }
        let rev = Array(pts.reversed())
        if !onBorder(out.last!) { out.append(ray(rev[0], dir(farPoint(rev), rev[0]))) }
        return out
    }

    /// 边框上的点 -> 顺时针周长参数（从左上角开始）
    private func perimeterT(_ p: NSPoint) -> CGFloat {
        if p.y >= H { return p.x }
        if p.x >= W { return W + (H - p.y) }
        if p.y <= 0 { return W + H + (W - p.x) }
        return 2 * W + H + p.y
    }

    private func corners(from t0: CGFloat, to t1: CGFloat, clockwise: Bool) -> [NSPoint] {
        let P = 2 * (W + H)
        let cs: [(CGFloat, NSPoint)] = [(W, NSPoint(x: W, y: H)), (W + H, NSPoint(x: W, y: 0)),
                                        (2 * W + H, NSPoint(x: 0, y: 0)), (0, NSPoint(x: 0, y: H))]
        func mod(_ v: CGFloat) -> CGFloat { (v.truncatingRemainder(dividingBy: P) + P).truncatingRemainder(dividingBy: P) }
        let total = clockwise ? mod(t1 - t0) : mod(t0 - t1)
        return cs.compactMap { (t, pt) -> (CGFloat, NSPoint)? in
            let rel = clockwise ? mod(t - t0) : mod(t0 - t)
            return rel > 0 && rel < total ? (rel, pt) : nil
        }
        .sorted { $0.0 < $1.0 }
        .map { $0.1 }
    }

    private func path(_ pts: [NSPoint]) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: pts[0]); pts.dropFirst().forEach(p.line); p.close()
        return p
    }

    /// 分界线右上方的死区多边形
    private func deadPolygon(_ pts: [NSPoint]) -> [NSPoint]? {
        let full = extended(pts)
        guard full.count >= 2 else { return nil }
        let t0 = perimeterT(full.last!), t1 = perimeterT(full.first!)
        let a = full + corners(from: t0, to: t1, clockwise: true)
        let b = full + corners(from: t0, to: t1, clockwise: false)
        // 选包含右上角的那一侧
        let probe = NSPoint(x: W - 2, y: H - 2)
        let inA = a.count > 2 && path(a).contains(probe), inB = b.count > 2 && path(b).contains(probe)
        if inA != inB { return inA ? a : b }
        return nil
    }

    private func buildMask(_ poly: [NSPoint]) -> Mask {
        var m = Mask(cols: mask.cols, rows: mask.rows)
        let cw = W / CGFloat(m.cols), ch = H / CGFloat(m.rows)
        let p = path(poly)
        for r in 0..<m.rows {
            for c in 0..<m.cols {
                // 格子任一角落在死区内就算死区（宁多勿少）
                let x0 = CGFloat(c) * cw, y0 = H - CGFloat(r + 1) * ch
                if p.contains(NSPoint(x: x0 + cw / 2, y: y0 + ch / 2)) ||
                   p.contains(NSPoint(x: x0, y: y0)) || p.contains(NSPoint(x: x0 + cw, y: y0)) ||
                   p.contains(NSPoint(x: x0, y: y0 + ch)) || p.contains(NSPoint(x: x0 + cw, y: y0 + ch)) {
                    m[c, r] = true
                }
            }
        }
        return m
    }

    private func save() {
        guard let poly = deadPolygon(line) else { NSSound.beep(); return }
        onFinish?(buildMask(poly))
    }

    // MARK: 事件

    override func mouseDown(with e: NSEvent) {
        if e.clickCount >= 2 { save(); return }
        line.append(clamp(convert(e.locationInWindow, from: nil)))
        dragging = false
        needsDisplay = true
    }
    override func mouseDragged(with e: NSEvent) {
        let p = clamp(convert(e.locationInWindow, from: nil))
        cursor = p
        if let last = line.last, hypot(p.x - last.x, p.y - last.y) > 6 { line.append(p); dragging = true }
        needsDisplay = true
    }
    override func mouseMoved(with e: NSEvent) { cursor = convert(e.locationInWindow, from: nil); needsDisplay = true }
    override func rightMouseDown(with e: NSEvent) { save() }

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 36, 76: save()                                               // 回车：保存
        case 53: onFinish?(nil)                                           // Esc：取消
        case 51, 117: if !line.isEmpty { line.removeLast(); needsDisplay = true }   // Delete：删最后一个点
        default:
            if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "z", !line.isEmpty {
                line.removeLast(); needsDisplay = true
            } else if e.charactersIgnoringModifiers?.lowercased() == "c" {
                line.removeAll(); needsDisplay = true                    // C：重画
            } else { super.keyDown(with: e) }
        }
    }

    // MARK: 绘制

    override func draw(_ dirty: NSRect) {
        NSColor(white: 0, alpha: 0.2).setFill()
        bounds.fill()

        var pts = line
        if let c = cursor, !line.isEmpty, !dragging { pts.append(clamp(c)) }

        // 预览死区
        if let poly = deadPolygon(pts) {
            NSColor.systemRed.withAlphaComponent(0.45).setFill()
            path(poly).fill()
        } else if line.isEmpty && !mask.isEmpty {
            // 显示已保存的死区
            let cw = W / CGFloat(mask.cols), ch = H / CGFloat(mask.rows)
            NSColor.systemRed.withAlphaComponent(0.35).setFill()
            for g in mask.gridRects() {
                NSRect(x: CGFloat(g.c0) * cw, y: H - CGFloat(g.r1) * ch,
                       width: CGFloat(g.c1 - g.c0) * cw, height: CGFloat(g.r1 - g.r0) * ch).fill()
            }
        }

        // 延伸部分（虚线）
        if pts.count >= 2 {
            let full = extended(pts)
            let ext = NSBezierPath()
            ext.move(to: full[0]); full.dropFirst().forEach(ext.line)
            ext.lineWidth = 1.5; ext.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.white.setStroke(); ext.stroke()
        }
        // 用户画的线
        if pts.count >= 2 {
            let l = NSBezierPath()
            l.move(to: pts[0]); pts.dropFirst().forEach(l.line)
            l.lineWidth = 3; NSColor.systemYellow.setStroke(); l.stroke()
        }
        if !dragging {
            for p in line {
                let dot = NSBezierPath(ovalIn: NSRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
                NSColor.systemYellow.setFill(); dot.fill()
            }
        }

        // 贯穿全屏的十字线：鼠标进了黑区也能看出它在哪
        if let c = cursor {
            NSColor.systemGreen.withAlphaComponent(0.9).setFill()
            NSRect(x: 0, y: c.y - 0.5, width: W, height: 1).fill()
            NSRect(x: c.x - 0.5, y: 0, width: 1, height: H).fill()
        }

        let tip = """
        沿坏区边界画一条线（在看得见的一侧，单击逐点 或 按住拖动都可以）
        线两端会自动延伸到屏幕边缘，线的【右上方】全部当作死区（红色预览）
        双击 / 回车 / 右键：保存并退出     Esc：取消
        Delete 或 ⌘Z：删掉最后一个点     C：清空重画
        """ as NSString
        let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineSpacing = 5
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium),
                                                    .foregroundColor: NSColor.white, .paragraphStyle: para]
        let size = tip.boundingRect(with: NSSize(width: 900, height: 400), options: .usesLineFragmentOrigin, attributes: attrs).size
        let box = NSRect(x: 40, y: 40, width: size.width + 48, height: size.height + 32)   // 放在左下角，远离坏区
        NSColor(white: 0.1, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).fill()
        tip.draw(with: box.insetBy(dx: 24, dy: 16), options: .usesLineFragmentOrigin, attributes: attrs)
    }
}

final class Editor {
    private var window: NSWindow?

    func open(screen: NSScreen, done: @escaping () -> Void) {
        let f = screen.frame
        let w = KeyableWindow(contentRect: f, styleMask: .borderless, backing: .buffered, defer: false)
        w.setFrame(f, display: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.acceptsMouseMovedEvents = true

        let v = EditorView(frame: NSRect(origin: .zero, size: f.size),
                           mask: Store.mask(for: screen) ?? Mask(size: f.size))
        v.onFinish = { [weak self] m in
            if let m { Store.set(m, for: screen) }
            self?.window?.orderOut(nil)
            self?.window = nil
            done()
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

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let overlays = OverlayManager()
    private let avoider = WindowAvoider()
    private let mouse = MouseGuard()
    private let editor = Editor()
    private var timer: Timer?
    private var editing = false
    private var zones: [DeadZone] = []

    private var showOverlay: Bool { Store.bool("showOverlay", default: true) }
    private var avoidWindows: Bool { Store.bool("avoidWindows", default: true) }
    private var blockMouse: Bool { Store.bool("blockMouse", default: true) }

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
        }
        reload()
        if zones.isEmpty, let s = NSScreen.screens.first(where: { CGDisplayIsBuiltin($0.displayID) == 0 }) ?? NSScreen.screens.last {
            startEditing(s)
        }
    }

    /// 再次打开 App（例如在访达里双击）时进入编辑，防止菜单栏图标被刘海挤掉后无从下手
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !editing, let s = NSScreen.screens.first(where: { CGDisplayIsBuiltin($0.displayID) == 0 }) ?? NSScreen.screens.last {
            startEditing(s)
        }
        return false
    }

    private func tickWindows() {
        guard !editing, avoidWindows else { return }
        avoider.tick(zones: zones)
    }

    @objc func reload() {
        zones = Store.zones()
        overlays.rebuild(zones: zones, visible: showOverlay && !editing)
        mouse.zones = zones
        if blockMouse && !editing && !zones.isEmpty { mouse.start() } else { mouse.stop() }
        statusItem.button?.appearsDisabled = zones.isEmpty
    }

    private func startEditing(_ s: NSScreen) {
        editing = true
        reload()
        editor.open(screen: s) { [weak self] in
            self?.editing = false
            self?.reload()
        }
    }

    private func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let names = zones.map { $0.screen.localizedName }
        menu.addItem(disabled(names.isEmpty ? "还没有设置坏区" : "已屏蔽坏区：" + names.joined(separator: "、")))
        if !AXIsProcessTrusted() {
            menu.addItem(item("⚠️ 需要辅助功能权限（点此授权）", #selector(openAXSettings)))
        }
        menu.addItem(.separator())

        let editItem = NSMenuItem(title: "编辑坏区…", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (i, s) in NSScreen.screens.enumerated() {
            let it = item(s.title + (Store.mask(for: s) == nil ? "" : "  ●"), #selector(editScreen(_:)))
            it.tag = i
            sub.addItem(it)
        }
        editItem.submenu = sub
        menu.addItem(editItem)
        menu.addItem(item("清除全部坏区", #selector(clearAll)))
        menu.addItem(.separator())

        menu.addItem(toggle("黑色遮罩坏区", "showOverlay", showOverlay))
        menu.addItem(toggle("自动把窗口移出坏区", "avoidWindows", avoidWindows))
        menu.addItem(toggle("阻止鼠标进入坏区", "blockMouse", blockMouse))
        let login = item("开机自动启动", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("退出", #selector(quit), key: "q"))
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
            let a = NSAlert(); a.messageText = "设置开机启动失败"; a.informativeText = error.localizedDescription; a.runModal()
        }
    }
    @objc func openAXSettings() {
        requestAccessibility()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
