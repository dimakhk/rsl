import SwiftUI
import UIKit

/* The history screen: a drum of chats, like the time picker in iOS.

   TODO: функция будет добавлена позже (история чатов).
   The list is a placeholder: nothing is stored, renamed or deleted, and
   choosing a chat only returns to the start screen. */

/* A spring that can be stepped by hand - for the drum, whose position is
   dragged, thrown and then has to settle on a row. (Everything else in the
   app moves on SwiftUI's own springs.) Same numbers as the web app's. */
struct StepSpring {
    var value: CGFloat
    var target: CGFloat
    var velocity: CGFloat = 0
    let stiffness: CGFloat
    let friction: CGFloat
    let precision: CGFloat

    init(_ value: CGFloat, damping: CGFloat = 1, response: CGFloat = 0.4, precision: CGFloat = 0.001) {
        self.value = value
        target = value
        let omega = 2 * .pi / response           // natural frequency, unit mass
        stiffness = omega * omega
        friction = 2 * damping * omega
        self.precision = precision
    }

    var settled: Bool {
        abs(target - value) < precision && abs(velocity) < precision * 10
    }

    mutating func step(_ dt: CGFloat) {
        // Fixed sub-steps: identical motion at 60 Hz and at 120 Hz.
        let h: CGFloat = 1 / 240
        var left = dt
        while left > 1e-6 {
            let s = min(h, left)
            let force = -stiffness * (value - target) - friction * velocity
            velocity += force * s
            value += velocity * s
            left -= h
        }
        if settled {
            value = target
            velocity = 0
        }
    }
}

final class WheelModel: NSObject, ObservableObject {
    struct Row: Identifiable {
        let id = UUID()
        var name: String
        var grow: CGFloat                        // 0 just inserted ... 1 full size
    }

    static let step: CGFloat = 43                // mockup points between rows

    @Published private(set) var rows: [Row] = []
    @Published private(set) var position: CGFloat = 0

    var reduceMotion = false
    private var pos = StepSpring(0, damping: 0.85, response: 0.45)
    private var growing: [(id: UUID, spring: StepSpring, done: () -> Void)] = []
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0

    var centre: Int {
        max(0, min(rows.count - 1, Int(pos.value.rounded())))
    }

    func build(_ names: [String], current: Int) {
        rows = names.map { Row(name: $0, grow: 1) }
        growing.removeAll()
        pos.value = CGFloat(current)
        pos.target = CGFloat(current)
        pos.velocity = 0
        position = pos.value
    }

    /* While a finger holds the drum. */
    func hold(at value: CGFloat) {
        pos.value = value
        pos.target = value
        pos.velocity = 0
        position = value
    }

    func go(_ index: Int, velocity: CGFloat = 0) {
        let target = CGFloat(max(0, min(rows.count - 1, index)))
        pos.target = target
        if reduceMotion {
            pos.value = target
            pos.velocity = 0
            position = target
            return
        }
        pos.velocity += velocity
        run()
    }

    /* A new chat opens up in the middle of the wheel, pushing the rest apart. */
    func insert(_ name: String, at index: Int, done: @escaping () -> Void) {
        let i = max(0, min(rows.count, index))
        let row = Row(name: name, grow: reduceMotion ? 1 : 0)
        rows.insert(row, at: i)
        go(i)
        if reduceMotion {
            done()
            return
        }
        var spring = StepSpring(0, damping: 0.7, response: 0.45)
        spring.target = 1
        growing.append((row.id, spring, done))
        run()
    }

    private func run() {
        guard link == nil else { return }
        last = 0
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick(_ l: CADisplayLink) {
        // Clamped: after a stall motion must catch up smoothly, not teleport.
        let dt = last == 0 ? 1.0 / 60 : min(max(l.timestamp - last, 0), 1.0 / 30)
        last = l.timestamp
        pos.step(CGFloat(dt))
        position = pos.value
        var finished: [() -> Void] = []
        for i in growing.indices {
            growing[i].spring.step(CGFloat(dt))
            if let r = rows.firstIndex(where: { $0.id == growing[i].id }) {
                rows[r].grow = clamp01(growing[i].spring.value)
            }
            if growing[i].spring.settled { finished.append(growing[i].done) }
        }
        growing.removeAll { $0.spring.settled }
        if pos.settled && growing.isEmpty {
            link?.invalidate()
            link = nil
        }
        finished.forEach { $0() }
    }
}

struct WheelView: View {
    @ObservedObject var wheel: WheelModel
    let onChoose: (Int) -> Void
    @Environment(\.metrics) private var m
    @Environment(\.accessibilityReduceMotion) private var reduce

    @State private var dragStart: CGFloat? = nil
    @State private var dragVelocity: CGFloat = 0
    @State private var lastY: CGFloat = 0
    @State private var lastTime = Date()
    @State private var moved: CGFloat = 0

    var body: some View {
        let u = m.u
        GeometryReader { geo in
            ZStack {
                ForEach(placed) { row in
                    Text(row.name)
                        .font(Typeface.font(38 * u))
                        .lineLimit(1)
                        .frame(width: m.width, height: 48 * u)
                        .scaleEffect(row.scale)
                        .rotation3DEffect(.degrees(row.tilt), axis: (x: 1, y: 0, z: 0), perspective: 0.56)
                        .offset(y: row.y * u)
                        .opacity(row.alpha)
                        .accessibilityAddTraits(row.selected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .foregroundStyle(Palette.wine)
            .contentShape(Rectangle())
            .gesture(drag(height: geo.size.height))
        }
        .clipped()
    }

    private struct Placed: Identifiable {
        let id: UUID
        let name: String
        let y: CGFloat
        let scale: CGFloat
        let tilt: Double
        let alpha: Double
        let selected: Bool
    }

    /* Every row by its distance from the centre: size, opacity and tilt all follow from it. */
    private var placed: [Placed] {
        var out: [Placed] = []
        var at: CGFloat = 0                      // rows before this one, counting a growing row in part
        for r in wheel.rows {
            let d = at + (r.grow - 1) / 2 - wheel.position
            at += r.grow
            let ad = abs(d)
            // 38 pt in the centre, 30 pt one row away, smaller and fainter beyond
            let size: CGFloat = ad <= 1 ? 38 - 8 * ad : max(16, 30 - 6 * (ad - 1))
            let alpha: CGFloat = ad <= 1 ? 1 - 0.3 * ad : max(0, 0.7 - 0.4 * (ad - 1))
            let tilt: CGFloat = reduce ? 0 : max(-62, min(62, -d * 16))
            let y: CGFloat = d * WheelModel.step * (1 - 0.03 * min(ad, 3))
            if alpha * r.grow > 0.01 {
                out.append(Placed(id: r.id, name: r.name, y: y, scale: size / 38 * (0.6 + 0.4 * r.grow),
                                  tilt: Double(tilt), alpha: Double(alpha * r.grow), selected: ad < 0.5))
            }
        }
        return out
    }

    /* Drag with inertia, then settle softly on a row. Past either end the
       list resists, like a rubber band. A touch that does not move is a tap. */
    private func drag(height: CGFloat) -> some Gesture {
        let unit = WheelModel.step * m.u
        return DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = wheel.position
                    dragVelocity = 0
                    moved = 0
                    lastY = value.location.y
                    lastTime = value.time
                    wheel.hold(at: wheel.position)
                }
                let dy = value.translation.height
                moved = max(moved, abs(dy))
                var p = (dragStart ?? 0) - dy / unit
                let top = CGFloat(max(0, wheel.rows.count - 1))
                if p < 0 { p *= 0.35 } else if p > top { p = top + (p - top) * 0.35 }
                let dt = max(0.001, value.time.timeIntervalSince(lastTime))
                let v = -(value.location.y - lastY) / unit / CGFloat(dt)
                dragVelocity = dragVelocity + (v - dragVelocity) * 0.5
                lastY = value.location.y
                lastTime = value.time
                wheel.hold(at: p)
            }
            .onEnded { value in
                defer { dragStart = nil }
                if moved < 6 * m.u {
                    let off = Int(((value.location.y - height / 2) / unit).rounded())
                    let i = max(0, min(wheel.rows.count - 1, wheel.centre + off))
                    if off == 0 { onChoose(i) } else { wheel.go(i) }
                    return
                }
                let target = Int((wheel.position + dragVelocity * 0.22).rounded())
                wheel.go(target, velocity: reduce ? 0 : dragVelocity)
            }
    }
}

struct HistoryScreen: View {
    @ObservedObject var model: ChatModel
    @StateObject private var wheel = WheelModel()
    @Environment(\.metrics) private var m
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let u = m.u
        ZStack(alignment: .topLeading) {
            Palette.beige

            // «+» turns a quarter; the new chat unfolds in the wheel, then opens.
            Button(action: add) {
                IconView(icon: Icons.plus, width: 32 * u)
                    .rotationEffect(.degrees(Double(model.plusTurns) * 90))
                    .animation(Motion.pick(Motion.bouncy, reduce: reduce), value: model.plusTurns)
                    .frame(width: 44 * u, height: 44 * u)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Новый чат")
            .place(x: 32 * u, y: m.top + 6 * u, width: 44 * u, height: 44 * u)

            Text("История")
                .font(Typeface.font(20 * u))
                .place(x: 80 * u, y: m.top + 12 * u, width: m.width - 160 * u, height: 32 * u)
                .accessibilityAddTraits(.isHeader)

            Button(action: model.closeHistory) {
                IconView(icon: Icons.close, width: 32 * u)
                    .rotationEffect(.degrees(Double(model.closeTurns) * 90))
                    .animation(Motion.pick(Motion.bouncy, reduce: reduce), value: model.closeTurns)
                    .frame(width: 44 * u, height: 44 * u)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Вернуться в чат")
            .place(x: m.width - 76 * u, y: m.top + 6 * u, width: 44 * u, height: 44 * u)

            WheelView(wheel: wheel, onChoose: model.openChat)
                .place(x: 0, y: m.top + 70 * u, width: m.width,
                       height: max(0, m.height - m.top - m.bottom - 140 * u))

            // Required by the licences of the models. Plain text on purpose.
            Text("Модели: SignFlow-R · SberDevices, hukenovs/slovo · S3D · ai-forever/easy_sign · CC BY-SA 4.0")
                .golos(11, line: 15, u: u)
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.wine.opacity(0.5))
                .frame(width: m.width - 48 * u)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, m.bottom + 14 * u)
                .offset(x: 24 * u)
                .allowsHitTesting(false)
        }
        .foregroundStyle(Palette.wine)
        .frame(width: m.width, height: m.height)
        .onAppear {
            wheel.reduceMotion = reduce
            wheel.build(model.chats, current: model.current)
        }
        .onChange(of: model.historyOpen) { _, open in
            wheel.reduceMotion = reduce
            if open { wheel.build(model.chats, current: model.current) }
        }
    }

    private func add() {
        guard let i = model.addChat(after: wheel.centre) else { return }
        wheel.insert(model.chats[i], at: i) { model.chatAdded(i) }
    }
}
