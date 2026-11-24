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
            let pad: CGFloat = 18
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
