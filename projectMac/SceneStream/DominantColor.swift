import Foundation

/// Hue/saturation/value, each 0.0-1.0 — hue as a fraction of the circle, not degrees.
struct HSV: Sendable {
    var h: Float
    var s: Float
    var v: Float
}

/// Reduces a grid of RGBA8 texels into a dominant-color pair via k-means, plus the flat
/// average. Pure CPU math — runs on `SceneReducer`'s background queue.
enum DominantColor {
    private struct Cluster {
        var color: SIMD3<Float>
        var population: Int
    }

    /// Flat mean over every texel — smoother, less-flickery than the k-means swatches.
    static func flatAverage(pixels: [UInt8], gridSize: Int) -> SIMD3<Float> {
        let texelCount = gridSize * gridSize
        var rSum = 0, gSum = 0, bSum = 0
        for i in 0..<texelCount {
            rSum += Int(pixels[i * 4])
            gSum += Int(pixels[i * 4 + 1])
            bSum += Int(pixels[i * 4 + 2])
        }
        return SIMD3(
            Float(rSum) / Float(texelCount) / 255,
            Float(gSum) / Float(texelCount) / 255,
            Float(bSum) / Float(texelCount) / 255
        )
    }

    /// Rec. 709 luma — perceptual brightness, unlike HSV's `v` (just `max(r,g,b)`).
    static func luma(_ rgb: SIMD3<Float>) -> Float {
        0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
    }

    static func rgbToHSV(_ rgb: SIMD3<Float>) -> HSV {
        let r = rgb.x, g = rgb.y, b = rgb.z
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let delta = maxC - minC

        var h: Float = 0
        if delta > 0 {
            if maxC == r {
                h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == g {
                h = (b - r) / delta + 2
            } else {
                h = (r - g) / delta + 4
            }
            h /= 6
            if h < 0 { h += 1 }
        }
        let s: Float = maxC <= 0 ? 0 : delta / maxC
        return HSV(h: h, s: s, v: maxC)
    }

    /// k-means over the texel grid (RGB, 0...1), after dropping near-black texels so a
    /// mostly-black MilkDrop frame doesn't waste clusters on the background (à la
    /// Ambilight/Hyperion). `vibrant` maximizes population×saturation (Android Palette's
    /// trick); `muted` is just the largest surviving cluster.
    static func vibrantAndMuted(
        pixels: [UInt8],
        gridSize: Int,
        k: Int = 3,
        blackLevelThreshold: Float = 0.1,
        iterations: Int = 6
    ) -> (vibrant: SIMD3<Float>, muted: SIMD3<Float>) {
        let texelCount = gridSize * gridSize
        var samples: [SIMD3<Float>] = []
        samples.reserveCapacity(texelCount)
        for i in 0..<texelCount {
            let r = Float(pixels[i * 4]) / 255
            let g = Float(pixels[i * 4 + 1]) / 255
            let b = Float(pixels[i * 4 + 2]) / 255
            if max(r, max(g, b)) >= blackLevelThreshold {
                samples.append(SIMD3(r, g, b))
            }
        }

        // Genuinely black frame — skip clustering an empty set.
        guard !samples.isEmpty else { return (.zero, .zero) }

        // Too few texels to cluster meaningfully; their average stands in for both.
        guard samples.count >= k else {
            let avg = samples.reduce(SIMD3<Float>.zero, +) / Float(samples.count)
            return (avg, avg)
        }

        let clusters = kMeans(samples, k: k, iterations: iterations)
        let vibrant = clusters.max { saturation($0.color) * Float($0.population) < saturation($1.color) * Float($1.population) }
        let muted = clusters.max { $0.population < $1.population }
        return (vibrant?.color ?? .zero, muted?.color ?? .zero)
    }

    private static func saturation(_ rgb: SIMD3<Float>) -> Float {
        let maxC = rgb.max()
        let minC = rgb.min()
        return maxC <= 0 ? 0 : (maxC - minC) / maxC
    }

    /// Lloyd's algorithm, deterministically seeded (evenly spaced samples, not random).
    private static func kMeans(_ samples: [SIMD3<Float>], k: Int, iterations: Int) -> [Cluster] {
        var centroids = (0..<k).map { samples[$0 * samples.count / k] }
        var assignments = [Int](repeating: 0, count: samples.count)

        for _ in 0..<iterations {
            for (i, sample) in samples.enumerated() {
                var best = 0
                var bestDistance = Float.greatestFiniteMagnitude
                for (c, centroid) in centroids.enumerated() {
                    let diff = sample - centroid
                    let distance = (diff * diff).sum()
                    if distance < bestDistance {
                        bestDistance = distance
                        best = c
                    }
                }
                assignments[i] = best
            }

            var sums = [SIMD3<Float>](repeating: .zero, count: k)
            var counts = [Int](repeating: 0, count: k)
            for (i, sample) in samples.enumerated() {
                sums[assignments[i]] += sample
                counts[assignments[i]] += 1
            }
            for c in 0..<k where counts[c] > 0 {
                centroids[c] = sums[c] / Float(counts[c])
            }
        }

        var counts = [Int](repeating: 0, count: k)
        for a in assignments { counts[a] += 1 }
        return (0..<k).map { Cluster(color: centroids[$0], population: counts[$0]) }
    }
}
