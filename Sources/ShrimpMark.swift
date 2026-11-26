import AppKit
import SwiftUI

/// Clauncher's own mark: a line-drawn pistol shrimp (snapping shrimp), side view facing right, with its
/// oversized snapping claw and the bubble it fires. Original artwork in the same line style as the
/// AntCodeLabs ant, on the same 32×32 grid (y grows downward).
extension Brand {
    static func shrimpPath(in rect: CGRect) -> CGPath {
        let s = min(rect.width, rect.height) / 32
        let ox = rect.midX - 16 * s, oy = rect.midY - 16 * s
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        let path = CGMutablePath()
        func line(_ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat)) { path.move(to: p(a.0, a.1)); path.addLine(to: p(b.0, b.1)) }
        func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
            path.addEllipse(in: CGRect(x: ox + (x - r) * s, y: oy + (y - r) * s, width: 2 * r * s, height: 2 * r * s))
        }

        // Tail fan
        line((5.8, 19.4), (2.0, 16.2)); line((5.8, 20.0), (1.4, 20.4)); line((6.2, 20.6), (2.6, 24.0))

        // Body: arched back running into a pointed snout, belly running back to the tail
        path.move(to: p(5.8, 19.4))
        path.addCurve(to: p(20.0, 11.2), control1: p(8.2, 14.0), control2: p(14.0, 10.8))
        path.addCurve(to: p(28.4, 12.8), control1: p(23.2, 11.4), control2: p(25.8, 12.0))
        path.addCurve(to: p(21.6, 17.4), control1: p(26.8, 14.8), control2: p(24.6, 16.4))
        path.addCurve(to: p(6.2, 20.6), control1: p(16.6, 19.6), control2: p(10.8, 21.4))

        // Shell segments, bowed slightly toward the head
        for (x, top, bottom) in [(10.2, 13.9, 21.0), (13.8, 12.0, 20.2), (17.4, 11.2, 19.0)] as [(CGFloat, CGFloat, CGFloat)] {
            path.move(to: p(x, top)); path.addQuadCurve(to: p(x, bottom), control: p(x + 0.9, (top + bottom) / 2))
        }

        circle(23.4, 13.6, 0.7)   // eye

        // Long antennae sweeping back over the body, and a short pair forward
        path.move(to: p(24.2, 12.0)); path.addCurve(to: p(5.0, 5.2), control1: p(21.6, 6.6), control2: p(14.0, 4.0))
        path.move(to: p(25.4, 12.3)); path.addCurve(to: p(11.0, 8.6), control1: p(23.4, 8.4), control2: p(17.4, 7.2))
        line((27.6, 12.9), (30.6, 11.2))

        // Walking legs
        line((10.6, 21.0), (10.0, 23.6)); line((13.6, 20.3), (13.2, 22.9)); line((16.6, 19.3), (16.4, 21.8))

        // The big snapping claw, held open: arm, upper (snapping) finger, lower finger and palm
        line((22.4, 17.2), (23.2, 19.6))
        path.move(to: p(23.2, 19.6))
        path.addCurve(to: p(31.2, 19.8), control1: p(24.6, 17.4), control2: p(29.2, 17.0))
        path.move(to: p(31.4, 21.8))
        path.addCurve(to: p(24.0, 24.4), control1: p(30.8, 24.8), control2: p(26.6, 26.6))
        path.addCurve(to: p(23.2, 19.6), control1: p(22.6, 23.2), control2: p(22.4, 21.0))

        // The snap: the bubble the claw fires
        circle(28.0, 28.6, 1.6)

        return path
    }

    static func drawShrimp(in rect: CGRect, color: NSColor, lineWidth: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.addPath(shrimpPath(in: rect))
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }
}

/// SwiftUI version of the shrimp mark.
struct ShrimpMark: Shape {
    func path(in rect: CGRect) -> Path { Path(Brand.shrimpPath(in: rect)) }
}
