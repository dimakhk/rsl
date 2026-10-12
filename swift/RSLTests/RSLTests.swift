import CoreVideo
import SwiftUI
import XCTest
@testable import RSL

/* What can be checked without a camera and without a person: that the model
   inside the app answers as it does on a PC, that frames are turned into the
   numbers it expects, and that the arithmetic of framing and of accepting a
   word gives the results worked out by hand.

   Lines starting with RSLNOTE are picked out of the log by the workflow and
   shown on the run's page. */

final class ModelTests: XCTestCase {
    private func modelPath() throws -> String {
        try XCTUnwrap(Bundle.main.path(forResource: "s3d", ofType: "onnx"), "the model is not in the app")
    }

    private func reference() throws -> [String: [[Double]]] {
        let url = try XCTUnwrap(Bundle(for: ModelTests.self).url(forResource: "reference", withExtension: "json"))
        return try JSONDecoder().decode([String: [[Double]]].self, from: Data(contentsOf: url))
    }

    /* The same made-up input as tools/reference.py: pseudo-random numbers. */
    private func noise() -> NSMutableData {
        let data = NSMutableData(length: S3DModel.count * MemoryLayout<Float>.size)!
        let f = data.mutableBytes.bindMemory(to: Float.self, capacity: S3DModel.count)
        for i in 0..<S3DModel.count {
            f[i] = Float((UInt64(i) &* 2654435761) % 1000) / 1000
        }
        return data
    }

    func testModelAnswersAsOnAPC() throws {
        let model = try S3DModel(path: modelPath())
        let expected = try reference()
        for (name, input) in [("waves", S3DModel.sample()), ("noise", noise())] {
            let t0 = CFAbsoluteTimeGetCurrent()
            let logits = try model.logits(input)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            XCTAssertEqual(logits.count, 1599)
            var worst = 0.0
            for row in try XCTUnwrap(expected[name]) {
                let index = Int(row[0])
                worst = max(worst, abs(Double(logits[index]) - row[1]))
                XCTAssertEqual(Double(logits[index]), row[1], accuracy: 0.02, "\(name), class \(index)")
            }
            let best = logits.indices.max { logits[$0] < logits[$1] }!
            XCTAssertEqual(best, Int(expected[name]![0][0]), "\(name): the best class")
            print(String(format: "RSLNOTE model/%@: best class %d, largest difference from the PC %.4f, %.0f ms (CPU, Simulator)",
                         name, best, worst, ms))
        }
    }

    func testCoreMLIsComparedWithTheCPU() throws {
        let model = try S3DModel(path: modelPath())
        let trial = model.tryCoreML()
        print(String(format: "RSLNOTE coreml: CPU %.0f ms, Core ML %.0f ms, agrees %@, switched %@ %@",
                     trial.cpuMs, trial.coreMLMs, String(trial.agrees), String(trial.switched), trial.note))
        // Whatever was chosen must still give the PC's answer.
        let logits = try model.logits(S3DModel.sample())
        let row = try XCTUnwrap(reference()["waves"]?.first)
        XCTAssertEqual(Double(logits[Int(row[0])]), row[1], accuracy: 0.05)
        XCTAssertTrue(trial.switched == false || trial.agrees)
    }

    /* 32 frames go in one by one; the window the model gets must be those
       frames in order, oldest first. */
    func testRecognizerFeedsFramesInOrder() throws {
        let labels = try XCTUnwrap(Bundle.main.path(forResource: "labels", ofType: "json"))
        let names = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: labels)))
        XCTAssertEqual(names.count, 1599)
        let queue = DispatchQueue(label: "test.frames")
        let recognizer = Recognizer()
        recognizer.callbackQueue = queue
        try recognizer.load(modelPath: modelPath(), labelsPath: labels)
        let answered = expectation(description: "the model answered")
        var top: [Guess] = []
        recognizer.onStats = { stats in
            if top.isEmpty, !stats.top.isEmpty {
                top = stats.top
                answered.fulfill()
            }
        }
        let sample = S3DModel.sample()
        let frames = sample.bytes.bindMemory(to: Float.self, capacity: S3DModel.count)
        queue.async {
            recognizer.start()
            for t in 0..<Recognizer.window { recognizer.pushPlanes(frames + t * Recognizer.plane) }
        }
        wait(for: [answered], timeout: 120)
        let expected = try XCTUnwrap(reference()["waves"]?.first)
        XCTAssertEqual(top.first?.label, names[Int(expected[0])])
        print("RSLNOTE recognizer: best guess \(top.first?.label ?? "-") (expected \(names[Int(expected[0])]))")
    }
}

final class FrameTests: XCTestCase {
    /* A 640x480 BGRA picture: left half red, right half blue, with a green
       band along the top. */
    private func picture() throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_32BGRA, nil, &made)
        let buffer = try XCTUnwrap(made)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<480 {
            for x in 0..<640 {
                let p = base + y * row + x * 4
                let green = y < 48
                p[0] = !green && x >= 320 ? 255 : 0       // blue
                p[1] = green ? 255 : 0
                p[2] = !green && x < 320 ? 255 : 0        // red
                p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    func testPlanesAreRedGreenBlue() throws {
        let buffer = try picture()
        let side = FrameTools.side
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let crop = FrameTools.clamp(nil, width: 640, height: 480)
        XCTAssertTrue(bytes.withUnsafeMutableBytes {
            FrameTools.scale(buffer, crop: crop, into: $0.baseAddress!, outWidth: side, outHeight: side, outRowBytes: side * 4)
        })
        var planes = [Float](repeating: -1, count: Recognizer.plane)
        var previous: [Int16] = []
        let first = FrameTools.planes(from: bytes, into: &planes, previous: &previous)
        XCTAssertEqual(first, -1)                                   // nothing to compare with yet
        let area = side * side
        func at(_ plane: Int, x: Int, y: Int) -> Float { planes[plane * area + y * side + x] }
        // middle of the left half: red;  middle of the right half: blue;  the top band: green
        XCTAssertEqual(at(0, x: 56, y: 140), 1, accuracy: 0.02)
        XCTAssertEqual(at(2, x: 56, y: 140), 0, accuracy: 0.02)
        XCTAssertEqual(at(2, x: 168, y: 140), 1, accuracy: 0.02)
        XCTAssertEqual(at(0, x: 168, y: 140), 0, accuracy: 0.02)
        XCTAssertEqual(at(1, x: 112, y: 8), 1, accuracy: 0.02)
        // the same picture again: no motion
        XCTAssertEqual(FrameTools.planes(from: bytes, into: &planes, previous: &previous), 0)
    }

    func testCropTakesThePartAsked() throws {
        let buffer = try picture()
        let side = FrameTools.side
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        // the right half, below the band: all blue
        let crop = FrameTools.clamp(CGRect(x: 330, y: 60, width: 300, height: 400), width: 640, height: 480)
        XCTAssertTrue(bytes.withUnsafeMutableBytes {
            FrameTools.scale(buffer, crop: crop, into: $0.baseAddress!, outWidth: side, outHeight: side, outRowBytes: side * 4)
        })
        for i in stride(from: 0, to: bytes.count, by: 4 * 997) {
            XCTAssertEqual(bytes[i], 255)                           // blue
            XCTAssertEqual(bytes[i + 2], 0)                         // red
        }
    }

    func testLightnessOfAPart() throws {
        let buffer = try picture()
        // the green band along the top: 0.587; the red half under it: 0.299
        let band = try XCTUnwrap(FrameTools.lightness(buffer, in: CGRect(x: 0, y: 0, width: 640, height: 48)))
        XCTAssertEqual(band, 0.587, accuracy: 0.01)
        let red = try XCTUnwrap(FrameTools.lightness(buffer, in: CGRect(x: 0, y: 60, width: 320, height: 400)))
        XCTAssertEqual(red, 0.299, accuracy: 0.01)
    }

    func testLetterboxIsAJPEGOf224() throws {
        let buffer = try picture()
        let data = try XCTUnwrap(FrameTools.letterboxJPEG(buffer, crop: FrameTools.clamp(nil, width: 640, height: 480)))
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
        let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
        XCTAssertEqual(image.width, 224)
        XCTAssertEqual(image.height, 224)
        // 640x480 into 224: the picture is 224x168 with grey bars of 28 above and below
        let context = CGContext(data: nil, width: 224, height: 224, bitsPerComponent: 8, bytesPerRow: 224 * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 224, height: 224))
        let px = context.data!.assumingMemoryBound(to: UInt8.self)
        func rgb(x: Int, y: Int) -> [Int] { (0..<3).map { Int(px[(y * 224 + x) * 4 + $0]) } }
        for c in rgb(x: 112, y: 10) { XCTAssertEqual(Double(c), 114, accuracy: 6) }      // the bar
        XCTAssertGreaterThan(rgb(x: 50, y: 120)[0], 200)                                 // red, left
        XCTAssertGreaterThan(rgb(x: 170, y: 120)[2], 200)                                // blue, right
    }
}

final class FramingTests: XCTestCase {
    private func person(shoulders: CGFloat, centre: CGFloat = 0.5, y: CGFloat = 0.45, neck: CGFloat = 0.1) -> BodyPoints {
        BodyPoints(nose: .init(x: centre, y: y - neck, v: 1),
                   leftShoulder: .init(x: centre + shoulders / 2, y: y, v: 1),
                   rightShoulder: .init(x: centre - shoulders / 2, y: y, v: 1))
    }

    /* A 720x1280 frame, shoulders 0.3 of the width at 45% of the height. */
    func testCropInShoulderWidths() throws {
        let t = try XCTUnwrap(Framing.target(person(shoulders: 0.3), width: 720, height: 1280))
        XCTAssertEqual(t.s, 216, accuracy: 0.01)                    // 0.3 * 720; the neck gives 185.6
        XCTAssertEqual(t.cx, 360, accuracy: 0.01)
        XCTAssertEqual(t.cy, 576 - 1.6 * 216 + 2.9 * 216 / 2, accuracy: 0.01)
        let crop = Framing.crop(t, width: 720, height: 1280)
        XCTAssertEqual(crop.width, 518.4, accuracy: 0.01)
        XCTAssertEqual(crop.height, 626.4, accuracy: 0.01)
        XCTAssertEqual(crop.minX, 100.8, accuracy: 0.01)
        XCTAssertEqual(crop.minY, 230.4, accuracy: 0.01)
        XCTAssertNil(Framing.judge(t, width: 720, height: 1280))
    }

    func testAdvice() throws {
        let close = try XCTUnwrap(Framing.target(person(shoulders: 0.7), width: 720, height: 1280))
        XCTAssertEqual(Framing.judge(close, width: 720, height: 1280), .close)
        let far = try XCTUnwrap(Framing.target(person(shoulders: 0.1, y: 0.5, neck: 0.03), width: 720, height: 1280))
        XCTAssertEqual(Framing.judge(far, width: 720, height: 1280), .far)
        let side = try XCTUnwrap(Framing.target(person(shoulders: 0.3, centre: 0.1), width: 720, height: 1280))
        XCTAssertEqual(Framing.judge(side, width: 720, height: 1280), .side)
        var unsure = person(shoulders: 0.3)
        unsure.leftShoulder.v = 0.1
        XCTAssertNil(Framing.target(unsure, width: 720, height: 1280))
    }

    func testHintsWaitBeforeShowing() {
        var framing = Framing()
        framing.reset(now: 0)
        framing.digest(nil, width: 720, height: 1280, now: 500)
        XCTAssertNil(framing.advice)                                // a moment's grace
        framing.digest(nil, width: 720, height: 1280, now: 1300)
        XCTAssertNil(framing.advice)                                // lost, but the hint must hold 700 ms
        framing.digest(nil, width: 720, height: 1280, now: 2100)
        XCTAssertEqual(framing.advice, "Встаньте перед камерой")
        framing.digest(person(shoulders: 0.3), width: 720, height: 1280, now: 2300)
        XCTAssertNotNil(framing.crop)
        framing.digest(person(shoulders: 0.3), width: 720, height: 1280, now: 3100)
        XCTAssertNil(framing.advice)
    }
}

final class RuleTests: XCTestCase {
    func testTwoWindowsInARowWhenWindowsAreDense() {
        var rule = Rule()
        XCTAssertEqual(rule.judge(label: "дом", confidence: 0.8, stride: 8), .nothing)
        XCTAssertEqual(rule.judge(label: "дом", confidence: 0.75, stride: 8), .accepted(word: "дом"))
        // the same sign held: accepted again, but not said twice
        XCTAssertEqual(rule.judge(label: "дом", confidence: 0.8, stride: 8), .nothing)
        XCTAssertEqual(rule.judge(label: "дом", confidence: 0.8, stride: 8), .accepted(word: nil))
    }

    func testOneWindowIsEnoughWhenSureOrWhenWindowsAreRare() {
        var rule = Rule()
        XCTAssertEqual(rule.judge(label: "мама", confidence: 0.95, stride: 8), .accepted(word: "мама"))
        XCTAssertEqual(rule.judge(label: "папа", confidence: 0.72, stride: 20), .accepted(word: "папа"))
    }

    func testBlankAndUnsureAreNothing() {
        var rule = Rule()
        XCTAssertEqual(rule.judge(label: "no", confidence: 0.99, stride: 8), .nothing)
        XCTAssertEqual(rule.judge(label: "дом", confidence: 0.6, stride: 20), .nothing)
        XCTAssertEqual(rule.judge(label: "дом", confidence: 0.8, stride: 8), .nothing)
        XCTAssertEqual(rule.judge(label: "кот", confidence: 0.8, stride: 8), .nothing)      // a different word: the count starts over
    }
}

final class DrawingTests: XCTestCase {
    func testPathCommands() {
        let line = SVGPath.parse("M8 60L34 9L129 53").boundingRect
        XCTAssertEqual(line, CGRect(x: 8, y: 9, width: 121, height: 51))
        let relative = SVGPath.parse("m10 10h20v5l-5-5z").boundingRect
        XCTAssertEqual(relative, CGRect(x: 10, y: 10, width: 20, height: 5))
        let packed = SVGPath.parse("M1.5.5-2,3").boundingRect           // numbers running together
        XCTAssertEqual(packed, CGRect(x: -2, y: 0.5, width: 3.5, height: 2.5))
    }

    /* The ring of the splash: an arc that goes all the way round. */
    func testArcGoesRound() {
        let ring = SVGPath.parse("M52.5 4.3A48.2 48.2 0 1 1 52.49 4.3").boundingRect
        XCTAssertEqual(ring.minX, 4.3, accuracy: 0.05)
        XCTAssertEqual(ring.maxX, 100.7, accuracy: 0.05)
        XCTAssertEqual(ring.minY, 4.3, accuracy: 0.05)
        XCTAssertEqual(ring.maxY, 100.7, accuracy: 0.05)
    }

    func testIconsComeFromTheFiles() {
        XCTAssertEqual(Icons.hand.parts.count, 4)
        XCTAssertEqual(Icons.logoHouse.parts.count, 9)
        XCTAssertEqual(Icons.soundOn.parts.count, 3)
        XCTAssertEqual(Icons.micOff.parts.count, 6)
        XCTAssertEqual(Icons.logoAccess.box, CGRect(x: 0, y: 0, width: 105, height: 105))
        XCTAssertNil(Icons.logoAccess.parts[0].stroke)                  // a filled shape
        XCTAssertFalse(Icons.logoAccess.parts[0].path.isEmpty)
        XCTAssertEqual(Icons.close.parts[0].stroke ?? 0, 2.33333, accuracy: 0.0001)
    }

    func testSpringSettlesOnItsTarget() {
        var spring = StepSpring(0, damping: 0.85, response: 0.45)
        spring.target = 3
        for _ in 0..<240 { spring.step(1.0 / 60) }
        XCTAssertEqual(spring.value, 3)
        XCTAssertTrue(spring.settled)
    }
}
