import AppKit
import SwiftUI

/// AntCodeLabs Limited branding: the line-drawn ant mark from antcodelabs.ai, its colours and link.
enum Brand {
    static let company = "AntCodeLabs Limited"
    static let website = URL(string: "https://antcodelabs.ai")!
    static let websiteLabel = "antcodelabs.ai"
    static let repository = "AntCodeLabs/ant-ai-launcher"
    static let acid = NSColor(srgbRed: 0x8d / 255.0, green: 0xfa / 255.0, blue: 0x4e / 255.0, alpha: 1)
    static let ink = NSColor(srgbRed: 0x05 / 255.0, green: 0x07 / 255.0, blue: 0x0c / 255.0, alpha: 1)
    static let navy = NSColor(srgbRed: 0x15 / 255.0, green: 0x20 / 255.0, blue: 0x39 / 255.0, alpha: 1)

    /// The ant from the site's `<g id="ant">`, in its 32×32 viewBox (y grows downward).
    static func antPath(in rect: CGRect) -> CGPath {
        let s = min(rect.width, rect.height) / 32
        let ox = rect.midX - 16 * s, oy = rect.midY - 16 * s
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        let path = CGMutablePath()
        for (cx, cy, rx, ry) in [(16.0, 7.0, 4.2, 3.6), (16, 15, 3.2, 3.4), (16, 24.5, 4.6, 5.3)] {
            path.addEllipse(in: CGRect(x: ox + (cx - rx) * s, y: oy + (cy - ry) * s, width: 2 * rx * s, height: 2 * ry * s))
        }
        let lines: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (13.5, 4.5, 9.5, 1), (18.5, 4.5, 22.5, 1),                       // antennae
            (13, 14, 6.5, 10.5), (13, 16.5, 6, 17.5), (13.6, 18, 8, 23),     // left legs
            (19, 14, 25.5, 10.5), (19, 16.5, 26, 17.5), (18.4, 18, 24, 23),  // right legs
        ]
        for (x1, y1, x2, y2) in lines {
            path.move(to: p(x1, y1)); path.addLine(to: p(x2, y2))
        }
        return path
    }

    /// Draws the ant into the current (flipped) graphics context.
    static func drawAnt(in rect: CGRect, color: NSColor, lineWidth: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.addPath(antPath(in: rect))
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Monochrome template ant for the menu bar.
    static var menuBarIcon: NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            drawAnt(in: rect.insetBy(dx: 0, dy: 0), color: .black, lineWidth: 1.35)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Ant AI Launcher"
        return img
    }

    /// The app icon: acid-green ant on the site's navy-to-ink gradient, in a rounded square.
    static func appIcon(pixels: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        let gctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = gctx
        let ctx = gctx.cgContext
        let n = CGFloat(pixels)
        // macOS icon grid: ~10% margin, ~22.5% corner radius.
        let tile = CGRect(x: n * 0.1, y: n * 0.1, width: n * 0.8, height: n * 0.8)
        let shape = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -n * 0.01), blur: n * 0.03,
                      color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.addPath(shape); ctx.setFillColor(ink.cgColor); ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape); ctx.clip()
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [navy.cgColor, ink.cgColor] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(grad, startCenter: CGPoint(x: n / 2, y: n * 0.75), startRadius: 0,
                               endCenter: CGPoint(x: n / 2, y: n * 0.75), endRadius: n * 0.7, options: [.drawsAfterEndLocation])
        // Flip so the ant (y-down coordinates) draws upright.
        ctx.translateBy(x: 0, y: n); ctx.scaleBy(x: 1, y: -1)
        let antRect = tile.insetBy(dx: tile.width * 0.17, dy: tile.width * 0.17)
        ctx.setShadow(offset: .zero, blur: n * 0.025, color: acid.withAlphaComponent(0.55).cgColor)
        drawAnt(in: antRect, color: acid, lineWidth: max(1, antRect.width / 32 * 1.6))
        ctx.restoreGState()

        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Writes an .iconset folder (for `iconutil`). Used by build.sh via `--write-iconset <dir>`.
    static func writeIconset(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                let data = appIcon(pixels: base * scale).representation(using: .png, properties: [:])!
                try data.write(to: dir.appendingPathComponent(name))
            }
        }
    }
}

/// SwiftUI version of the ant mark.
struct AntMark: Shape {
    func path(in rect: CGRect) -> Path { Path(Brand.antPath(in: rect)) }
}

/// "🐜 AntCodeLabs Limited · antcodelabs.ai" footer used in Settings.
struct BrandFooter: View {
    var body: some View {
        Link(destination: Brand.website) {
            HStack(spacing: 8) {
                AntMark()
                    .stroke(Color(nsColor: Brand.acid), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                    .frame(width: 22, height: 22)
                    .padding(3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: Brand.ink)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(Brand.company).font(.caption.weight(.semibold)).foregroundStyle(.primary)
                    Text(Brand.websiteLabel).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Open \(Brand.website.absoluteString)")
        .onHover { inside in (inside ? NSCursor.pointingHand : NSCursor.arrow).set() }
    }
}
