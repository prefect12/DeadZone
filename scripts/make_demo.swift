// 生成 README 用的示意动画（GIF）：坏区标记 → 窗口被推出 → 鼠标贴边滑动 → 顶着坏区最大化
// 用法：swift scripts/make_demo.swift Resources/demo.gif

import AppKit
import ImageIO
import UniformTypeIdentifiers

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "demo.gif"
let W: CGFloat = 800, H: CGFloat = 500
let fps: Double = 20
let scale: CGFloat = 1

func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: a)
}

// MARK: 几何（左上原点）

let scr = CGRect(x: 56, y: 30, width: 688, height: 390)
let P0 = CGPoint(x: scr.minX + 330, y: scr.minY)
let C1 = CGPoint(x: scr.minX + 400, y: scr.minY + 110)
let C2 = CGPoint(x: scr.minX + 560, y: scr.minY + 190)
let P1 = CGPoint(x: scr.maxX, y: scr.minY + 230)

func bez(_ t: CGFloat) -> CGPoint {
    let u = 1 - t
    return CGPoint(x: u*u*u*P0.x + 3*u*u*t*C1.x + 3*u*t*t*C2.x + t*t*t*P1.x,
                   y: u*u*u*P0.y + 3*u*u*t*C1.y + 3*u*t*t*C2.y + t*t*t*P1.y)
}
let curve = (0...400).map { bez(CGFloat($0) / 400) }
let deadPath: CGPath = {
    let p = CGMutablePath()
    p.addLines(between: curve + [CGPoint(x: scr.maxX + 2, y: scr.minY - 2)])
    p.closeSubpath()
    return p
}()

/// 曲线上 y 对应的 x（曲线 x、y 都单调递增）
func curveX(atY y: CGFloat) -> CGFloat {
    if y <= P0.y { return P0.x }
    if y >= P1.y { return .greatestFiniteMagnitude }
    for i in 1..<curve.count where curve[i].y >= y {
        let a = curve[i - 1], b = curve[i]
        return a.x + (b.x - a.x) * (y - a.y) / max(b.y - a.y, 0.0001)
    }
    return .greatestFiniteMagnitude
}
func curveY(atX x: CGFloat) -> CGFloat {
    if x <= P0.x { return scr.minY }
    for i in 1..<curve.count where curve[i].x >= x {
        let a = curve[i - 1], b = curve[i]
        return a.y + (b.y - a.y) * (x - a.x) / max(b.x - a.x, 0.0001)
    }
    return P1.y
}

/// 与 App 中相同的思路：落在坏区里的点投影到分界线上，再往外推一点
func project(_ p: CGPoint) -> CGPoint {
    guard deadPath.contains(p) else { return p }
    var best = curve[0], bd = CGFloat.greatestFiniteMagnitude
    for q in curve { let d = hypot(q.x - p.x, q.y - p.y); if d < bd { bd = d; best = q } }
    let n = max(bd, 0.001)
    return CGPoint(x: best.x + (best.x - p.x) / n * 2, y: best.y + (best.y - p.y) / n * 2)
}

let winSize = CGSize(width: 240, height: 160)
let home = CGRect(origin: CGPoint(x: 110, y: 200), size: winSize)
let dragged = CGRect(origin: CGPoint(x: 360, y: 120), size: winSize)
let grab = CGPoint(x: 30, y: 14)

// 松手后的位置：左移或下移，取位移小的
let snapped: CGRect = {
    let left = curveX(atY: dragged.minY) - winSize.width - 2
    let down = curveY(atX: dragged.maxX) + 2
    return abs(dragged.minX - left) < abs(dragged.minY - down)
        ? CGRect(origin: CGPoint(x: left, y: dragged.minY), size: winSize)
        : CGRect(origin: CGPoint(x: dragged.minX, y: down), size: winSize)
}()

// 顶着坏区最大化：左下锚定，枚举顶边
let maxRect: CGRect = {
    var best = CGRect.zero
    var t = scr.minY + 14   // 菜单栏下方
    while t < scr.maxY - 100 {
        let w = min(curveX(atY: t) - 2, scr.maxX) - scr.minX
        let r = CGRect(x: scr.minX, y: t, width: w, height: scr.maxY - t)
        if r.width * r.height > best.width * best.height { best = r }
        t += 1
    }
    return best
}()

// MARK: 动画工具

func clamp01(_ v: Double) -> CGFloat { CGFloat(max(0, min(1, v))) }
func ease(_ v: CGFloat) -> CGFloat { v < 0.5 ? 2 * v * v : 1 - pow(-2 * v + 2, 2) / 2 }
func prog(_ t: Double, _ a: Double, _ b: Double) -> CGFloat { ease(clamp01((t - a) / (b - a))) }
func lerp(_ a: CGFloat, _ b: CGFloat, _ k: CGFloat) -> CGFloat { a + (b - a) * k }
func lerp(_ a: CGPoint, _ b: CGPoint, _ k: CGFloat) -> CGPoint { CGPoint(x: lerp(a.x, b.x, k), y: lerp(a.y, b.y, k)) }
func lerp(_ a: CGRect, _ b: CGRect, _ k: CGFloat) -> CGRect {
    CGRect(x: lerp(a.minX, b.minX, k), y: lerp(a.minY, b.minY, k),
           width: lerp(a.width, b.width, k), height: lerp(a.height, b.height, k))
}

struct Frame {
    var glitch = false
    var line: CGFloat = 0          // 分界线绘制进度
    var red: CGFloat = 0           // 红色预览
    var black: CGFloat = 0         // 黑色遮罩
    var window = home
    var cursor: CGPoint?
    var click: CGFloat?            // 点击涟漪 0...1
    var caption = ""
    var step = 0
}

func state(_ t: Double) -> Frame {
    var f = Frame()
    // ① 坏区
    f.glitch = t < 3.4
    f.caption = "显示器右上角坏了，窗口和鼠标照样会跑进去"
    f.step = 1
    if t >= 2 {
        f.step = 2
        f.caption = "沿坏区边界画一条线，线的右上方就是死区"
        f.line = prog(t, 2.0, 3.0)
        f.red = t < 3.3 ? prog(t, 2.9, 3.1) : 1 - prog(t, 3.3, 3.7)
        f.black = prog(t, 3.3, 3.7)
    }
    // ② 拖窗口
    if t >= 4.0 {
        f.step = 3
        f.caption = "窗口拖进死区 → 松手自动推出，贴边摆放"
        let pick = home.origin.applying(.init(translationX: grab.x, y: grab.y))
        f.cursor = lerp(CGPoint(x: 200, y: 360), pick, prog(t, 4.0, 4.5))
        let d = prog(t, 4.7, 5.9)
        f.window = lerp(home, dragged, d)
        if t >= 4.7 { f.cursor = CGPoint(x: f.window.minX + grab.x, y: f.window.minY + grab.y) }
        if t >= 6.2 {
            f.window = lerp(dragged, snapped, prog(t, 6.2, 6.6))
            f.cursor = CGPoint(x: dragged.minX + grab.x, y: dragged.minY + grab.y)
        }
    }
    // ③ 鼠标贴边
    if t >= 7.5 {
        f.step = 4
        f.caption = "鼠标碰到边界会贴着分界线滑动，进不去"
        f.window = snapped
        let start = CGPoint(x: dragged.minX + grab.x, y: dragged.minY + grab.y)
        let raw: CGPoint
        if t < 8.0 { raw = lerp(start, CGPoint(x: 250, y: 330), prog(t, 7.5, 8.0)) }
        else { raw = lerp(CGPoint(x: 250, y: 330), CGPoint(x: 760, y: 40), CGFloat(clamp01((t - 8.0) / 2.2))) }
        f.cursor = project(raw)
    }
    // ④ 最大化
    if t >= 10.6 {
        f.step = 5
        f.caption = "最大化 / 全屏 = 顶着死区最大化，像普通屏幕一样用"
        let green = CGPoint(x: snapped.minX + 58, y: snapped.minY + 14)
        let from = project(CGPoint(x: 760, y: 40))
        f.cursor = lerp(from, green, prog(t, 10.6, 11.5))
        if t >= 11.6 && t < 12.0 { f.click = CGFloat((t - 11.6) / 0.4) }
        f.window = lerp(snapped, maxRect, prog(t, 11.8, 12.5))
        if t >= 11.8 { f.cursor = CGPoint(x: f.window.minX + 58, y: f.window.minY + 14) }
        if t >= 12.6 { f.cursor = lerp(CGPoint(x: f.window.minX + 58, y: f.window.minY + 14),
                                       CGPoint(x: 300, y: 330), prog(t, 12.6, 13.2)) }
    }
    if t >= 13.6 { f.caption = "DeadZone  ·  github.com/prefect12/DeadZone"; f.step = 0 }
    return f
}

// MARK: 绘制

func rounded(_ r: CGRect, _ rad: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil) }

struct LCG { var s: UInt64; mutating func next() -> CGFloat { s = s &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(s >> 33) / CGFloat(1 << 31) } }

func drawWindow(_ c: CGContext, _ r: CGRect) {
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 6), blur: 14, color: hex(0x000000, 0.35))
    c.addPath(rounded(r, 10)); c.setFillColor(hex(0xF4F6FA)); c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(rounded(r, 10)); c.clip()
    c.setFillColor(hex(0xDDE3EC)); c.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: 28))
    c.setFillColor(hex(0xC6CFDC))
    let lines: [CGFloat] = [0.75, 0.6, 0.82, 0.5, 0.7, 0.4, 0.78, 0.55]
    var y = r.minY + 46
    for w in lines where y + 8 < r.maxY - 10 {
        c.addPath(rounded(CGRect(x: r.minX + 18, y: y, width: (r.width - 36) * w, height: 8), 4)); c.fillPath()
        y += 22
    }
    c.restoreGState()
    for (i, col) in [hex(0xFF5F57), hex(0xFEBC2E), hex(0x28C840)].enumerated() {
        c.setFillColor(col)
        c.fillEllipse(in: CGRect(x: r.minX + 12 + CGFloat(i) * 20, y: r.minY + 8, width: 12, height: 12))
    }
}

func drawCursor(_ c: CGContext, _ p: CGPoint) {
    let pts: [CGPoint] = [(0, 0), (0, 17), (4.5, 13), (7.5, 20), (10, 19), (7, 12.5), (12.5, 12.5)]
        .map { CGPoint(x: p.x + $0.0 * 1.2, y: p.y + $0.1 * 1.2) }
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: hex(0x000000, 0.4))
    c.addLines(between: pts); c.closePath()
    c.setFillColor(hex(0xFFFFFF)); c.setStrokeColor(hex(0x000000)); c.setLineWidth(1.3)
    c.drawPath(using: .fillStroke)
    c.restoreGState()
}

func render(_ t: Double, frameIndex: Int) -> CGImage {
    let f = state(t)
    let c = CGContext(data: nil, width: Int(W * scale), height: Int(H * scale), bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.scaleBy(x: scale, y: scale)
    c.translateBy(x: 0, y: H); c.scaleBy(x: 1, y: -1)     // 左上原点
    NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)

    c.setFillColor(hex(0x0E131B)); c.fill(CGRect(x: 0, y: 0, width: W, height: H))

    // 显示器
    c.addPath(rounded(scr.insetBy(dx: -14, dy: -14), 18)); c.setFillColor(hex(0x05070B)); c.fillPath()
    c.addPath(rounded(scr.insetBy(dx: -14, dy: -14), 18)); c.setStrokeColor(hex(0xFFFFFF, 0.08)); c.setLineWidth(1.5); c.strokePath()

    c.saveGState()
    c.addPath(rounded(scr, 6)); c.clip()
    c.setFillColor(hex(0x2E5C8A)); c.fill(scr)
    c.setFillColor(hex(0x3A6FA3)); c.fillEllipse(in: CGRect(x: scr.minX - 120, y: scr.maxY - 220, width: 520, height: 420))
    c.setFillColor(hex(0x1B2A3A)); c.fill(CGRect(x: scr.minX, y: scr.minY, width: scr.width, height: 14))

    drawWindow(c, f.window)

    // 坏掉的区域：花屏
    if f.glitch {
        c.saveGState(); c.addPath(deadPath); c.clip()
        var rng = LCG(s: UInt64(frameIndex / 2 &* 7919 &+ 17))
        c.setFillColor(hex(0x101010)); c.fill(scr)
        let cols = [hex(0xFF2BD6), hex(0x00FFA3), hex(0x00C8FF), hex(0xFFFFFF), hex(0x6B00FF), hex(0x2A2A2A)]
        for _ in 0..<22 {
            let y = scr.minY + rng.next() * 240, h = 2 + rng.next() * 14
            let x = P0.x - 40 + rng.next() * 300
            c.setFillColor(cols[Int(rng.next() * CGFloat(cols.count)) % cols.count])
            c.fill(CGRect(x: x, y: y, width: 60 + rng.next() * 400, height: h))
        }
        c.restoreGState()
    }
    // 红色预览 / 黑色遮罩
    if f.red > 0 {
        c.addPath(deadPath); c.setFillColor(hex(0xFF5A5F, 0.55 * f.red)); c.fillPath()
    }
    if f.black > 0 {
        c.addPath(deadPath); c.setFillColor(hex(0x000000, f.black)); c.fillPath()
    }
    c.restoreGState()

    // 分界线
    if f.line > 0 {
        let n = max(2, Int(CGFloat(curve.count - 1) * f.line))
        c.saveGState()
        c.addLines(between: Array(curve.prefix(n)))
        let isDrawing = f.black < 1
        c.setStrokeColor(isDrawing ? hex(0xFFD60A) : hex(0xFF5A5F, 0.9))
        c.setLineWidth(isDrawing ? 3 : 2)
        c.setLineCap(.round)
        if !isDrawing { c.setLineDash(phase: 0, lengths: [6, 5]) }
        c.strokePath()
        c.restoreGState()
    }

    if let k = f.click, let p = f.cursor {
        let r = 6 + 22 * k
        c.setStrokeColor(hex(0xFFFFFF, 0.8 * (1 - k))); c.setLineWidth(2)
        c.strokeEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    }
    if let p = f.cursor { drawCursor(c, p) }

    // 步骤指示 + 字幕
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let capAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 19, weight: .semibold),
                                                   .foregroundColor: NSColor.white, .paragraphStyle: para]
    (f.caption as NSString).draw(in: CGRect(x: 0, y: 452, width: W, height: 30), withAttributes: capAttrs)
    if f.step > 0 {
        for i in 1...5 {
            let x = W / 2 - 50 + CGFloat(i - 1) * 25
            c.setFillColor(i == f.step ? hex(0xFF5A5F) : hex(0xFFFFFF, 0.25))
            c.fillEllipse(in: CGRect(x: x - 4, y: 484, width: 8, height: 8))
        }
    }
    return c.makeImage()!
}

// MARK: 输出 GIF

let total = 15.0
let count = Int(total * fps)
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.gif.identifier as CFString, count, nil)!
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps,
                                             kCGImagePropertyGIFUnclampedDelayTime: 1 / fps]] as CFDictionary
for i in 0..<count {
    CGImageDestinationAddImage(dest, render(Double(i) / fps, frameIndex: i), props)
}
CGImageDestinationFinalize(dest)
print("wrote \(out) (\(count) frames)")
