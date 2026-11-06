import SwiftUI
import AppKit

// MARK: - 色板：Night Chart（夜航图）
//
// 整体压暗、降饱和，只用低饱和的金属金做提亮。
// 面层不是纯白叠加，而是暖羊皮纸白（#E8D9B8）低透明度，避免死黑与冷灰。

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

extension Color {
    // 底
    static let glBackground     = Color(hex: 0x0A0E14)
    static let glBackgroundDeep = Color(hex: 0x06090D)

    // 面
    static let glSurface   = Color(hex: 0xE8D9B8, alpha: 0.070)
    static let glSurfaceHi = Color(hex: 0xE8D9B8, alpha: 0.120)

    // 线
    static let glStroke     = Color(hex: 0xD4AF6A, alpha: 0.30)
    static let glStrokeSoft = Color(hex: 0xD4AF6A, alpha: 0.13)

    // 字
    static let glText    = Color(hex: 0xF4EEDF)
    static let glTextDim = Color(hex: 0xA59C8A)

    // 金属
    static let glGold       = Color(hex: 0xD4AF6A)
    static let glGoldBright = Color(hex: 0xF1D494)
    static let glGoldDeep   = Color(hex: 0x9A7A3C)

    // 语义
    static let glWax = Color(hex: 0x9E453A)   // 蜡封红：拒绝 / 失败 / PIN
    static let glSea = Color(hex: 0x8FBF9B)   // 海绿：抵达 / 成功

    // 旧语义名映射，保持调用点稳定
    static let glAccent  = Color.glGold
    static let glAccent2 = Color.glGoldDeep
    static let glGreen   = Color.glSea
    static let glRed     = Color.glWax
    static let glAmber   = Color(hex: 0xD9A659)
}

/// 金铜渐变：主按钮、进度、徽标
let glAccentGradient = LinearGradient(colors: [Color(hex: 0xF0D28F), Color(hex: 0xB28438)],
                                      startPoint: .topLeading,
                                      endPoint: .bottomTrailing)

/// 极细的金属描边渐变（卡片高光边）
let glHairline = LinearGradient(colors: [Color.glGold.opacity(0.68),
                                         Color.glGold.opacity(0.16),
                                         Color.glGold.opacity(0.36)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing)

// MARK: - 字体
//
// 标题/分区标签用 New York（衬线，系统自带，无需打包字体），
// 正文与按钮保持 SF 保证可读性，数字用等宽。

enum GLFont {
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - 设备色板
//
// 低饱和的金 / 海绿 / 石蓝 / 铁锈，保证白图标对比度，同时不破坏暗调整体感。

enum PeerPalette {
    private static let pairs: [[UInt32]] = [
        [0xD9B46C, 0x96742F],   // 黄铜
        [0x8FBF9B, 0x47745F],   // 海绿
        [0x9FB2C9, 0x57688A],   // 石蓝
        [0xD49A70, 0x96573A],   // 铁锈
        [0xBBA0BD, 0x6E5570],   // 暮紫
        [0xC9B287, 0x83704C]    // 沙金
    ]

    static func gradient(for id: String) -> LinearGradient {
        var h = 5381
        for u in id.unicodeScalars {
            h = ((h &* 33) &+ Int(u.value)) & 0x7FFF_FFFF
        }
        let pair = pairs[h % pairs.count]
        return LinearGradient(colors: [Color(hex: pair[0]), Color(hex: pair[1])],
                              startPoint: .topLeading,
                              endPoint: .bottomTrailing)
    }
}

// MARK: - 头像

/// 统一头像：有照片显示照片，否则回退到按设备 ID 稳定取色的渐变
struct GLAvatar: View {
    var image: NSImage?
    var seed: String = ""
    var size: CGFloat = 40
    /// nil 表示正圆
    var cornerRadius: CGFloat? = nil
    var symbol: String = "laptopcomputer"
    /// 无照片时使用的渐变；nil 则按 seed 稳定取色
    var gradient: LinearGradient? = nil
    /// 金色描边
    var ringed: Bool = true

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius ?? size / 2, style: .continuous)
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                gradient ?? PeerPalette.gradient(for: seed)
                Image(systemName: symbol)
                    .font(.system(size: size * 0.36, weight: .medium))
                    .foregroundColor(.white.opacity(0.94))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(ringed ? Color.glGold.opacity(0.45) : Color.glStroke, lineWidth: 1)
        )
    }
}

// MARK: - 品牌徽标
//
// 草帽 + 金框：宽檐 + 圆顶的剪影在 16px 下依然可辨，比锚更贴合 GrandLine。
// 全部矢量手绘，不依赖 SF Symbols（本机符号库无 anchor）。

struct GLBrandMark: View {
    var size: CGFloat = 34

    var body: some View {
        let r = size * 0.30
        ZStack {
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x1C222A), Color(hex: 0x0B0F14)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))

            RoundedRectangle(cornerRadius: r, style: .continuous)
                .strokeBorder(glHairline, lineWidth: 1)

            StrawHatShape()
                .fill(LinearGradient(colors: [Color(hex: 0xF8E1A4), Color(hex: 0xC79A4C)],
                                     startPoint: .top,
                                     endPoint: .bottom))
                .frame(width: size * 0.70, height: size * 0.62)
        }
        .frame(width: size, height: size)
        .shadow(color: Color.glGold.opacity(0.38), radius: 12, y: 2)
    }
}

/// 草帽剪影：宽檐椭圆 + 圆顶帽冠。两个子路径用 nonzero 填充即为并集。
struct StrawHatShape: Shape {
    var brimHeight: CGFloat = 0.30
    var brimCenterY: CGFloat = 0.66
    var crownTopY: CGFloat = 0.06
    var crownBaseY: CGFloat = 0.62
    var crownHalfTop: CGFloat = 0.175
    var crownHalfBase: CGFloat = 0.255

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height

        // 帽檐
        let brimH = h * brimHeight
        p.addEllipse(in: CGRect(x: rect.minX,
                                y: rect.minY + h * brimCenterY - brimH / 2,
                                width: w,
                                height: brimH))

        // 帽冠
        let cx = rect.midX
        let baseY = rect.minY + h * crownBaseY
        let topY = rect.minY + h * crownTopY
        let shoulder = topY + h * 0.14
        p.move(to: CGPoint(x: cx - w * crownHalfBase, y: baseY))
        p.addLine(to: CGPoint(x: cx - w * crownHalfTop, y: shoulder))
        p.addQuadCurve(to: CGPoint(x: cx + w * crownHalfTop, y: shoulder),
                       control: CGPoint(x: cx, y: topY - h * 0.05))
        p.addLine(to: CGPoint(x: cx + w * crownHalfBase, y: baseY))
        p.closeSubpath()

        return p
    }
}

/// 菜单栏用的模板图（黑色剪影，isTemplate 由系统着色）
enum StrawHatGlyph {
    static func image(size: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        NSColor.black.setFill()
        StrawHatShape()
            .path(in: CGRect(x: 0, y: 0, width: size, height: size))
            .fill()
        img.unlockFocus()
        img.isTemplate = true
        return img
    }
}

/// 手绘锚：顶环 + 竖杆 + 横杆 + 底弧与倒钩。
/// 用折线段近似圆弧，避免 Path.addArc 在翻转坐标系下的方向歧义。
struct AnchorShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let a = min(rect.width, rect.height)
        let cx = rect.midX
        let top = rect.midY + a / 2
        let bottom = rect.midY - a / 2

        // 顶环
        let ringR = a * 0.105
        let ringY = top - ringR
        p.addEllipse(in: CGRect(x: cx - ringR, y: ringY - ringR, width: ringR * 2, height: ringR * 2))

        // 竖杆
        p.move(to: CGPoint(x: cx, y: ringY - ringR))
        p.addLine(to: CGPoint(x: cx, y: bottom))

        // 横杆
        let barY = ringY - ringR - a * 0.14
        p.move(to: CGPoint(x: cx - a * 0.175, y: barY))
        p.addLine(to: CGPoint(x: cx + a * 0.175, y: barY))

        // 底弧（锚爪）：中心在 bottom 上方 R 处，从左上尖端扫过最低点到底部
        let R = a * 0.335
        let arcCenterY = bottom - R
        let steps = 28
        for i in 0...steps {
            let t = 155.0 - Double(i) / Double(steps) * 130.0   // 155° → 25°
            let rad = CGFloat(t) * .pi / 180
            let pt = CGPoint(x: cx + R * cos(rad), y: arcCenterY + R * sin(rad))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }

        // 爪尖倒钩
        for side in [-1.0, 1.0] {
            let rad = (side < 0 ? CGFloat(155) : CGFloat(25)) * .pi / 180
            let tipX = cx + R * cos(rad)
            let tipY = arcCenterY + R * sin(rad)
            p.move(to: CGPoint(x: tipX, y: tipY))
            p.addLine(to: CGPoint(x: tipX - CGFloat(side) * a * 0.055, y: tipY + a * 0.075))
        }
        return p
    }
}

// MARK: - Background

struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x0C1118), Color.glBackgroundDeep],
                           startPoint: .top,
                           endPoint: .bottom)

            ChartGrid()
                .opacity(0.9)

            // 左上一团极弱的暖光，像航海图上被灯照到的角落
            Circle()
                .fill(Color.glGold.opacity(0.070))
                .frame(width: 560, height: 560)
                .blur(radius: 150)
                .offset(x: -300, y: -240)

            // 右下一团冷海光，压住整体暖调
            Circle()
                .fill(Color(hex: 0x2C4A55).opacity(0.12))
                .frame(width: 500, height: 500)
                .blur(radius: 150)
                .offset(x: 340, y: 260)

            // 暗角（收窄，只压最外圈）
            RadialGradient(colors: [.clear, Color.black.opacity(0.24)],
                           center: .center,
                           startRadius: 320,
                           endRadius: 660)

            // 顶沿一道极细金线
            LinearGradient(colors: [.clear, Color.glGold.opacity(0.35), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .ignoresSafeArea()
    }
}

/// 海图经纬网：极低透明度的金线，只做质感，不抢内容
private struct ChartGrid: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 88
            var grid = Path()

            var x: CGFloat = 0
            while x <= size.width {
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y: CGFloat = 0
            while y <= size.height {
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            ctx.stroke(grid, with: .color(Color.glGold.opacity(0.030)), lineWidth: 0.75)

            // 每隔四格加深一条，模仿主经纬线
            var major = Path()
            var mx: CGFloat = 0
            var i = 0
            while mx <= size.width {
                if i % 4 == 0 {
                    major.move(to: CGPoint(x: mx, y: 0))
                    major.addLine(to: CGPoint(x: mx, y: size.height))
                }
                mx += step; i += 1
            }
            var my: CGFloat = 0
            var j = 0
            while my <= size.height {
                if j % 4 == 0 {
                    major.move(to: CGPoint(x: 0, y: my))
                    major.addLine(to: CGPoint(x: size.width, y: my))
                }
                my += step; j += 1
            }
            ctx.stroke(major, with: .color(Color.glGold.opacity(0.055)), lineWidth: 0.9)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 通用控件

struct IconButton: View {
    let systemName: String
    var size: CGFloat = 13
    var tint: Color = .glTextDim
    var action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundColor(hover ? .glGoldBright : tint)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(hover ? Color.glGold.opacity(0.16) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct GhostButton: View {
    let title: String
    var systemImage: String? = nil
    var action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 9.5, weight: .semibold))
                }
                Text(title).font(GLFont.text(11, .medium))
            }
            .foregroundColor(hover ? .glGoldBright : .glTextDim)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hover ? Color.glGold.opacity(0.15) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - 航路进度条
//
// 虚线航路 + 金色实线推进 + 船头小三角，替换普通进度条。

struct SlimProgressBar: View {
    var progress: Double
    var tint: AnyShapeStyle = AnyShapeStyle(glAccentGradient)
    var height: CGFloat = 4
    /// 是否显示船头
    var ship: Bool = true

    private var barHeight: CGFloat { max(height, 8) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let filled = max(0, min(1, progress)) * w

            ZStack(alignment: .leading) {
                // 航路
                Path { p in
                    p.move(to: CGPoint(x: 0, y: barHeight / 2))
                    p.addLine(to: CGPoint(x: w, y: barHeight / 2))
                }
                .stroke(Color.glGold.opacity(0.32),
                        style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2.5, 3.5]))

                Capsule()
                    .fill(tint)
                    .frame(width: filled, height: max(2, height))

                if ship && filled > 2 {
                    Triangle()
                        .fill(tint)
                        .frame(width: 7, height: 8)
                        .offset(x: filled - 3.5, y: (barHeight - max(2, height)) / 2)
                }
            }
            .frame(height: barHeight)
        }
        .frame(height: barHeight)
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - 海图卡片
//
// 圆角底 + 内缩金细线 + 四角短角标，像海图图幅的边框。

struct CornerMarks: Shape {
    var length: CGFloat = 10
    var inset: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = rect.insetBy(dx: inset, dy: inset)
        let l = length

        // 左上
        p.move(to: CGPoint(x: r.minX, y: r.minY + l))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
        // 右上
        p.move(to: CGPoint(x: r.maxX - l, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + l))
        // 右下
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - l))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - l, y: r.maxY))
        // 左下
        p.move(to: CGPoint(x: r.minX + l, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - l))
        return p
    }
}

struct ChartPanel: ViewModifier {
    var radius: CGFloat = 16
    var targeted: Bool = false
    var highlighted: Bool = false
    var cornerMarks: Bool = true

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(targeted ? Color.glGold.opacity(0.14) : Color.glSurface)

                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(LinearGradient(colors: [Color(hex: 0xE8D9B8, alpha: highlighted ? 0.070 : 0.030), .clear],
                                             startPoint: .top,
                                             endPoint: .bottom))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(targeted ? Color.glGold.opacity(0.85) : Color.glStrokeSoft, lineWidth: 1)
            )
            .overlay {
                if cornerMarks {
                    CornerMarks(length: 10, inset: 5)
                        .stroke(targeted ? Color.glGold : Color.glGold.opacity(0.40),
                                lineWidth: 1.1)
                }
            }
    }
}

extension View {
    func chartPanel(radius: CGFloat = 16,
                    targeted: Bool = false,
                    highlighted: Bool = false,
                    cornerMarks: Bool = true) -> some View {
        modifier(ChartPanel(radius: radius,
                            targeted: targeted,
                            highlighted: highlighted,
                            cornerMarks: cornerMarks))
    }

    /// 分区标题：衬线 + 大字距的小写字
    func glSectionStyle() -> some View {
        self.font(GLFont.display(10, .semibold))
            .tracking(1.7)
            .foregroundColor(Color.glTextDim.opacity(0.9))
    }
}

// MARK: - 船型徽记
//
// 一台设备 = 一条船。按 deviceID 稳定取型，和 PeerPalette 取色同一套哈希，
// 保证同一台 Mac 永远显示同一条船。六型剪影各有辨识点：
// sloop 三角帆快船 / merry 羊头帆船 / sunny 狮鬃炮舰 /
// galleon 三桅大帆船 / whale 鲸首海贼船 / submerge 潜水艇

enum ShipKind: Int, CaseIterable {
    case sloop = 0
    case merry = 1
    case sunny = 2
    case galleon = 3
    case whale = 4
    case submerge = 5

    static func kind(for id: String) -> ShipKind {
        var h = 5381
        for u in id.unicodeScalars {
            h = ((h &* 33) &+ Int(u.value)) & 0x7FFF_FFFF
        }
        return ShipKind(rawValue: h % ShipKind.allCases.count) ?? .sloop
    }
}

struct ShipGlyph: Shape {
    var kind: ShipKind = .sloop

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let s = min(rect.width, rect.height) / 24
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * s, y: rect.minY + y * s)
        }
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: rect.minX + x * s, y: rect.minY + y * s, width: w * s, height: h * s)
        }

        // 船体（共用）：船艏朝右
        func hull(_ front: CGFloat) {
            p.move(to: pt(2.2, 14.4))
            p.addQuadCurve(to: pt(front, 14.4), control: pt((2.2 + front) / 2, 20.8))
            p.addQuadCurve(to: pt(2.2, 14.4), control: pt((2.2 + front) / 2, 13.5))
        }

        switch kind {
        case .sloop:
            hull(21.6)
            p.addRect(box(11.3, 3.4, 1.3, 11.2))                 // 桅杆
            p.move(to: pt(12.9, 4.4))                            // 主帆
            p.addLine(to: pt(19.6, 13.6))
            p.addLine(to: pt(12.9, 13.6))
            p.closeSubpath()
            p.move(to: pt(11.1, 6.4))                            // 前帆
            p.addLine(to: pt(5.6, 13.6))
            p.addLine(to: pt(11.1, 13.6))
            p.closeSubpath()

        case .merry:
            hull(20.0)
            p.addRect(box(9.9, 4.4, 1.3, 10.2))                  // 桅杆
            p.addRect(box(5.4, 5.2, 9.0, 6.6))                   // 方帆
            p.addEllipse(in: box(16.6, 8.2, 6.2, 6.2))           // 羊头船首
            p.addEllipse(in: box(15.4, 5.0, 2.8, 2.8))           // 左角
            p.addEllipse(in: box(21.0, 5.0, 2.8, 2.8))           // 右角
            p.move(to: pt(10.5, 2.2))                            // 桅顶小旗
            p.addLine(to: pt(14.4, 3.4))
            p.addLine(to: pt(10.5, 4.6))
            p.closeSubpath()

        case .sunny:
            hull(19.4)
            p.addRect(box(5.0, 4.8, 1.2, 9.8))                   // 前桅
            p.addRect(box(10.4, 3.6, 1.2, 11.0))                 // 主桅
            p.move(to: pt(11.8, 4.6))                            // 主帆
            p.addLine(to: pt(17.4, 13.6))
            p.addLine(to: pt(11.8, 13.6))
            p.closeSubpath()
            p.addRect(box(6.4, 6.0, 3.6, 5.4))                   // 前帆

            // 狮鬃：12 齿星形，读作带鬃毛的圆头
            let c = pt(20.6, 11.0)
            let outer = 4.2 * s
            let inner = 2.9 * s
            for i in 0..<24 {
                let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 12
                let r = i % 2 == 0 ? outer : inner
                let q = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
                if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
            }
            p.closeSubpath()

        case .galleon:
            hull(22.4)
            p.addRect(box(1.8, 11.2, 3.6, 3.4))                  // 尉楼（艉部高台）
            p.move(to: pt(21.6, 13.8))                           // 艏斜桁
            p.addLine(to: pt(23.7, 11.0))
            p.addLine(to: pt(22.5, 11.2))
            p.closeSubpath()
            p.addRect(box(6.0, 4.2, 1.1, 10.4))                  // 前桅
            p.addRect(box(11.2, 3.0, 1.1, 11.6))                 // 主桅
            p.addRect(box(16.4, 4.2, 1.1, 10.4))                 // 后桅
            p.addRect(box(3.4, 5.4, 5.4, 6.0))                   // 前方帆
            p.addRect(box(9.0, 4.2, 5.6, 6.8))                   // 主方帆
            p.addRect(box(14.4, 5.4, 5.2, 6.0))                  // 后方帆

        case .whale:
            hull(20.4)
            p.addEllipse(in: box(17.2, 8.0, 6.0, 5.8))           // 鲸首船艏
            p.move(to: pt(19.0, 8.4))                            // 尾鳍上翘
            p.addLine(to: pt(20.6, 3.2))
            p.addLine(to: pt(21.5, 8.0))
            p.closeSubpath()
            p.move(to: pt(21.2, 8.2))
            p.addLine(to: pt(23.2, 4.0))
            p.addLine(to: pt(23.5, 8.8))
            p.closeSubpath()
            p.addRect(box(8.6, 3.8, 1.2, 10.6))                  // 桅杆
            p.addRect(box(5.2, 5.4, 7.0, 6.4))                   // 方帆

        case .submerge:
            hull(21.8)
            p.addRect(box(10.4, 10.8, 4.6, 3.8))                 // 指挥塔
            p.addRect(box(12.2, 7.6, 0.8, 3.4))                  // 潜望镜杆
            p.addRect(box(12.2, 7.6, 2.8, 0.9))                  // 潜望镜头
            p.addEllipse(in: box(19.9, 15.4, 2.0, 2.0))          // 艏灯
            p.addEllipse(in: box(0.5, 13.2, 1.2, 1.2))           // 艉流气泡
            p.addEllipse(in: box(1.9, 11.7, 0.9, 0.9))
        }

        return p
    }
}

// MARK: - 海浪
//
// 正弦波填充形，phase 可动画（每推进 1.0 平移一个波长，
// 累计偶数周期后回到同相位，循环无缝）。

struct WaveShape: Shape {
    var phase: CGFloat = 0
    var amp: CGFloat = 0.20
    var waves: CGFloat = 1.6

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let steps = 28
        var first = true
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = rect.minX + t * rect.width
            let y = rect.midY - sin((t * waves + phase) * 2 * .pi) * rect.height * amp * 0.5
            let q = CGPoint(x: x, y: y)
            if first { p.move(to: q); first = false } else { p.addLine(to: q) }
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - 船只陈列
//
// 设备卡里的「模型船」：船体按设备 ID 取型取色，船身刻设备名铭牌，
// 艏艏微波两层错相漂移，整船带轻微起伏与摇摆。

struct ShipShowcase: View {
    /// 设备 ID：决定船型与配色
    let seed: String
    /// 刻在船身的名字；为空则不出铭牌
    var name: String = ""
    /// 场景宽度（船体即此宽度）
    var size: CGFloat = 96
    /// 是否刻铭牌
    var engraved: Bool = true
    /// 是否跑常驻动画。设备上百台时网格里会同时挂着大量无限动画，
    /// 滚动过程反复创建销毁，关掉可显著降低 CPU 占用。
    var animated: Bool = true

    @State private var bob = false
    @State private var wavePhase: CGFloat = 0
    @State private var wavePhase2: CGFloat = 0.5

    private var kind: ShipKind { ShipKind.kind(for: seed) }
    private var gradient: LinearGradient { PeerPalette.gradient(for: seed) }

    var body: some View {
        ZStack {
            // 远浪：更平、更淡、更慢
            WaveShape(phase: wavePhase2, amp: 0.12, waves: 1.2)
                .fill(Color(hex: 0x35566A).opacity(0.34))
                .frame(width: size, height: size * 0.22)
                .offset(y: size * 0.16)

            ship

            // 近浪：盖住船底一点，像浮在海面
            WaveShape(phase: wavePhase, amp: 0.20, waves: 1.6)
                .fill(LinearGradient(colors: [Color.glSea.opacity(0.26), Color.glSea.opacity(0.06)],
                                     startPoint: .top,
                                     endPoint: .bottom))
                .frame(width: size * 1.04, height: size * 0.26)
                .offset(y: size * 0.185)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard animated else { return }
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
                bob = true
            }
            withAnimation(.linear(duration: 5.4).repeatForever(autoreverses: false)) {
                wavePhase = 2
            }
            withAnimation(.linear(duration: 8.2).repeatForever(autoreverses: false)) {
                wavePhase2 = 2.5
            }
        }
    }

    private var ship: some View {
        ShipGlyph(kind: kind)
            .fill(gradient)
            .frame(width: size, height: size)
            .overlay(alignment: .bottom) {
                if engraved, !name.isEmpty {
                    hullPlate.padding(.bottom, size * 0.150)
                }
            }
            .offset(y: bob ? -2.4 : 1.6)
            .rotationEffect(.degrees(bob ? -1.5 : 1.1),
                            anchor: UnitPoint(x: 0.5, y: 0.8))
            .shadow(color: .black.opacity(0.28), radius: 3, y: 2)
    }

    /// 船身铭牌：深底 + 刻金字，长名自动缩小
    private var hullPlate: some View {
        Text(name)
            .font(GLFont.mono(6, .semibold))
            .tracking(-0.2)
            .minimumScaleFactor(0.25)
            .lineLimit(1)
            .foregroundColor(Color(hex: 0xF2E3BC))
            .padding(.horizontal, 3)
            .padding(.vertical, 0.5)
            .frame(maxWidth: size * 0.46)
            .background(RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color(hex: 0x0B0D10, alpha: 0.58)))
    }
}

// MARK: - 蜡封
//
// 传输抵达时盖一枚印记，只在完成态出现。

struct WaxSeal: View {
    var size: CGFloat = 24
    var rotate: Double = -7

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0xA74B3D), Color(hex: 0x6B2820)],
                                     center: .init(x: 0.34, y: 0.28),
                                     startRadius: 1,
                                     endRadius: size * 0.62))
            Circle()
                .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.8)
                .padding(size * 0.11)
            AnchorShape()
                .stroke(Color.white.opacity(0.62),
                        style: StrokeStyle(lineWidth: size * 0.055, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.40, height: size * 0.44)
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(rotate))
        .shadow(color: .black.opacity(0.40), radius: 3, y: 1)
    }
}

// MARK: - 悬赏令边框
//
// 双线金框 + 四角花饰：接收确认弹窗用，像一张贴到船舷上的告示。

struct PosterFlourish: Shape {
    var length: CGFloat = 12
    var inset: CGFloat = 4

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = rect.insetBy(dx: inset, dy: inset)
        let l = length

        // 四角的斜向小花饰
        p.move(to: CGPoint(x: r.minX, y: r.minY + l))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
        p.move(to: CGPoint(x: r.minX + 3, y: r.minY + 3))
        p.addLine(to: CGPoint(x: r.minX + l * 0.7, y: r.minY + l * 0.7))

        p.move(to: CGPoint(x: r.maxX - l, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + l))
        p.move(to: CGPoint(x: r.maxX - 3, y: r.minY + 3))
        p.addLine(to: CGPoint(x: r.maxX - l * 0.7, y: r.minY + l * 0.7))

        p.move(to: CGPoint(x: r.maxX, y: r.maxY - l))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - l, y: r.maxY))
        p.move(to: CGPoint(x: r.maxX - 3, y: r.maxY - 3))
        p.addLine(to: CGPoint(x: r.maxX - l * 0.7, y: r.maxY - l * 0.7))

        p.move(to: CGPoint(x: r.minX + l, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - l))
        p.move(to: CGPoint(x: r.minX + 3, y: r.maxY - 3))
        p.addLine(to: CGPoint(x: r.minX + l * 0.7, y: r.maxY - l * 0.7))
        return p
    }
}

struct PosterFrame: ViewModifier {
    var radius: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.glGold.opacity(0.42), lineWidth: 1.4)
                    .padding(7)
            )
            .overlay(
                RoundedRectangle(cornerRadius: max(2, radius - 4), style: .continuous)
                    .strokeBorder(Color.glGold.opacity(0.16), lineWidth: 0.8)
                    .padding(12)
            )
            .overlay(
                PosterFlourish(length: 11, inset: 12)
                    .stroke(Color.glGold.opacity(0.40), lineWidth: 1)
            )
    }
}

extension View {
    func posterFrame(radius: CGFloat = 10) -> some View {
        modifier(PosterFrame(radius: radius))
    }
}

// MARK: - 金色开关
//
// 系统 NSSwitch 在本机不吃自定义 tint（始终白色），自绘一个与主题一致的迷你开关。

struct GLSwitch: View {
    @Binding var isOn: Bool

    @State private var hover = false

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) { isOn.toggle() }
        } label: {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(isOn ? AnyShapeStyle(glAccentGradient)
                               : AnyShapeStyle(Color.white.opacity(hover ? 0.16 : 0.12)))
                    .overlay(
                        Capsule().strokeBorder(Color.glGold.opacity(isOn ? 0.25 : 0.10), lineWidth: 0.8)
                    )

                Circle()
                    .fill(Color(hex: 0xF2EDE2))
                    .frame(width: 13, height: 13)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .offset(x: isOn ? 19 : 3)
            }
            .frame(width: 35, height: 19)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - 毛玻璃底座

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
