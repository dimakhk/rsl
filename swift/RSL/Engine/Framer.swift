import CoreVideo
import Foundation
import Vision

/* Finds the person in the camera picture and frames them the way the sign
   model reads best - and says how to stand when they are not where they
   should be.

   Apple's body-pose detector (Vision) finds the shoulders and the nose about
   five times a second. From them comes a crop in "shoulder widths", measured
   on the lesson video where recognition was best:

       width 2.4, height 2.9, top 1.6 above the shoulder line,
       centred between the shoulders                      (bottom ~ the waist)

   The crop is smoothed (time constant ~0.5 s): a crop that jitters is motion
   the sign model would try to read as a gesture. */

struct BodyPoints {
    struct Point {
        var x: CGFloat                           // fractions of the frame, y down
        var y: CGFloat
        var v: CGFloat                           // how sure the detector is
    }
    var nose: Point
    var leftShoulder: Point
    var rightShoulder: Point
}

/* The arithmetic, apart from the camera. */
struct Framing {
    static let widthK: CGFloat = 2.4
    static let heightK: CGFloat = 2.9
    static let upK: CGFloat = 1.6
    static let smooth: CGFloat = 0.35            // per sample
    static let lostMs: Double = 1200             // nobody seen this long: say so
    static let forgetMs: Double = 2500           // ...and this long: drop the crop
    static let adviceMs: Double = 700            // a hint must hold this long to show
    static let minVisibility: CGFloat = 0.3

    enum Advice: String {
        case nobody = "Встаньте перед камерой"
        case close = "Отойдите чуть дальше"
        case far = "Подойдите ближе"
        case side = "Встаньте по центру"
    }

    struct State {
        var cx: CGFloat
        var cy: CGFloat
        var s: CGFloat
    }

    private(set) var crop: CGRect? = nil
    private(set) var advice: String? = nil

    private var state: State? = nil
    private var lastSeen: Double = 0
    private var candidate: Advice? = nil
    private var candidateSince: Double = 0

    /* Where the crop should be for these landmarks, before smoothing. */
    static func target(_ p: BodyPoints, width W: CGFloat, height H: CGFloat) -> State? {
        if min(p.leftShoulder.v, p.rightShoulder.v) < minVisibility { return nil }
        let sw = abs(p.leftShoulder.x - p.rightShoulder.x) * W
        let sy = (p.leftShoulder.y + p.rightShoulder.y) / 2 * H
        let neck = max(0, sy - p.nose.y * H)
        // Turned sideways, the shoulders look narrow; the neck keeps the scale.
        let s = max(sw, 1.45 * neck)
        if s < 8 { return nil }
        let cx = (p.leftShoulder.x + p.rightShoulder.x) / 2 * W
        return State(cx: cx, cy: sy - upK * s + heightK * s / 2, s: s)
    }

    static func crop(_ st: State, width W: CGFloat, height H: CGFloat) -> CGRect {
        var w = widthK * st.s, h = heightK * st.s
        if w > W || h > H {                      // too close: as much as the frame allows
            let f = min(W / w, H / h)
            w *= f
            h *= f
        }
        let x = min(max(st.cx - w / 2, 0), W - w)
        let y = min(max(st.cy - h / 2, 0), H - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /* What is wrong with where the person stands, judged on the unclamped crop. */
    static func judge(_ st: State, width W: CGFloat, height H: CGFloat) -> Advice? {
        let w = widthK * st.s, h = heightK * st.s
        let top = st.cy - h / 2
        if h > H * 1.08 || w > W * 1.05 || top < -0.08 * H { return .close }
        let left = st.cx - w / 2, right = st.cx + w / 2
        if left < -0.12 * w || right > W + 0.12 * w { return .side }
        if h < H * 0.35 { return .far }
        return nil
    }

    private mutating func settle(_ next: Advice?, now: Double) {
        if next != candidate {
            candidate = next
            candidateSince = now
        }
        if now - candidateSince >= Framing.adviceMs { advice = candidate?.rawValue }
    }

    /* One answer of the detector (nil: nobody found), at time `now` in ms. */
    mutating func digest(_ points: BodyPoints?, width W: CGFloat, height H: CGFloat, now: Double) {
        if let p = points, let t = Framing.target(p, width: W, height: H) {
            lastSeen = now
            if let s = state {
                state = State(cx: s.cx + Framing.smooth * (t.cx - s.cx),
                              cy: s.cy + Framing.smooth * (t.cy - s.cy),
                              s: s.s + Framing.smooth * (t.s - s.s))
            } else {
                state = t
            }
            settle(Framing.judge(state!, width: W, height: H), now: now)
        } else {
            if now - lastSeen > Framing.forgetMs { state = nil }
            settle(now - lastSeen > Framing.lostMs ? Advice.nobody : candidate, now: now)
        }
        crop = state.map { Framing.crop($0, width: W, height: H) }
    }

    mutating func reset(now: Double) {
        state = nil
        crop = nil
        advice = nil
        candidate = nil
        lastSeen = now                           // a moment's grace before "nobody here"
    }
}

final class Framer {
    static let everyMs: Double = 180             // pose rate, ~5.5 Hz

    /* Read and written on the queue the frames arrive on. */
    private(set) var framing = Framing()
    private var busy = false
    private var lastRun: Double = 0
    private let poseQueue = DispatchQueue(label: "rsl.pose", qos: .userInitiated)
    private let request = VNDetectHumanBodyPoseRequest()

    /* The queue frames arrive on; answers come back to it. */
    var callbackQueue = DispatchQueue.main

    var crop: CGRect? { framing.crop }
    var advice: String? { framing.advice }

    /* Call on every captured frame; hands one to the detector every `everyMs`. */
    func update(_ buffer: CVPixelBuffer, now: Double) {
        guard !busy, now - lastRun >= Framer.everyMs else { return }
        lastRun = now
        busy = true
        let width = CGFloat(CVPixelBufferGetWidth(buffer)), height = CGFloat(CVPixelBufferGetHeight(buffer))
        let home = callbackQueue
        poseQueue.async { [weak self] in
            guard let self = self else { return }
            let points = Framer.detect(buffer, request: self.request)
            home.async {
                self.busy = false
                self.framing.digest(points, width: width, height: height, now: now)
            }
        }
    }

    func reset(now: Double) {
        framing.reset(now: now)
    }

    /* The nose and both shoulders of the most visible person, or nil. */
    static func detect(_ buffer: CVPixelBuffer, request: VNDetectHumanBodyPoseRequest) -> BodyPoints? {
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let people = request.results, !people.isEmpty else { return nil }
        var best: BodyPoints? = nil
        var bestWidth: CGFloat = -1
        for person in people {
            guard let nose = try? person.recognizedPoint(.nose),
                  let left = try? person.recognizedPoint(.leftShoulder),
                  let right = try? person.recognizedPoint(.rightShoulder) else { continue }
            // Vision counts y from the bottom; the rest of the app from the top.
            func point(_ p: VNRecognizedPoint) -> BodyPoints.Point {
                BodyPoints.Point(x: p.location.x, y: 1 - p.location.y, v: CGFloat(p.confidence))
            }
            let width = abs(left.location.x - right.location.x)
            if width > bestWidth {               // the nearest person is the one signing
                bestWidth = width
                best = BodyPoints(nose: point(nose), leftShoulder: point(left), rightShoulder: point(right))
            }
        }
        return best
    }
}
