// 把图标原图规范化为 macOS 图标并生成 AppIcon.icns
// 用法：swift tools/make-icon.swift assets/icon-source.png assets/AppIcon.icns
//
// 处理：按 alpha 找到图标主体 → 缩放到 Apple 图标网格（1024 画布中 824×824 主体，四周 100px）
//      → 圆角矩形裁切（四角透明）→ 加柔和投影 → 导出各尺寸 → iconutil 打包 .icns
import Cocoa

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: make-icon <source.png> <out.icns>"); exit(1) }
let srcURL = URL(fileURLWithPath: args[1]), outURL = URL(fileURLWithPath: args[2])

guard let isrc = CGImageSourceCreateWithURL(srcURL as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(isrc, 0, nil) else { print("cannot read \(srcURL.path)"); exit(1) }
let w = img.width, h = img.height
var px = [UInt8](repeating: 0, count: w * h * 4)
let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
let rctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: rgb,
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
rctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

// 1. 主体边界（alpha > 50%）；缓冲区第 0 行是图像顶部
var minX = w, maxX = 0, minY = h, maxY = 0
for y in 0..<h { for x in 0..<w where px[(y * w + x) * 4 + 3] > 128 {
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
} }
let side = max(maxX - minX + 1, maxY - minY + 1)
let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
// CG 坐标原点在左下：把「距顶部」换算成「距底部」
let crop = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
print("主体边界 x:\(minX)-\(maxX) y:\(minY)-\(maxY) → 裁切 \(Int(crop.width))px")
guard let body = img.cropping(to: crop) else { print("crop failed"); exit(1) }

// 2. 绘制 1024 母版
func render(_ size: Int) -> CGImage {
    let s = CGFloat(size) / 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: rgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let rect = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = CGPath(roundedRect: rect, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    // 投影（大尺寸才画，小尺寸保持清爽）
    if size >= 64 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s,
                      color: CGColor(gray: 0, alpha: 0.28))
        ctx.addPath(path); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(rect)       // 垫底，避免原图边缘半透明
    ctx.draw(body, in: rect.insetBy(dx: -3 * s, dy: -3 * s))          // 略放大，裁掉原图自带的圆角边缘
    ctx.restoreGState()
    // 细描边，增强在浅色背景上的轮廓
    ctx.addPath(path); ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.08)); ctx.setLineWidth(max(1, 2 * s)); ctx.strokePath()
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

// 3. iconset → icns
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    writePNG(render(base), tmp.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(render(base * 2), tmp.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let master = outURL.deletingLastPathComponent().appendingPathComponent("AppIcon-1024.png")
writePNG(render(1024), master)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", tmp.path, "-o", outURL.path]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: tmp)
print(p.terminationStatus == 0 ? "✅ \(outURL.path)\n✅ \(master.path)" : "iconutil failed")
