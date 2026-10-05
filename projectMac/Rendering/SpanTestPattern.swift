/// A static test image for judging span alignment by eye (Display > Span Test Pattern): it
/// replaces the preset on the scene texture, so it goes through exactly the same canvas,
/// slicing and scaling as the real picture. Rows run bottom-up like the GL texture.
enum SpanTestPattern {
    private typealias RGB = (r: UInt8, g: UInt8, b: UInt8)

    /// Grey grid (vertical line every 5% of the width, horizontal every 10% of the height,
    /// white at the centre lines), both diagonals corner to corner (a diagonal that crosses
    /// a seam without a kink means the displays line up), and a coloured square in each
    /// corner: top-left red, top-right green, bottom-left blue, bottom-right yellow.
    static func rgba(width w: Int, height h: Int) -> [UInt32] {
        // One word per pixel (little-endian: A<<24 | B<<16 | G<<8 | R), opaque black to start.
        var pixels = [UInt32](repeating: 0xFF00_0000, count: w * h)
        let thickness = max(2, h / 600)

        func put(_ x: Int, _ y: Int, _ c: RGB) {
            guard x >= 0, x < w, y >= 0, y < h else { return }
            pixels[y * w + x] = 0xFF00_0000 | UInt32(c.b) << 16 | UInt32(c.g) << 8 | UInt32(c.r)
        }

        for k in 0...20 {
            let x = k * (w - 1) / 20
            let c: RGB = k == 10 ? (255, 255, 255) : (90, 90, 90)
            for y in 0..<h { for d in 0..<thickness { put(x + d - thickness / 2, y, c) } }
        }
        for k in 0...10 {
            let y = k * (h - 1) / 10
            let c: RGB = k == 5 ? (255, 255, 255) : (90, 90, 90)
            for x in 0..<w { for d in 0..<thickness { put(x, y + d - thickness / 2, c) } }
        }
        for x in 0..<w {
            let y = x * (h - 1) / max(1, w - 1)
            for d in 0..<thickness * 2 {
                put(x, y + d - thickness, (255, 200, 0))
                put(x, h - 1 - y + d - thickness, (0, 200, 255))
            }
        }
        let side = h / 12
        for dy in 0..<side {
            for dx in 0..<side {
                put(dx, h - 1 - dy, (255, 0, 0))
                put(w - 1 - dx, h - 1 - dy, (0, 255, 0))
                put(dx, dy, (0, 0, 255))
                put(w - 1 - dx, dy, (255, 255, 0))
            }
        }
        return pixels
    }
}
