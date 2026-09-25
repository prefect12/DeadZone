// 生成 App 图标：一台显示器，屏幕右上角被一条弧线切掉（死区），可用区域里有一个贴边摆放的窗口。
// 用法：swift scripts/make_icon.swift Resources/icon.png

import AppKit

let S: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// 背景：macOS 标准圆角方块（824pt，四周留阴影空间）
let bg = NSRect(x: 100, y: 100, width: 824, height: 824)
let bgPath = NSBezierPath(roundedRect: bg, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor(white: 0, alpha: 0.35).cgColor)
hex(0x1B2433).setFill(); bgPath.fill()
ctx.restoreGState()
NSGradient(starting: hex(0x243049), ending: hex(0x0D131C))!.draw(in: bgPath, angle: -90)
hex(0xFFFFFF, 0.08).setStroke(); bgPath.lineWidth = 3; bgPath.stroke()

// 支架
let neck = NSBezierPath()
neck.move(to: NSPoint(x: 470, y: 322)); neck.line(to: NSPoint(x: 554, y: 322))
neck.line(to: NSPoint(x: 572, y: 246)); neck.line(to: NSPoint(x: 452, y: 246)); neck.close()
NSGradient(starting: hex(0x9AA6B8), ending: hex(0x5E6A7D))!.draw(in: neck, angle: -90)
let base = NSBezierPath(roundedRect: NSRect(x: 366, y: 222, width: 292, height: 32), xRadius: 16, yRadius: 16)
NSGradient(starting: hex(0xD5DCE6), ending: hex(0x8C98AA))!.draw(in: base, angle: -90)

// 显示器外框
let body = NSRect(x: 164, y: 310, width: 696, height: 478)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 44, yRadius: 44)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor(white: 0, alpha: 0.5).cgColor)
hex(0x05070B).setFill(); bodyPath.fill()
ctx.restoreGState()
hex(0xFFFFFF, 0.10).setStroke(); bodyPath.lineWidth = 3; bodyPath.stroke()

// 屏幕
let screen = NSRect(x: 196, y: 342, width: 632, height: 414)
let screenPath = NSBezierPath(roundedRect: screen, xRadius: 18, yRadius: 18)
NSGradient(colors: [hex(0x34D5C0), hex(0x3B82F6), hex(0x8B5CF6)])!.draw(in: screenPath, angle: -35)

// 死区分界线：从屏幕顶边弯到右边
let p0 = NSPoint(x: 470, y: screen.maxY)
let c1 = NSPoint(x: 540, y: 640), c2 = NSPoint(x: 690, y: 556)
let p1 = NSPoint(x: screen.maxX, y: 500)
let dead = NSBezierPath()
dead.move(to: p0); dead.curve(to: p1, controlPoint1: c1, controlPoint2: c2)
dead.line(to: NSPoint(x: screen.maxX + 20, y: screen.maxY + 20)); dead.close()

ctx.saveGState()
screenPath.addClip()
hex(0x06080C).setFill(); dead.fill()
// 死区里的暗纹斜线
dead.addClip()
hex(0xFFFFFF, 0.06).setStroke()
var x: CGFloat = 300
while x < 1500 {
    let l = NSBezierPath(); l.move(to: NSPoint(x: x, y: 300)); l.line(to: NSPoint(x: x - 600, y: 900))
    l.lineWidth = 6; l.stroke(); x += 30
}
ctx.restoreGState()

// 分界线：发光的珊瑚红
let edge = NSBezierPath()
edge.move(to: p0); edge.curve(to: p1, controlPoint1: c1, controlPoint2: c2)
edge.lineCapStyle = .round
ctx.saveGState()
screenPath.addClip()
ctx.setShadow(offset: .zero, blur: 22, color: hex(0xFF5A5F, 0.9).cgColor)
edge.lineWidth = 12; hex(0xFF5A5F).setStroke(); edge.stroke()
ctx.restoreGState()

// 可用区域里的一个窗口，右上角贴近分界线
let win = NSRect(x: 232, y: 384, width: 300, height: 206)
let winPath = NSBezierPath(roundedRect: win, xRadius: 16, yRadius: 16)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: NSColor(white: 0, alpha: 0.35).cgColor)
hex(0xF7F9FC, 0.96).setFill(); winPath.fill()
ctx.restoreGState()
// 标题栏
ctx.saveGState(); winPath.addClip()
hex(0xE3E8F0).setFill(); NSRect(x: win.minX, y: win.maxY - 40, width: win.width, height: 40).fill()
ctx.restoreGState()
for (i, c) in [hex(0xFF5F57), hex(0xFEBC2E), hex(0x28C840)].enumerated() {
    c.setFill()
    NSBezierPath(ovalIn: NSRect(x: win.minX + 20 + CGFloat(i) * 26, y: win.maxY - 28, width: 16, height: 16)).fill()
}
// 内容占位条
hex(0xC5CEDB).setFill()
for (i, w) in [220.0, 180.0, 240.0, 150.0].enumerated() {
    NSBezierPath(roundedRect: NSRect(x: win.minX + 24, y: win.maxY - 74 - CGFloat(i) * 30, width: w, height: 12),
                 xRadius: 6, yRadius: 6).fill()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
