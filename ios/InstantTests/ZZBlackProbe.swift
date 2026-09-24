import Testing
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
@testable import Instant

@MainActor @Suite struct ZZBlackProbe {
    @Test func stages() {
        let black = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { c in
            UIColor.black.setFill(); c.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        let ctx = CIContext()
        let input = CIImage(cgImage: black.cgImage!)
        func px(_ image: CIImage?) -> String {
            guard let image, let cg = ctx.createCGImage(image, from: input.extent) else { return "nil" }
            var p = [UInt8](repeating: 0, count: 4)
            let c = CGContext(data: &p, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return "\(p[0])/\(p[1])/\(p[2])"
        }
        let curve = CIFilter.toneCurve()
        curve.inputImage = input
        curve.point0 = CGPoint(x: 0, y: 0.05); curve.point1 = CGPoint(x: 0.25, y: 0.262)
        curve.point2 = CGPoint(x: 0.5, y: 0.513); curve.point3 = CGPoint(x: 0.75, y: 0.772)
        curve.point4 = CGPoint(x: 1, y: 0.972)
        let toned = curve.outputImage!

        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = toned
        matrix.rVector = CIVector(x: 1.035, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: 0.975, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let warmed = matrix.outputImage!

        let controls = CIFilter.colorControls()
        controls.inputImage = warmed
        controls.saturation = 0.94; controls.contrast = 1; controls.brightness = 0
        let calmed = controls.outputImage!

        let vib = CIFilter.vibrance()
        vib.inputImage = calmed
        vib.amount = 0.18
        let graded = vib.outputImage

        #expect(Bool(false), "toned \(px(toned)) warmed \(px(warmed)) calmed \(px(calmed)) graded \(px(graded)) film \(px(PhotoFilter.film.apply(to: black).cgImage.map { CIImage(cgImage: $0) }))")
    }
}
