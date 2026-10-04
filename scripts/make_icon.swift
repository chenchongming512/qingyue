// 生成「轻阅」App 图标：渐变圆角方块 + 白纸折角 + 高亮笔触
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no ctx") }

// 底板：圆角方块
let tile = CGRect(x: 112, y: 112, width: 800, height: 800)
let radius: CGFloat = 180
let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

// 投影
ctx.saveGState()
ctx.addPath(tilePath)
ctx.setShadow(offset: CGSize(width: 0, height: -30), blur: 70, color: NSColor.black.withAlphaComponent(0.30).cgColor)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

// 渐变底
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let colors = [NSColor(calibratedRed: 0.36, green: 0.31, blue: 0.98, alpha: 1).cgColor,
              NSColor(calibratedRed: 0.60, green: 0.38, blue: 0.98, alpha: 1).cgColor] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: tile.midX, y: tile.maxY), end: CGPoint(x: tile.midX, y: tile.minY), options: [])
ctx.restoreGState()

// 白纸（带折角）
let pageW: CGFloat = 420, pageH: CGFloat = 540
let pageX = tile.midX - pageW / 2 - 16
let pageY = tile.midY - pageH / 2 + 8
let fold: CGFloat = 92
let pagePath = CGMutablePath()
pagePath.move(to: CGPoint(x: pageX, y: pageY))
pagePath.addLine(to: CGPoint(x: pageX, y: pageY + pageH - fold))
pagePath.addLine(to: CGPoint(x: pageX + fold, y: pageY + pageH))
pagePath.addLine(to: CGPoint(x: pageX + pageW, y: pageY + pageH))
pagePath.addLine(to: CGPoint(x: pageX + pageW, y: pageY))
pagePath.closeSubpath()
ctx.saveGState()
ctx.addPath(pagePath)
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: NSColor.black.withAlphaComponent(0.28).cgColor)
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillPath()
ctx.restoreGState()

// 折角阴影面
ctx.saveGState()
let foldPath = CGMutablePath()
foldPath.move(to: CGPoint(x: pageX, y: pageY + pageH - fold))
foldPath.addLine(to: CGPoint(x: pageX + fold, y: pageY + pageH))
foldPath.addLine(to: CGPoint(x: pageX, y: pageY + pageH))
foldPath.closeSubpath()
ctx.addPath(foldPath)
ctx.setFillColor(NSColor(calibratedWhite: 0.84, alpha: 1).cgColor)
ctx.fillPath()
ctx.restoreGState()

// 文字行 + 高亮笔触
let lineX = pageX + 55
let lineW = pageW - 110
let lineYs: [CGFloat] = [pageY + pageH - 175, pageY + pageH - 248, pageY + pageH - 321, pageY + pageH - 394]
ctx.saveGState()
let hRect = CGRect(x: lineX - 10, y: lineYs[1] - 13, width: lineW * 0.72 + 20, height: 40)
ctx.addPath(CGPath(roundedRect: hRect, cornerWidth: 9, cornerHeight: 9, transform: nil))
ctx.setFillColor(NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.22, alpha: 0.95).cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.setFillColor(NSColor(calibratedWhite: 0.76, alpha: 1).cgColor)
for (i, y) in lineYs.enumerated() {
    let w = i == 1 ? lineW * 0.72 : (i == 3 ? lineW * 0.58 : lineW)
    let r = CGRect(x: lineX, y: y - 7, width: w, height: 15)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 7.5, cornerHeight: 7.5, transform: nil))
    ctx.fillPath()
}

img.unlockFocus()

// 输出 iconset 全尺寸
let specs: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
let iconsetDir = outDir + "/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)
for (name, px) in specs {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: iconsetDir + "/" + name))
}
print("icon ok")
