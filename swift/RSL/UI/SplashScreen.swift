import SwiftUI

/* The splash: both marks are drawn as if by a pen, and end up exactly as
   their files. The house is made of strokes: its own paths are drawn. The
   figure is one filled shape: it stays as it is and is uncovered through a
   mask, by wide "brush" strokes that run along the middle of each part.

   Then one soft pulse, the marks shrink and melt, and the burgundy goes up;
   the start screen is under it. */

/* CSS-style timing curves, so the drawing keeps the pace it has on the web. */
struct TimingCurve {
    let x1: Double, y1: Double, x2: Double, y2: Double

    static let easeOut = TimingCurve(x1: 0, y1: 0, x2: 0.58, y2: 1)
    static let roof = TimingCurve(x1: 0.45, y1: 0, x2: 0.3, y2: 1)
    static let ring = TimingCurve(x1: 0.4, y1: 0, x2: 0.3, y2: 1)

    private func bezier(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
    }

    func callAsFunction(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<24 {                        // the curve is monotonic in x: halve the interval
            let at = bezier(t, x1, x2)
            if abs(at - x) < 1e-5 { break }
            if at < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return bezier(t, y1, y2)
    }
}

struct SplashScreen: View {
    let skip: Bool
    let onDone: () -> Void

    @Environment(\.metrics) private var m
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var started = Date()
    @State private var leaving = false
    @State private var gone = false

    private struct Brush {
        let path: Path
        let width: CGFloat
        let round: Bool
        let start: Double                        // ms
        let duration: Double
        let curve: TimingCurve
    }

    // The house: the roof in one line, then the strokes left to right, like rain.
    private static let houseOrder = [3, 2, 1, 4, 5, 6, 7, 8]

    // The figure in a circle, from when the house is about half drawn (520 ms).
    private static let brushes: [Brush] = {
        let t = 520.0
        func b(_ d: String, _ w: CGFloat, _ round: Bool, _ start: Double, _ ms: Double,
               _ curve: TimingCurve = .easeOut) -> Brush {
            Brush(path: SVGPath.parse(d), width: w, round: round, start: start, duration: ms, curve: curve)
        }
        return [
            b("M52.5 4.3A48.2 48.2 0 1 1 52.49 4.3", 13, false, t, 500, .ring),          // the ring, clockwise from the top
            b("M52.5 21.2A4.1 4.1 0 1 1 52.49 21.2", 9.4, true, t + 470, 160),           // the head, drawn and filled
            b("M25 36.7L44 40.2Q52.5 41.4 61 40.2L80 36.7", 14, true, t + 590, 170),     // arms: left hand, shoulders, right hand
            b("M52.5 39.5L52.5 63.5", 25, false, t + 710, 150),                          // the body, down from the shoulders
            b("M50 60L40.3 84.2", 14, true, t + 820, 160),                               // both legs at once
            b("M55.2 60L65.4 84.2", 14, true, t + 820, 160),
        ]
    }()

    private static func progress(_ ms: Double, start: Double, duration: Double, curve: TimingCurve) -> CGFloat {
        CGFloat(curve((ms - start) / duration))
    }

    var body: some View {
        if !gone {
            let u = m.u
            ZStack(alignment: .topLeading) {
                Palette.wine
                TimelineView(.animation(paused: leaving || reduce || skip)) { context in
                    let ms = leaving || reduce || skip ? 100_000 : context.date.timeIntervalSince(started) * 1000
                    marks(ms)
                        .scaleEffect(pulse(ms))
                }
                .frame(width: 261 * u, height: 116 * u)
                .scaleEffect(leaving && !reduce ? 0.75 : 1)
                .opacity(leaving ? 0 : 1)
                .animation(Motion.pick(Motion.soft, reduce: reduce), value: leaving)
                .offset(x: 66 * u, y: m.height / 2 - 58 * u)
            }
            .frame(width: m.width, height: m.height)
            .offset(y: leaving && !reduce ? -1.03 * m.height : 0)
            .opacity(leaving && reduce ? 0 : 1)
            .animation(Motion.pick(.spring(response: 0.55, dampingFraction: 1), reduce: reduce), value: leaving)
            .accessibilityHidden(true)
            .task {
                started = Date()
                let wait: Double = skip ? 0 : (reduce ? 0.6 : 1.82)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                leaving = true
                onDone()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                gone = true
            }
        }
    }

    /* One soft pulse once both marks are drawn. */
    private func pulse(_ ms: Double) -> CGFloat {
        guard ms > 1520, ms < 1820 else { return 1 }
        return 1 + 0.04 * CGFloat(sin(.pi * (ms - 1520) / 300))
    }

    private func marks(_ ms: Double) -> some View {
        let u = m.u
        var drawn: [Int: CGFloat] = [0: SplashScreen.progress(ms, start: 0, duration: 450, curve: .roof)]
        for (i, k) in SplashScreen.houseOrder.enumerated() {
            drawn[k] = SplashScreen.progress(ms, start: 400 + Double(i) * 70, duration: 200, curve: .easeOut)
        }
        let scale = 105 * u / 105
        return ZStack(alignment: .topLeading) {
            IconView(icon: Icons.logoHouse, width: 138 * u, drawn: drawn)
            IconView(icon: Icons.logoAccess, width: 105 * u)
                .mask {
                    ZStack {
                        ForEach(SplashScreen.brushes.indices, id: \.self) { i in
                            let b = SplashScreen.brushes[i]
                            let p = SplashScreen.progress(ms, start: b.start, duration: b.duration, curve: b.curve)
                            b.path
                                .applying(CGAffineTransform(scaleX: scale, y: scale))
                                .trim(from: 0, to: p)
                                .stroke(style: StrokeStyle(lineWidth: b.width * scale,
                                                           lineCap: b.round ? .round : .butt, lineJoin: .round))
                                .opacity(p <= 0.001 ? 0 : 1)
                        }
                    }
                    .frame(width: 105 * u, height: 105 * u)
                }
                .offset(x: 156 * u, y: 6 * u)
        }
        .foregroundStyle(Palette.beige)
        .frame(width: 261 * u, height: 116 * u, alignment: .topLeading)
    }
}
