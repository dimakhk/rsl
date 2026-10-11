import SwiftUI

/* Small pieces the screens are built from: the two-tone bar content, the
   icons that redraw themselves, the pills, the wave. */

/* Over the camera the bar turns beige with a soft shadow, so that it reads on
   any picture. Both versions are there all the time and cross-fade with `cam`
   (0 camera away ... 1 camera open). */
struct TwoTone<Content: View>: View {
    let cam: CGFloat
    @ViewBuilder var content: Content
    @Environment(\.metrics) private var m

    var body: some View {
        ZStack {
            content
                .foregroundStyle(Palette.wine)
                .opacity(1 - cam)
            content
                .foregroundStyle(Palette.beige)
                .shadow(color: Color(red: 80 / 255, green: 8 / 255, blue: 8 / 255).opacity(0.7), radius: 2 * m.u, y: 1 * m.u)
                .opacity(cam)
        }
    }
}

/* The sound icon. On: the arcs fan out of the speaker one after another.
   Off: they fold back and the slash is drawn. Both end as the original files.
   `v` runs from 0 (off) to 1 (on) on a spring. */
struct SoundIcon: View, Animatable {
    var v: CGFloat
    let width: CGFloat

    var animatableData: CGFloat {
        get { v }
        set { v = newValue }
    }

    var body: some View {
        ZStack {
            IconView(icon: Icons.soundOn, width: width,
                     drawn: [1: clamp01((v - 0.4) / 0.3), 2: clamp01((v - 0.62) / 0.38)])
                .opacity(clamp01((v - 0.3) / 0.25))
            IconView(icon: Icons.soundOff, width: width, drawn: [2: 1 - clamp01(v / 0.45)])
                .opacity(clamp01((0.55 - v) / 0.25))
        }
    }
}

/* The microphone: the slash is drawn across it or pulled back. */
struct MicIcon: View, Animatable {
    var v: CGFloat                               // 0 off (crossed out) ... 1 on
    let width: CGFloat

    var animatableData: CGFloat {
        get { v }
        set { v = newValue }
    }

    var body: some View {
        ZStack {
            IconView(icon: Icons.mic, width: width)
                .opacity(clamp01((v - 0.45) / 0.3))
            IconView(icon: Icons.micOff, width: width, drawn: [4: 1 - clamp01(v / 0.6)])
                .opacity(clamp01((0.75 - v) / 0.3))
        }
    }
}

/* A pill has two faces - burgundy on beige, beige on burgundy (over the wave)
   - and two states. Everything is there at once; `active` and `onWave` only
   set opacities and one scale, each on its own spring. */
struct PillView<IconContent: View>: View {
    let active: Bool
    let onWave: Bool
    let breathing: Bool
    @ViewBuilder var icon: IconContent

    @Environment(\.metrics) private var m
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var breath = false

    var body: some View {
        let u = m.u
        let a: CGFloat = active ? 1 : 0
        let w: CGFloat = onWave ? 1 : 0
        let light = a + w - 2 * a * w            // beige icon: on a burgundy fill, or on the wave while not filled
        ZStack {
            // The fill spreads from the centre: a disc that outgrows the pill.
            Circle().fill(Palette.wine)
                .frame(width: 112 * u, height: 112 * u)
                .scaleEffect(a)
                .opacity(1 - w)
            // Over the wave the active pill is drawn as in the mockup: its
            // 5-wide ring stays burgundy - so it melts into the wave - and
            // the beige fill sits inside it.
            Circle().fill(Palette.beige)
                .frame(width: 112 * u, height: 112 * u)
                .scaleEffect(a)
                .opacity(w)
                .frame(width: 78 * u, height: 50 * u)
                .clipShape(RoundedRectangle(cornerRadius: 25 * u))
            Capsule().strokeBorder(Palette.wine, lineWidth: 5 * u)
                .opacity(1 - w)
            Capsule().strokeBorder(Palette.beige, lineWidth: 5 * u)
                .opacity(w * (1 - a))
            icon.foregroundStyle(Palette.wine).opacity(1 - light)
            icon.foregroundStyle(Palette.beige).opacity(light)
        }
        .frame(width: 88 * u, height: 60 * u)
        .clipShape(Capsule())
        .contentShape(Capsule())
        .animation(Motion.pick(.spring(response: 0.38, dampingFraction: 0.8), reduce: reduce), value: active)
        .animation(Motion.pick(Motion.screen, reduce: reduce), value: onWave)
        .scaleEffect(breath ? 1.03 : 1)
        .onChange(of: breathing) { _, on in
            if on && !reduce {
                withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { breath = true }
            } else {
                withAnimation(.easeInOut(duration: 0.3)) { breath = false }
            }
        }
    }
}

/* The wavy edge: seven waves over two screen widths (3.5 a screen), as drawn. */
struct WaveCrest: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        var x: CGFloat = 0
        while x <= 786 {
            let y = 12 - 11 * sin((x / (786 / 7)) * 2 * .pi + 0.6)
            p.addLine(to: CGPoint(x: rect.minX + x / 786 * rect.width, y: rect.minY + y / 24 * rect.height))
            x += 3
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/* The burgundy panel of the voice screen. Its edge flows sideways - sliding
   by exactly one wave brings it back onto itself - and breathes a little. */
struct WaveView: View {
    @Environment(\.metrics) private var m
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var flow = false
    @State private var breathe = false

    var body: some View {
        let u = m.u
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Palette.wine)
                .padding(.top, 23 * u)
            WaveCrest().fill(Palette.wine)
                .frame(width: m.width * 2, height: 24 * u)
                .offset(x: flow ? -m.width * 2 / 7 : 0)
                .frame(width: m.width, height: 24 * u, alignment: .leading)
                .scaleEffect(x: 1, y: reduce ? 1 : (breathe ? 1.06 : 0.82), anchor: .bottom)
        }
        .frame(width: m.width, height: m.bottom + 121 * u)
        .onAppear {
            guard !reduce else { return }
            withAnimation(.linear(duration: 5).repeatForever(autoreverses: false)) { flow = true }
            withAnimation(.easeInOut(duration: 3.4).repeatForever(autoreverses: true)) { breathe = true }
        }
        .allowsHitTesting(false)
    }
}

/* Three dots, as in a messenger: more is coming. */
struct DotsView: View {
    @Environment(\.metrics) private var m
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let u = m.u
        TimelineView(.animation(paused: reduce)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3.5 * u) {
                ForEach(0..<3, id: \.self) { i in
                    let v = reduce ? 0.6 : DotsView.blink(t - Double(i) * 0.18)
                    Circle()
                        .frame(width: 4.5 * u, height: 4.5 * u)
                        .opacity(0.25 + 0.75 * v)
                        .offset(y: -2.5 * u * v)
                }
            }
        }
    }

    /* 0 at rest, up to 1 a third of the way through each 1.2 s and back. */
    static func blink(_ time: Double) -> CGFloat {
        var phase = time.truncatingRemainder(dividingBy: 1.2) / 1.2
        if phase < 0 { phase += 1 }
        let x: Double
        if phase < 0.35 {
            x = phase / 0.35
        } else if phase < 0.7 {
            x = 1 - (phase - 0.35) / 0.35
        } else {
            x = 0
        }
        return CGFloat(x * x * (3 - 2 * x))                      // ease in and out
    }
}

/* Words one after another, wrapping like text. */
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineHeight: CGFloat

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + spacing + size.width > width + 0.5 {
                widest = max(widest, x)
                x = 0
                y += lineHeight
            }
            if x > 0 { x += spacing }
            origins.append(CGPoint(x: x, y: y + (lineHeight - size.height) / 2))
            x += size.width
        }
        return (CGSize(width: max(widest, x), height: y + lineHeight), origins)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .greatestFiniteMagnitude).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = arrange(subviews, width: bounds.width)
        for (s, origin) in zip(subviews, placed.origins) {
            s.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                    proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}
