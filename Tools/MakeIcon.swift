// 生成 Kanade 的应用图标（build.sh 会自动调用）
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Kanade.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let padColors: [NSColor] = [
    NSColor(calibratedRed: 0.27, green: 0.50, blue: 0.92, alpha: 1),
    NSColor(calibratedRed: 0.24, green: 0.68, blue: 0.42, alpha: 1),
    NSColor(calibratedRed: 0.97, green: 0.58, blue: 0.16, alpha: 1),
    NSColor(calibratedRed: 0.58, green: 0.40, blue: 0.90, alpha: 1),
    NSColor(calibratedRed: 0.93, green: 0.28, blue: 0.27, alpha: 1),
    NSColor(calibratedRed: 0.13, green: 0.67, blue: 0.74, alpha: 1),
    NSColor(calibratedRed: 0.94, green: 0.78, blue: 0.18, alpha: 1),
    NSColor(calibratedRed: 0.94, green: 0.40, blue: 0.64, alpha: 1),
    NSColor(calibratedRed: 0.52, green: 0.55, blue: 0.60, alpha: 1)
]

func render(_ px: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    let s = CGFloat(px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.28, alpha: 1),
                        NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.12, alpha: 1)])?.draw(in: bg, angle: -90)

    let pad = rect.width * 0.13
    let gap = rect.width * 0.055
    let cell = (rect.width - pad * 2 - gap * 2) / 3
    for r in 0..<3 {
        for c in 0..<3 {
            let x = rect.minX + pad + CGFloat(c) * (cell + gap)
            let y = rect.minY + pad + CGFloat(r) * (cell + gap)
            let cellRect = NSRect(x: x, y: y, width: cell, height: cell)
            let path = NSBezierPath(roundedRect: cellRect, xRadius: cell * 0.24, yRadius: cell * 0.24)
            let color = padColors[r * 3 + c]
            NSGradient(colors: [color.highlight(withLevel: 0.25) ?? color, color])?.draw(in: path, angle: -90)
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for size in [16, 32, 128, 256, 512] {
    if let d = render(size) {
        try? d.write(to: URL(fileURLWithPath: "\(outDir)/icon_\(size)x\(size).png"))
    }
    if let d = render(size * 2) {
        try? d.write(to: URL(fileURLWithPath: "\(outDir)/icon_\(size)x\(size)@2x.png"))
    }
}
