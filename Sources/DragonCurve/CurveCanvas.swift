import SwiftUI

struct CurveCanvas: View {
    var picture: DragonEngine.CurvePicture

    var body: some View {
        Canvas { context, size in
            let marks = picture.marks
            let path = picture.path
            let xs = path.map(\.x) + marks.map(\.x)
            let ys = path.map(\.y) + marks.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
                return
            }
            let spanX = CGFloat(max(maxX - minX, 1))
            let spanY = CGFloat(max(maxY - minY, 1))
            let pad: CGFloat = 32
            let scale = min((size.width - pad * 2) / spanX, (size.height - pad * 2) / spanY)
            let originX = (size.width - spanX * scale) / 2
            let originY = (size.height - spanY * scale) / 2

            func convert(_ x: Int, _ y: Int) -> CGPoint {
                CGPoint(
                    x: originX + CGFloat(x - minX) * scale,
                    y: originY + CGFloat(maxY - y) * scale
                )
            }

            if path.count >= 2 {
                var curve = Path()
                let start = convert(path[0].x, path[0].y)
                curve.move(to: start)
                for point in path.dropFirst() {
                    curve.addLine(to: convert(point.x, point.y))
                }
                context.stroke(
                    curve,
                    with: .color(Theme.brass),
                    style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
                )
                let radius: CGFloat = 3.5
                context.fill(
                    Path(ellipseIn: CGRect(x: start.x - radius, y: start.y - radius, width: radius * 2, height: radius * 2)),
                    with: .color(Theme.brass)
                )
            }

            let fontSize: CGFloat = marks.count > 120 ? 11 : (marks.count > 40 ? 14 : 18)
            for mark in marks {
                context.draw(
                    Text(mark.glyph)
                        .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.cream),
                    at: convert(mark.x, mark.y)
                )
            }
        }
        .background(Theme.paper)
    }
}
