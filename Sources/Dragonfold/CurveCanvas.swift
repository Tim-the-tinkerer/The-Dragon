import SwiftUI

struct CurveCanvas: View {
    var vertices: [Curve.Point]

    var body: some View {
        Canvas { context, size in
            guard vertices.count >= 2 else { return }
            let xs = vertices.map(\.x)
            let ys = vertices.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
                return
            }
            let spanX = CGFloat(max(maxX - minX, 1))
            let spanY = CGFloat(max(maxY - minY, 1))
            let pad: CGFloat = 28
            let scale = min((size.width - pad * 2) / spanX, (size.height - pad * 2) / spanY)
            let originX = (size.width - spanX * scale) / 2
            let originY = (size.height - spanY * scale) / 2

            func convert(_ point: Curve.Point) -> CGPoint {
                CGPoint(
                    x: originX + CGFloat(point.x - minX) * scale,
                    y: originY + CGFloat(maxY - point.y) * scale
                )
            }

            var curve = Path()
            let start = convert(vertices[0])
            curve.move(to: start)
            for point in vertices.dropFirst() {
                curve.addLine(to: convert(point))
            }
            context.stroke(
                curve,
                with: .color(Theme.brass),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
            )
            let radius: CGFloat = 4
            context.fill(
                Path(ellipseIn: CGRect(x: start.x - radius, y: start.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(Theme.cream)
            )
        }
        .background(Theme.paper)
    }
}

struct WaveCanvas: View {
    var wave: WavePeaks
    var playhead: Double
    var folded: Bool

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: mid))
            axis.addLine(to: CGPoint(x: size.width, y: mid))
            context.stroke(axis, with: .color(Theme.dim.opacity(0.6)), lineWidth: 1)

            stroke(context, size: size, lows: wave.minL, highs: wave.maxL, color: folded ? Theme.brass : Theme.cream, mid: mid)
            if wave.minR != wave.minL {
                stroke(context, size: size, lows: wave.minR, highs: wave.maxR, color: Theme.steel.opacity(0.85), mid: mid)
            }

            if playhead > 0, playhead < 1, !wave.isEmpty {
                let x = size.width * playhead
                var head = Path()
                head.move(to: CGPoint(x: x, y: 4))
                head.addLine(to: CGPoint(x: x, y: size.height - 4))
                context.stroke(head, with: .color(Theme.cream.opacity(0.9)), lineWidth: 1)
            }
        }
        .background(Theme.paper)
    }

    private func stroke(
        _ context: GraphicsContext,
        size: CGSize,
        lows: [Float],
        highs: [Float],
        color: Color,
        mid: CGFloat
    ) {
        guard !lows.isEmpty, lows.count == highs.count else { return }
        let width = size.width
        let amp = Swift.max(8, (size.height / 2) - 8)
        var path = Path()
        for index in lows.indices {
            let x = width * (CGFloat(index) + 0.5) / CGFloat(lows.count)
            let top = mid - CGFloat(highs[index]) * amp
            if index == 0 {
                path.move(to: CGPoint(x: x, y: top))
            } else {
                path.addLine(to: CGPoint(x: x, y: top))
            }
        }
        for index in lows.indices.reversed() {
            let x = width * (CGFloat(index) + 0.5) / CGFloat(lows.count)
            let bottom = mid - CGFloat(lows[index]) * amp
            path.addLine(to: CGPoint(x: x, y: bottom))
        }
        path.closeSubpath()
        context.fill(path, with: .color(color.opacity(0.9)))
    }
}
