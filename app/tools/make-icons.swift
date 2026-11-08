// 生成 AppIcon.icns 与菜单栏模板图。
//
// 输入是两张 2048x2048 的图形素材（同一枚字形，一蓝一白）。原始文件有两个
// 必须先处理掉的问题：
//   1. 背景不是真透明——有大量低 alpha 的压缩噪点，最高到 32+，
//      直接拿来当模板图会让菜单栏图标带一圈脏边。
//   2. 字形只占画布 57% x 82%，不处理就贴上去，Dock 里会显得又偏又小。
//
// 所以流程是：取最大连通域去掉噪点 -> 按字形真实包围盒裁切 -> 重新排布到
// macOS 图标网格（824x824 圆角方形居中于 1024 画布）-> 导出 iconset。
//
// 用法：
//   swift make-icons.swift render <blue.png> <white.png> <outdir>   生成 AppIcon.icns 与菜单栏 PNG
//   swift make-icons.swift variants <blue.png> <white.png> <out.png>  生成方案对比图
import AppKit
import Foundation

// MARK: - 读图

struct Bitmap {
    var w: Int
    var h: Int
    var rgba: [UInt8]   // non-premultiplied
}

func loadBitmap(_ path: String) -> Bitmap? {
    guard let img = NSImage(contentsOfFile: path),
          let tiff = img.tiffRepresentation,
          let rep0 = NSBitmapImageRep(data: tiff) else { return nil }
    let w = rep0.pixelsWide, h = rep0.pixelsHigh
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let cg = rep0.cgImage else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    // 还原成非预乘，避免半透明边缘的颜色被压暗
    for i in stride(from: 0, to: buf.count, by: 4) {
        let a = Int(buf[i + 3])
        if a > 0 && a < 255 {
            for k in 0..<3 {
                buf[i + k] = UInt8(min(255, Int(buf[i + k]) * 255 / a))
            }
        }
    }
    return Bitmap(w: w, h: h, rgba: buf)
}

// MARK: - 去噪 + 裁切

/// 只保留足够大的连通区域，向外扩几像素兜住抗锯齿边缘，其余一律清零。
/// 素材是 AI 出图，背景散布着 alpha 最高 32+ 的噪点，阈值法清不干净。
///
/// 注意：字形本身是「闪电 + 外圈」两部分，它们在像素上并不相连（圈有两处
/// 缺口）。只取最大连通域会把外圈整条丢掉，所以这里保留所有面积达到最大值
/// 一定比例的连通域。
func cleanAlpha(_ src: Bitmap) -> (alpha: [UInt8], box: (x0: Int, y0: Int, x1: Int, y1: Int)) {
    let w = src.w, h = src.h
    var raw = [UInt8](repeating: 0, count: w * h)
    for i in 0..<(w * h) { raw[i] = src.rgba[i * 4 + 3] }

    // 1. 粗分：alpha >= 96 视为字形内部
    var label = [Int32](repeating: -1, count: w * h)
    var sizes: [Int] = []
    var next: Int32 = 0
    var queue = [Int32]()
    queue.reserveCapacity(1 << 16)

    for start in 0..<(w * h) where label[start] < 0 && raw[start] >= 96 {
        let id = next
        next += 1
        var size = 0
        queue.removeAll(keepingCapacity: true)
        queue.append(Int32(start))
        label[start] = id
        var head = 0
        while head < queue.count {
            let p = Int(queue[head]); head += 1
            size += 1
            let x = p % w, y = p / w
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                let q = ny * w + nx
                if label[q] < 0 && raw[q] >= 96 {
                    label[q] = id
                    queue.append(Int32(q))
                }
            }
        }
        sizes.append(size)
    }

    let largest = sizes.max() ?? 0
    // 外圈面积约为闪电的 1/2 左右，阈值取 3% 足够把两者都留下，
    // 又能过滤掉噪声形成的小碎块。
    let threshold = max(200, Int(Double(largest) * 0.03))
    var keepIDs = Set<Int32>()
    for (i, s) in sizes.enumerated() where s >= threshold {
        keepIDs.insert(Int32(i))
    }

    // 2. 膨胀 3px：把保留区域周边的抗锯齿像素包进来
    var keep = [Bool](repeating: false, count: w * h)
    for i in 0..<(w * h) where keepIDs.contains(label[i]) { keep[i] = true }
    for _ in 0..<3 {
        var grown = keep
        for y in 0..<h {
            for x in 0..<w where !keep[y * w + x] {
                var hit = false
                for dy in -1...1 where !hit {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                        if keep[ny * w + nx] { hit = true; break }
                    }
                }
                if hit { grown[y * w + x] = true }
            }
        }
        keep = grown
    }

    var alpha = [UInt8](repeating: 0, count: w * h)
    var x0 = w, y0 = h, x1 = -1, y1 = -1
    for y in 0..<h {
        for x in 0..<w {
            let i = y * w + x
            guard keep[i] else { continue }
            let a = raw[i]
            // 低 alpha 的残余噪点再压一次
            alpha[i] = a <= 12 ? 0 : UInt8(min(255, Int(a - 12) * 255 / 243))
            if alpha[i] > 0 {
                if x < x0 { x0 = x }; if x > x1 { x1 = x }
                if y < y0 { y0 = y }; if y > y1 { y1 = y }
            }
        }
    }
    return (alpha, (x0, y0, x1, y1))
}

// MARK: - 遮罩

/// 把 alpha 裁到包围盒，做成灰度遮罩图（之后按任意尺寸铺开当 clip 用）。
func maskImage(alpha: [UInt8], w: Int, h: Int,
               box: (x0: Int, y0: Int, x1: Int, y1: Int)) -> (CGImage, Int, Int)? {
    let cw = box.x1 - box.x0 + 1
    let ch = box.y1 - box.y0 + 1
    guard cw > 0, ch > 0 else { return nil }
    var out = [UInt8](repeating: 0, count: cw * ch)
    for y in 0..<ch {
        for x in 0..<cw {
            out[y * cw + x] = alpha[(y + box.y0) * w + (x + box.x0)]
        }
    }
    guard let provider = CGDataProvider(data: Data(out) as CFData),
          let img = CGImage(width: cw, height: ch, bitsPerComponent: 8, bitsPerPixel: 8,
                            bytesPerRow: cw, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                            decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    else { return nil }
    return (img, cw, ch)
}

// MARK: - 绘制

func makeContext(_ w: Int, _ h: Int) -> CGContext? {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
}

/// 把遮罩画成指定颜色的图形。遮罩行序是自上而下，CGContext 是自下而上，
/// 所以先翻一次坐标系，否则字形会上下颠倒。
func drawGlyph(_ ctx: CGContext, mask: CGImage, mw: Int, mh: Int,
               color: NSColor, in rect: CGRect) {
    ctx.saveGState()
    ctx.translateBy(x: 0, y: rect.midY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.translateBy(x: 0, y: -rect.midY)
    ctx.clip(to: rect, mask: mask)
    ctx.setFillColor(color.cgColor)
    ctx.fill(rect)
    ctx.restoreGState()
    _ = (mw, mh)
}

/// Apple 图标网格用的超椭圆（连续圆角）。NSBezierPath 只有普通圆弧，
/// 画出来的圆角比系统图标更"方"，肉眼能分辨。
func squirclePath(in rect: CGRect, exponent n: CGFloat = 5.0) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), 2 / n), ct)
        let y = cy + b * copysign(pow(abs(st), 2 / n), st)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// 一张 app 图标草图。`background` 为 nil 时只画字形（不加圆角底板）。
struct AppIconSpec {
    var background: [NSColor]?      // 从上到下的渐变色；nil = 透明
    var glyphColor: NSColor
    var glyphHeightRatio: CGFloat   // 字形高 / 圆角方高
    var withShadow: Bool
}

func renderAppIcon(spec: AppIconSpec, mask: CGImage, mw: Int, mh: Int, side: Int) -> NSImage? {
    guard let ctx = makeContext(side, side) else { return nil }
    let s = CGFloat(side)

    // Apple 网格：1024 画布里放 824 的圆角方，四周留白给阴影
    let pad = s * (100.0 / 1024.0)
    let box = CGRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)

    if let bg = spec.background {
        let path = squirclePath(in: box)
        ctx.saveGState()
        if spec.withShadow {
            // 阴影随尺寸等比缩小，否则 16px 的图标会被糊成一团
            let scale = s / 1024.0
            ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale),
                          blur: 26 * scale,
                          color: NSColor.black.withAlphaComponent(0.28).cgColor)
        }
        ctx.addPath(path)
        ctx.setFillColor(bg[0].cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        if bg.count > 1 {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: bg.map { $0.cgColor } as CFArray,
                                  locations: [0, 1])!
            ctx.drawLinearGradient(grad,
                                   start: CGPoint(x: 0, y: box.maxY),
                                   end: CGPoint(x: 0, y: box.minY),
                                   options: [])
            ctx.restoreGState()
        }

        // 顶部高光：必须是渐隐的，直接填一块半透明白会在中线上留下硬边。
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let hl = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: [NSColor.white.withAlphaComponent(0.75).cgColor,
                                     NSColor.white.withAlphaComponent(0.0).cgColor] as CFArray,
                            locations: [0, 1])!
        ctx.drawLinearGradient(hl,
                               start: CGPoint(x: 0, y: box.maxY),
                               end: CGPoint(x: 0, y: box.midY),
                               options: [])
        ctx.restoreGState()
    }

    // 字形按高度对齐，宽度按素材原始比例
    let aspect = CGFloat(mw) / CGFloat(mh)
    let gh = box.height * spec.glyphHeightRatio
    let gw = gh * aspect
    let rect = CGRect(x: box.midX - gw / 2,
                      y: box.midY - gh / 2,
                      width: gw, height: gh)
    drawGlyph(ctx, mask: mask, mw: mw, mh: mh, color: spec.glyphColor, in: rect)

    guard let img = ctx.makeImage() else { return nil }
    return NSImage(cgImage: img, size: NSSize(width: side, height: side))
}

// MARK: - 落盘

func pngData(_ img: NSImage) -> Data? {
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
}

func writePNG(_ img: NSImage, to url: URL) throws {
    guard let data = pngData(img) else { throw NSError(domain: "icon", code: 1) }
    try data.write(to: url)
}

// MARK: - 主流程

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : ""

func preparedMask(_ path: String) -> (CGImage, Int, Int, Double)? {
    guard let bmp = loadBitmap(path) else { print("读不到 \(path)"); return nil }
    let (alpha, box) = cleanAlpha(bmp)
    guard let (mask, mw, mh) = maskImage(alpha: alpha, w: bmp.w, h: bmp.h, box: box) else {
        print("遮罩生成失败 \(path)"); return nil
    }
    print("  \(path.split(separator: "/").last!) 字形 \(mw)x\(mh) 宽高比 \(String(format: "%.3f", Double(mw) / Double(mh)))")
    return (mask, mw, mh, Double(mw) / Double(mh))
}

switch mode {
case "render":
    guard args.count >= 5 else { print("用法: render <blue> <white> <outdir>"); exit(2) }
    let bluePath = args[2], whitePath = args[3]
    let outDir = URL(fileURLWithPath: args[4])
    let resDir = outDir.appendingPathComponent("Resources")
    try? FileManager.default.createDirectory(at: resDir, withIntermediateDirectories: true)

    print("==> 解析素材")
    guard let blue = preparedMask(bluePath) else { exit(1) }

    // 主体图标：浅色圆角底板 + 蓝色字形。蓝色是主色，底板只负责让它在
    // Dock 里成为一枚"应用图标"而不是一张贴纸。
    let spec = AppIconSpec(
        background: [NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1),
                     NSColor(srgbRed: 0.914, green: 0.937, blue: 0.980, alpha: 1)],
        glyphColor: NSColor(srgbRed: 36 / 255.0, green: 109 / 255.0, blue: 234 / 255.0, alpha: 1),
        glyphHeightRatio: 0.68,
        withShadow: true
    )

    print("==> 渲染 iconset")
    let iconset = outDir.appendingPathComponent("AppIcon.iconset")
    try? FileManager.default.removeItem(at: iconset)
    try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

    let entries: [(String, Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]
    // 先渲染 1024 母版，再等比降采样——每个尺寸单独渲染会让小图的圆角/笔画走样
    guard let master = renderAppIcon(spec: spec, mask: blue.0, mw: blue.1, mh: blue.2, side: 1024) else {
        print("母版渲染失败"); exit(1)
    }
    for (name, px) in entries {
        let img: NSImage
        if px == 1024 {
            img = master
        } else {
            guard let ctx = makeContext(px, px), let cg = master.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                print("降采样失败 \(name)"); exit(1)
            }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: px, height: px))
            guard let out = ctx.makeImage() else { print("降采样失败 \(name)"); exit(1) }
            img = NSImage(cgImage: out, size: NSSize(width: px, height: px))
        }
        try! writePNG(img, to: iconset.appendingPathComponent("\(name).png"))
        print("    \(name).png \(px)x\(px)")
    }

    print("==> iconutil")
    let icns = resDir.appendingPathComponent("AppIcon.icns")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
    try! p.run(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { print("iconutil 失败"); exit(1) }
    let attrs = (try? FileManager.default.attributesOfItem(atPath: icns.path)) ?? [:]
    let size = (attrs[.size] as? Int) ?? 0
    print("    AppIcon.icns \(size) B")

    // 1024 母版另存一份给 README / docs 用
    try! writePNG(master, to: outDir.appendingPathComponent("icon-1024.png"))

    // 菜单栏图：白色字形 + 透明底。模板图只认 alpha，颜色由系统按明暗主题染，
    // 所以这里必须画成纯白而不是画成"看起来是白的"。
    //
    // 尺寸取字形 14pt + 上下各 1pt 留白 = 16pt 画布。和系统自带图标（电池约
    // 14pt、Wi-Fi 约 14pt）齐平；铺满 18pt 会顶到菜单栏上下边缘、被切掉。
    print("==> 渲染菜单栏模板图")
    guard let white = preparedMask(whitePath) else { exit(1) }
    let glyphPt: CGFloat = 14
    let padPt: CGFloat = 1
    for scale in [1, 2] {
        let gH = Int(glyphPt * CGFloat(scale))
        let gW = Int((glyphPt * CGFloat(white.1) / CGFloat(white.2)).rounded() * CGFloat(scale))
        let pad = Int(padPt * CGFloat(scale))
        let w = gW + pad * 2, h = gH + pad * 2
        guard let ctx = makeContext(w, h) else { exit(1) }
        drawGlyph(ctx, mask: white.0, mw: white.1, mh: white.2,
                  color: .white, in: CGRect(x: pad, y: pad, width: gW, height: gH))
        guard let cg = ctx.makeImage() else { exit(1) }
        let img = NSImage(cgImage: cg, size: NSSize(width: CGFloat(w) / CGFloat(scale),
                                                    height: CGFloat(h) / CGFloat(scale)))
        let name = scale == 1 ? "MenuBarIcon.png" : "MenuBarIcon@2x.png"
        try! writePNG(img, to: resDir.appendingPathComponent(name))
        print("    \(name) \(w)x\(h) px  (\(CGFloat(w) / CGFloat(scale))x\(CGFloat(h) / CGFloat(scale)) pt)")
    }

    // 顺手把旧素材也载入，做一张前后对照
    print("==> 方案对照图")
    let sheet = NSImage(size: NSSize(width: 1400, height: 420))
    sheet.lockFocus()
    NSColor(white: 0.92, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 1400, height: 420).fill()
    let variants: [(String, AppIconSpec)] = [
        ("A 白底+蓝字形（采用）", spec),
        ("B 纯字形无底板", AppIconSpec(background: nil,
                                    glyphColor: spec.glyphColor,
                                    glyphHeightRatio: 0.82, withShadow: false)),
        ("C 蓝底+白字形", AppIconSpec(background: [NSColor(srgbRed: 0.22, green: 0.45, blue: 0.94, alpha: 1),
                                                NSColor(srgbRed: 0.13, green: 0.37, blue: 0.86, alpha: 1)],
                                   glyphColor: .white, glyphHeightRatio: 0.68, withShadow: true)),
    ]
    for (i, v) in variants.enumerated() {
        let x = CGFloat(40 + i * 460)
        if let img = renderAppIcon(spec: v.1, mask: blue.0, mw: blue.1, mh: blue.2, side: 340) {
            img.draw(in: NSRect(x: x, y: 60, width: 340, height: 340))
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17, weight: .medium),
            .foregroundColor: NSColor.black,
        ]
        (v.0 as NSString).draw(at: NSPoint(x: x, y: 26), withAttributes: attrs)
    }
    sheet.unlockFocus()
    try? writePNG(sheet, to: outDir.appendingPathComponent("icon-variants.png"))
    print("    icon-variants.png")

    print("==> 菜单栏实际尺寸预览")
    // 真机菜单栏里图标只有 16pt，任何糊边、断笔在这一步都能看出来。
    let barW: CGFloat = 300, hei: CGFloat = 160
    let bar = NSImage(size: NSSize(width: barW, height: hei))
    bar.lockFocus()
    NSColor(white: 0.97, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: barW, height: hei / 2).fill()
    NSColor(white: 0.11, alpha: 1).setFill()
    NSRect(x: 0, y: hei / 2, width: barW, height: hei / 2).fill()

    if let ctx = NSGraphicsContext.current?.cgContext {
        let gw16 = 16 * CGFloat(white.1) / CGFloat(white.2)
        // 画布 300x160：下半 0..80 是浅色栏，上半 80..160 是深色栏
        // 深色菜单栏 -> 染白；浅色菜单栏 -> 染黑
        drawGlyph(ctx, mask: white.0, mw: white.1, mh: white.2, color: .white,
                  in: CGRect(x: 160, y: 112, width: gw16, height: 16))
        drawGlyph(ctx, mask: white.0, mw: white.1, mh: white.2, color: .black,
                  in: CGRect(x: 160, y: 32, width: gw16, height: 16))
        // 左半：2 倍与 4 倍放大，肉眼查笔画
        drawGlyph(ctx, mask: white.0, mw: white.1, mh: white.2, color: .white,
                  in: CGRect(x: 30, y: 96, width: gw16 * 2, height: 32))
        drawGlyph(ctx, mask: white.0, mw: white.1, mh: white.2, color: .black,
                  in: CGRect(x: 30, y: 16, width: gw16 * 2, height: 32))
        drawGlyph(ctx, mask: white.0, mw: white.1, mh: white.2, color: .white,
                  in: CGRect(x: 90, y: 96, width: gw16 * 3, height: 48))
        drawGlyph(ctx, mask: white.0, mw: white.1, mh: white.2, color: .black,
                  in: CGRect(x: 90, y: 16, width: gw16 * 3, height: 48))
    }
    bar.unlockFocus()
    try? writePNG(bar, to: outDir.appendingPathComponent("menubar-preview.png"))
    print("    menubar-preview.png")

    // Dock / Finder 里的真实观感：把各档实际文件贴到浅灰底上看。
    // 注意 iconset 里没有 icon_64x64.png，64px 那一档叫 icon_32x32@2x.png。
    let shelf = NSImage(size: NSSize(width: 900, height: 220))
    shelf.lockFocus()
    NSColor(white: 0.88, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 900, height: 220).fill()
    let sizeSheet: [(String, String, CGFloat)] = [
        ("icon_128x128.png", "128px", 128),
        ("icon_32x32@2x.png", "64px", 64),
        ("icon_32x32.png", "32px", 32),
        ("icon_16x16.png", "16px", 16),
    ]
    for (i, s) in sizeSheet.enumerated() {
        guard let im = NSImage(contentsOf: iconset.appendingPathComponent(s.0)) else {
            print("⚠️ 缺少 \(s.0)"); continue
        }
        let x = CGFloat(40 + i * 210)
        im.draw(in: NSRect(x: x, y: 60, width: s.2, height: s.2))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.darkGray,
        ]
        (s.1 as NSString).draw(at: NSPoint(x: x, y: 30), withAttributes: attrs)
    }
    shelf.unlockFocus()
    try? writePNG(shelf, to: outDir.appendingPathComponent("icon-sizes.png"))
    print("    icon-sizes.png")
    print("==> 完成")

case "variants":
    print("见 render 模式输出，已内置对照图")
default:
    print("用法: render <blue> <white> <outdir>")
    exit(2)
}
