// 生成 GrandLine App 图标（1024×1024 PNG）
// 用法：swiftc -O Scripts/make_icon.swift -o build/make_icon && build/make_icon <输出路径>
//
// 设计：深墨底 + 金属金内框 + 罗盘刻度环 + 锚。全部矢量绘制，无第三方素材。

import AppKit

let side = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: side, pixelsHigh: side,
                                 bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else {
    FileHandle.standardError.write("cannot create bitmap\n".data(using: .utf8)!)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

let S = CGFloat(side)
let gold = NSColor(srgbRed: 0.94, green: 0.82, blue: 0.58, alpha: 1)
let goldDim = NSColor(srgbRed: 0.82, green: 0.68, blue: 0.40, alpha: 1)

// 内容区留白（macOS 图标规范）
let inset: CGFloat = S * 0.055
let rect = NSRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let radius = rect.width * 0.2237

// 背景
let body = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
NSGraphicsContext.saveGraphicsState()
body.addClip()

let bg = NSGradient(colors: [NSColor(srgbRed: 0.085, green: 0.110, blue: 0.150, alpha: 1),
                             NSColor(srgbRed: 0.020, green: 0.030, blue: 0.043, alpha: 1)])!
bg.draw(in: rect, angle: -78)

// 左上暖光
let glow = NSGradient(colors: [goldDim.withAlphaComponent(0.34),
                               goldDim.withAlphaComponent(0.0)])!
let globe = NSBezierPath(ovalIn: NSRect(x: rect.midX - rect.width * 0.85,
                                        y: rect.maxY - rect.height * 0.75,
                                        width: rect.width * 1.7,
                                        height: rect.height * 1.7))
glow.draw(in: globe, relativeCenterPosition: NSPoint(x: -0.18, y: 0.22))

// 右下冷海光
let sea = NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.26, blue: 0.29, alpha: 0.30),
                              NSColor(srgbRed: 0.16, green: 0.26, blue: 0.29, alpha: 0.0)])!
let seaBall = NSBezierPath(ovalIn: NSRect(x: rect.midX - rect.width * 0.55,
                                          y: rect.minY - rect.height * 0.85,
                                          width: rect.width * 1.9,
                                          height: rect.height * 1.9))
sea.draw(in: seaBall, relativeCenterPosition: NSPoint(x: 0.2, y: -0.2))

NSGraphicsContext.restoreGraphicsState()

// 内金框
let frameInset: CGFloat = S * 0.105
let frameRect = NSRect(x: frameInset, y: frameInset,
                       width: S - frameInset * 2, height: S - frameInset * 2)
let frame = NSBezierPath(roundedRect: frameRect,
                         xRadius: radius * 0.78, yRadius: radius * 0.78)
frame.lineWidth = 4
gold.withAlphaComponent(0.62).setStroke()
frame.stroke()

// 罗盘刻度环
let center = NSPoint(x: rect.midX, y: rect.midY)
let ringR: CGFloat = S * 0.315
let ring = NSBezierPath()
ring.appendArc(withCenter: center, radius: ringR, startAngle: 0, endAngle: 360)
ring.lineWidth = 2
gold.withAlphaComponent(0.24).setStroke()
ring.stroke()

let ticks = NSBezierPath()
let tickCount = 60
for i in 0..<tickCount {
    let a = CGFloat(i) / CGFloat(tickCount) * 2 * .pi
    let major = i % 5 == 0
    let len: CGFloat = major ? S * 0.026 : S * 0.012
    ticks.move(to: NSPoint(x: center.x + cos(a) * (ringR - len),
                           y: center.y + sin(a) * (ringR - len)))
    ticks.line(to: NSPoint(x: center.x + cos(a) * ringR, y: center.y + sin(a) * ringR))
}
ticks.lineWidth = 3
gold.withAlphaComponent(0.55).setStroke()
ticks.stroke()

// 草帽：宽檐 + 圆顶 + 帽带。纯路径手绘，不依赖符号库。
do {
    let cx = center.x
    let hatTop = center.y + S * 0.130

    let brimW = S * 0.660
    let brimH = S * 0.125
    let brimCY = center.y - S * 0.080

    let crownBaseY = center.y - S * 0.065
    let crownTopY = hatTop
    let shoulderY = crownTopY - S * 0.040
    let halfBase = S * 0.185
    let halfTop = S * 0.135

    let hat = NSBezierPath()
    hat.appendOval(in: NSRect(x: cx - brimW / 2, y: brimCY - brimH / 2,
                              width: brimW, height: brimH))
    hat.move(to: NSPoint(x: cx - halfBase, y: crownBaseY))
    hat.line(to: NSPoint(x: cx - halfTop, y: shoulderY))
    hat.curve(to: NSPoint(x: cx + halfTop, y: shoulderY),
              controlPoint1: NSPoint(x: cx - halfTop * 0.75, y: crownTopY + S * 0.055),
              controlPoint2: NSPoint(x: cx + halfTop * 0.75, y: crownTopY + S * 0.055))
    hat.line(to: NSPoint(x: cx + halfBase, y: crownBaseY))
    hat.close()

    // 帽身：竖向金铜渐变
    NSGraphicsContext.saveGraphicsState()
    hat.addClip()
    let hatGrad = NSGradient(colors: [NSColor(srgbRed: 0.93, green: 0.80, blue: 0.55, alpha: 1),
                                      NSColor(srgbRed: 0.68, green: 0.53, blue: 0.27, alpha: 1)])!
    hatGrad.draw(in: hat, angle: -90)

    // 帽带：一条蜡封红，是「草帽」最好认的一笔
    let bandTop = crownBaseY + S * 0.045
    let bandH = S * 0.042
    NSColor(srgbRed: 0.56, green: 0.23, blue: 0.20, alpha: 0.92).setFill()
    NSRect(x: cx - S * 0.30, y: bandTop, width: S * 0.60, height: bandH).fill()

    // 檐下阴影，让帽檐有厚度
    let shade = NSGradient(colors: [NSColor.black.withAlphaComponent(0.0),
                                    NSColor.black.withAlphaComponent(0.28)])!
    shade.draw(in: NSRect(x: cx - brimW / 2, y: brimCY + brimH * 0.05,
                          width: brimW, height: brimH * 0.5), angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    // 轮廓：一层深色描边把帽子从背景里托起来
    hat.lineWidth = S * 0.010
    NSColor(srgbRed: 0.20, green: 0.13, blue: 0.05, alpha: 0.85).setStroke()
    hat.stroke()

}

// GrandLine 字样（帽檐正下方）
do {
    let text = "GrandLine" as NSString
    let font = NSFont.boldSystemFont(ofSize: S * 0.068)
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
    shadow.shadowOffset = NSSize(width: 0, height: -S * 0.004)
    shadow.shadowBlurRadius = S * 0.008
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: gold,
        .kern: S * 0.006,
        .paragraphStyle: para,
        .shadow: shadow,
    ]
    let size = text.size(withAttributes: attrs)
    // 帽檐下缘约在 center.y - S*0.255，罗盘环下缘约在 center.y - S*0.315，文字落在两者之间
    let baselineY = center.y - S * 0.262
    text.draw(at: NSPoint(x: center.x - size.width / 2, y: baselineY), withAttributes: attrs)
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
