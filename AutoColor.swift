// Auto color: Apple's own auto-enhance (Core Image's auto adjustment, as in
// Photos) measured on frames across the sermon, combined into one fixed
// correction, and baked into a 3D lookup table. The trim window previews
// the table with Core Image; the save applies the same table with ffmpeg's
// lut3d, so what you see is what you get.

import AVFoundation
import CoreImage

struct ColorLook: Equatable {
    /// Face balance (skin-tone white balance): the colour cast it measured.
    var faceI: Double?
    var faceQ: Double?
    var vibrance: Double = 0
    var curve: [CGPoint] = (0..<5).map { CGPoint(x: Double($0) / 4, y: Double($0) / 4) }
    var shadows: Double = 0

    /// Only filters that change each colour on its own, so the result can
    /// be a lookup table. (Shadow lift with radius 0 is one of those.)
    var filters: [CIFilter] {
        var out: [CIFilter] = []
        if let i = faceI, let q = faceQ, let f = CIFilter(name: "CIFaceBalance") {
            f.setValue(i, forKey: "inputOrigI")
            f.setValue(q, forKey: "inputOrigQ")
            f.setValue(1, forKey: "inputStrength")
            f.setValue(0.5, forKey: "inputWarmth")
            out.append(f)
        }
        if vibrance != 0, let f = CIFilter(name: "CIVibrance") {
            f.setValue(vibrance, forKey: "inputAmount")
            out.append(f)
        }
        if let f = CIFilter(name: "CIToneCurve") {
            for (k, p) in curve.enumerated() { f.setValue(CIVector(cgPoint: p), forKey: "inputPoint\(k)") }
            out.append(f)
        }
        if shadows != 0, let f = CIFilter(name: "CIHighlightShadowAdjust") {
            f.setValue(0, forKey: "inputRadius")
            f.setValue(shadows, forKey: "inputShadowAmount")
            f.setValue(1, forKey: "inputHighlightAmount")
            out.append(f)
        }
        return out
    }
}

enum AutoColor {
    static let size = 33

    /// Auto-enhance on `count` frames between `from` and `to`, combined
    /// (median of each setting) into one look, plus the colour space the
    /// frames came in. The table has to work in that space (CoreMedia's 709
    /// for HD): it holds the video's own R'G'B' values, the same ones ffmpeg
    /// gets with the bt709 matrix, so preview and save agree. (A plain
    /// ITU-R 709 space has a different curve and was off by about 12/255.)
    /// Face balance only counts if a face showed up in enough frames.
    static func measure(_ asset: AVAsset, from: Double, to: Double, count: Int = 20) async
        -> (look: ColorLook, space: CGColorSpace)? {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1280, height: 720)
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tolerance
        gen.requestedTimeToleranceAfter = tolerance
        var faces: [(Double, Double)] = []
        var vibrance: [Double] = []
        var shadows: [Double] = []
        var curves: [[CGPoint]] = []
        var space: CGColorSpace?
        for k in 0..<count {
            if Task.isCancelled { return nil }
            let t = from + (to - from) * (Double(k) + 0.5) / Double(count)
            guard let cg = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { continue }
            if space == nil { space = cg.colorSpace }
            let found = CIImage(cgImage: cg).autoAdjustmentFilters(options: [.redEye: false])
            var v = 0.0, s = 0.0
            var curve: [CGPoint]?
            for f in found {
                switch f.name {
                case "CIFaceBalance":
                    if let i = (f.value(forKey: "inputOrigI") as? NSNumber)?.doubleValue,
                       let q = (f.value(forKey: "inputOrigQ") as? NSNumber)?.doubleValue { faces.append((i, q)) }
                case "CIVibrance":
                    v = (f.value(forKey: "inputAmount") as? NSNumber)?.doubleValue ?? 0
                case "CIToneCurve":
                    curve = (0..<5).compactMap { (f.value(forKey: "inputPoint\($0)") as? CIVector)?.cgPointValue }
                case "CIHighlightShadowAdjust":
                    s = (f.value(forKey: "inputShadowAmount") as? NSNumber)?.doubleValue ?? 0
                default:
                    break
                }
            }
            vibrance.append(v)
            shadows.append(s)
            if let curve, curve.count == 5 { curves.append(curve) }
        }
        guard !vibrance.isEmpty, let space else { return nil }
        var look = ColorLook()
        if faces.count * 3 >= vibrance.count {
            look.faceI = median(faces.map(\.0))
            look.faceQ = median(faces.map(\.1))
        }
        look.vibrance = median(vibrance)
        look.shadows = median(shadows)
        if !curves.isEmpty {
            look.curve = (0..<5).map { k in CGPoint(x: median(curves.map { Double($0[k].x) }),
                                                    y: median(curves.map { Double($0[k].y) })) }
        }
        return (look, space)
    }

    private static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        return s.isEmpty ? 0 : (s[(s.count - 1) / 2] + s[s.count / 2]) / 2
    }

    /// The look as a size³ RGBA float table, red changing fastest (the
    /// layout both CIColorCube and .cube files use).
    static func table(_ look: ColorLook, space: CGColorSpace) -> [Float] {
        let n = size
        var lattice = [Float](repeating: 1, count: n * n * n * 4)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let i = ((b * n + g) * n + r) * 4
                    lattice[i] = Float(r) / Float(n - 1)
                    lattice[i + 1] = Float(g) / Float(n - 1)
                    lattice[i + 2] = Float(b) / Float(n - 1)
                }
            }
        }
        let bytes = lattice.withUnsafeBufferPointer { Data(buffer: $0) }
        var image = CIImage(bitmapData: bytes, bytesPerRow: n * 16, size: CGSize(width: n, height: n * n),
                            format: .RGBAf, colorSpace: space)
        for f in look.filters {
            f.setValue(image, forKey: kCIInputImageKey)
            image = f.outputImage ?? image
        }
        var out = [Float](repeating: 0, count: n * n * n * 4)
        CIContext().render(image, toBitmap: &out, rowBytes: n * 16,
                           bounds: CGRect(x: 0, y: 0, width: n, height: n * n), format: .RGBAf, colorSpace: space)
        for k in out.indices { out[k] = k % 4 == 3 ? 1 : min(max(out[k], 0), 1) }
        return out
    }

    /// The same table as a .cube file for ffmpeg's lut3d.
    static func cube(_ table: [Float]) -> String {
        var s = "LUT_3D_SIZE \(size)\n"
        s.reserveCapacity(size * size * size * 30)
        for k in stride(from: 0, to: table.count, by: 4) {
            s += String(format: "%.6f %.6f %.6f\n", table[k], table[k + 1], table[k + 2])
        }
        return s
    }

    /// A Core Image filter that applies the table, for the preview.
    static func filter(_ data: Data, space: CGColorSpace) -> CIFilter? {
        guard let f = CIFilter(name: "CIColorCubeWithColorSpace") else { return nil }
        f.setValue(size, forKey: "inputCubeDimension")
        f.setValue(data, forKey: "inputCubeData")
        f.setValue(space, forKey: "inputColorSpace")
        return f
    }
}
