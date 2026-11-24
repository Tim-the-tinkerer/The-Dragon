import Foundation

enum DemoReel {
    static let width = 480
    static let height = 270
    static let frames = 48
    static let fps = 24.0

    /// A two-second card in motion, so Fold works before a file is opened.
    static func make() -> Reel {
        var frames: [[UInt8]] = []
        frames.reserveCapacity(Self.frames)
        for index in 0..<Self.frames {
            frames.append(paint(index))
        }
        return Reel.memory(
            frames: frames,
            width: width,
            height: height,
            fps: fps,
            name: "Reel"
        )
    }

    private static func paint(_ index: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let wash = index / 6
        for y in 0..<height {
            let sky = y < 176
            let r: UInt8
            let g: UInt8
            let b: UInt8
            if sky {
                r = UInt8(min(255, 22 + y / 8 + wash))
                g = UInt8(min(255, 36 + y / 5))
                b = UInt8(min(255, 72 + y / 4))
            } else {
                r = 28
                g = UInt8(min(255, 48 + (y - 176) / 8))
                b = 30
            }
            var cursor = y * width * 4
            for _ in 0..<width {
                pixels[cursor] = r
                pixels[cursor + 1] = g
                pixels[cursor + 2] = b
                pixels[cursor + 3] = 255
                cursor += 4
            }
        }
        fill(&pixels, 70, 150, 190, 230, 242, 232, 210)
        fill(&pixels, 118, 188, 142, 230, 42, 32, 28)
        fill(&pixels, 84, 164, 108, 186, 176, 64, 48)
        fill(&pixels, 150, 164, 174, 186, 64, 120, 96)
        let centerX = 40 + index * 8
        let centerY = 78
        disc(&pixels, centerX, centerY, 26, 219, 173, 92)
        let bob = 40 + (index * 3 % 80)
        fill(&pixels, 400, bob, 428, bob + 18, 158, 188, 198)
        return pixels
    }

    private static func fill(
        _ pixels: inout [UInt8],
        _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int,
        _ r: UInt8, _ g: UInt8, _ b: UInt8
    ) {
        let left = max(0, x0)
        let right = min(width, x1)
        let top = max(0, y0)
        let bottom = min(height, y1)
        guard left < right, top < bottom else { return }
        for y in top..<bottom {
            var index = (y * width + left) * 4
            for _ in left..<right {
                pixels[index] = r
                pixels[index + 1] = g
                pixels[index + 2] = b
                pixels[index + 3] = 255
                index += 4
            }
        }
    }

    private static func disc(
        _ pixels: inout [UInt8],
        _ cx: Int, _ cy: Int, _ radius: Int,
        _ r: UInt8, _ g: UInt8, _ b: UInt8
    ) {
        let r2 = radius * radius
        for y in (cy - radius)..<(cy + radius) {
            for x in (cx - radius)..<(cx + radius) {
                guard x >= 0, y >= 0, x < width, y < height else { continue }
                let dx = x - cx
                let dy = y - cy
                if dx * dx + dy * dy <= r2 {
                    let index = (y * width + x) * 4
                    pixels[index] = r
                    pixels[index + 1] = g
                    pixels[index + 2] = b
                    pixels[index + 3] = 255
                }
            }
        }
    }
}
