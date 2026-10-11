import Accelerate
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/* Turning a camera frame into what the models read.

   A frame arrives as a BGRA pixel buffer. The sign models want a part of it
   (the crop around the person) at 224x224: the device's S3D squashed into the
   square as planar RGB numbers 0...1, the server's SignFlow-R letterboxed on
   grey as a JPEG. Scaling is done by vImage straight out of the camera's
   memory; nothing is copied at full size. */

enum FrameTools {
    static let side = 224

    /* The crop, kept inside the frame and at least 2 pixels each way. */
    static func clamp(_ crop: CGRect?, width: Int, height: Int) -> (x: Int, y: Int, w: Int, h: Int) {
        guard let r = crop else { return (0, 0, width, height) }
        let x = max(0, min(width - 2, Int(r.minX.rounded())))
        let y = max(0, min(height - 2, Int(r.minY.rounded())))
        let w = max(2, min(width - x, Int(r.width.rounded())))
        let h = max(2, min(height - y, Int(r.height.rounded())))
        return (x, y, w, h)
    }

    /* Scales a part of a BGRA buffer into `out` (BGRA, `outWidth` x `outHeight`, `outRowBytes` a row). */
    @discardableResult
    static func scale(_ buffer: CVPixelBuffer, crop: (x: Int, y: Int, w: Int, h: Int),
                      into out: UnsafeMutableRawPointer, outWidth: Int, outHeight: Int, outRowBytes: Int) -> Bool {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return false }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var src = vImage_Buffer(data: base.advanced(by: crop.y * rowBytes + crop.x * 4),
                                height: vImagePixelCount(crop.h), width: vImagePixelCount(crop.w), rowBytes: rowBytes)
        var dst = vImage_Buffer(data: out, height: vImagePixelCount(outHeight), width: vImagePixelCount(outWidth),
                                rowBytes: outRowBytes)
        return vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
    }

    /* 224x224 BGRA bytes -> planar RGB 0...1 (red plane, green plane, blue
       plane), the layout the S3D model was trained on. Returns how much the
       picture changed since `previous` (red channel on a 28x28 grid, mean
       absolute difference), or -1 the first time. */
    static func planes(from pixels: UnsafePointer<UInt8>, into f: UnsafeMutablePointer<Float>,
                       previous: inout [Int16]) -> Float {
        let area = side * side
        for i in 0..<area {
            let p = i * 4
            f[i] = Float(pixels[p + 2]) / 255
            f[area + i] = Float(pixels[p + 1]) / 255
            f[2 * area + i] = Float(pixels[p]) / 255
        }
        var small = [Int16](repeating: 0, count: 784)
        var k = 0
        var y = 0
        while y < side {
            var x = 0
            while x < side {
                small[k] = Int16(pixels[(y * side + x) * 4 + 2])
                k += 1
                x += 8
            }
            y += 8
        }
        var motion: Float = -1
        if previous.count == 784 {
            var sum = 0
            for i in 0..<784 { sum += Int(abs(small[i] - previous[i])) }
            motion = Float(sum) / 784
        }
        previous = small
        return motion
    }

    /* The crop letterboxed into 224x224 on grey (114), as SignFlow-R was
       trained, and packed as a JPEG. */
    static func letterboxJPEG(_ buffer: CVPixelBuffer, crop: (x: Int, y: Int, w: Int, h: Int),
                              quality: CGFloat = 0.8) -> Data? {
        let rowBytes = side * 4
        var pixels = [UInt8](repeating: 114, count: side * rowBytes)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        let s = Double(side) / Double(max(crop.w, crop.h))
        let w = max(1, Int((Double(crop.w) * s).rounded()))
        let h = max(1, Int((Double(crop.h) * s).rounded()))
        let ox = (side - w) / 2, oy = (side - h) / 2
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return scale(buffer, crop: crop, into: base.advanced(by: oy * rowBytes + ox * 4),
                         outWidth: w, outHeight: h, outRowBytes: rowBytes)
        }
        guard ok else { return nil }
        return jpeg(bgra: pixels, width: side, height: side, quality: quality)
    }

    static func jpeg(bgra pixels: [UInt8], width: Int, height: Int, quality: CGFloat) -> Data? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        guard let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
