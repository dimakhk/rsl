import SwiftUI

/* The icons come from the designer's SVG files (the icons folder of the repository)
   and are drawn here from the very same path data, so nothing is redrawn by
   hand. This is the part of SVG those files use: path commands
   M L H V C S Q T A Z, absolute and relative. */

enum SVGPath {
    static func parse(_ d: String) -> Path {
        var path = Path()
        var scanner = Reader(d)
        var command: Character = "M"
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint? = nil          // for S and T
        var lastWasCurve: Character = " "

        while let next = scanner.nextCommand(previous: command) {
            command = next
            let relative = command.isLowercase
            let base = relative ? current : .zero
            switch command.uppercased() {
            case "M":
                guard let p = scanner.point() else { return path }
                current = CGPoint(x: base.x + p.x, y: base.y + p.y)
                start = current
                path.move(to: current)
                command = relative ? "l" : "L"   // further pairs are line-tos
                lastWasCurve = " "
            case "L":
                guard let p = scanner.point() else { return path }
                current = CGPoint(x: base.x + p.x, y: base.y + p.y)
                path.addLine(to: current)
                lastWasCurve = " "
            case "H":
                guard let x = scanner.number() else { return path }
                current.x = (relative ? current.x : 0) + x
                path.addLine(to: current)
                lastWasCurve = " "
            case "V":
                guard let y = scanner.number() else { return path }
                current.y = (relative ? current.y : 0) + y
                path.addLine(to: current)
                lastWasCurve = " "
            case "C":
                guard let a = scanner.point(), let b = scanner.point(), let p = scanner.point() else { return path }
                let c1 = CGPoint(x: base.x + a.x, y: base.y + a.y)
                let c2 = CGPoint(x: base.x + b.x, y: base.y + b.y)
                current = CGPoint(x: base.x + p.x, y: base.y + p.y)
                path.addCurve(to: current, control1: c1, control2: c2)
                lastControl = c2
                lastWasCurve = "C"
            case "S":
                guard let b = scanner.point(), let p = scanner.point() else { return path }
                let c1 = lastWasCurve == "C" && lastControl != nil
                    ? CGPoint(x: 2 * current.x - lastControl!.x, y: 2 * current.y - lastControl!.y) : current
                let c2 = CGPoint(x: base.x + b.x, y: base.y + b.y)
                current = CGPoint(x: base.x + p.x, y: base.y + p.y)
                path.addCurve(to: current, control1: c1, control2: c2)
                lastControl = c2
                lastWasCurve = "C"
            case "Q":
                guard let a = scanner.point(), let p = scanner.point() else { return path }
                let c = CGPoint(x: base.x + a.x, y: base.y + a.y)
                current = CGPoint(x: base.x + p.x, y: base.y + p.y)
                path.addQuadCurve(to: current, control: c)
                lastControl = c
                lastWasCurve = "Q"
            case "T":
                guard let p = scanner.point() else { return path }
                let c = lastWasCurve == "Q" && lastControl != nil
                    ? CGPoint(x: 2 * current.x - lastControl!.x, y: 2 * current.y - lastControl!.y) : current
                current = CGPoint(x: base.x + p.x, y: base.y + p.y)
                path.addQuadCurve(to: current, control: c)
                lastControl = c
                lastWasCurve = "Q"
            case "A":
                guard let rx = scanner.number(), let ry = scanner.number(), let rotation = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(), let p = scanner.point() else { return path }
                let end = CGPoint(x: base.x + p.x, y: base.y + p.y)
                addArc(to: &path, from: current, to: end, rx: rx, ry: ry,
                       rotation: rotation * .pi / 180, large: large, sweep: sweep)
                current = end
                lastWasCurve = " "
            case "Z":
                path.closeSubpath()
                current = start
                lastWasCurve = " "
            default:
                return path
            }
        }
        return path
    }

    /* An SVG arc is given by its two ends; Core Graphics wants a centre.
       The conversion is the one from the SVG specification (F.6.5), and the
       arc is then laid down as cubic curves of at most a quarter turn. */
    private static func addArc(to path: inout Path, from p0: CGPoint, to p1: CGPoint,
                               rx rxIn: CGFloat, ry ryIn: CGFloat, rotation phi: CGFloat,
                               large: Bool, sweep: Bool) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 || p0 == p1 {
            path.addLine(to: p1)
            return
        }
        let cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosP * dx + sinP * dy
        let y1 = -sinP * dx + cosP * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            rx *= sqrt(lambda)
            ry *= sqrt(lambda)
        }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var k = den == 0 ? 0 : sqrt(max(0, num / den))
        if large == sweep { k = -k }
        let cx1 = k * rx * y1 / ry
        let cy1 = -k * ry * x1 / rx
        let cx = cosP * cx1 - sinP * cy1 + (p0.x + p1.x) / 2
        let cy = sinP * cx1 + cosP * cy1 + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let pieces = max(1, Int(ceil(abs(delta) / (.pi / 2) - 1e-9)))
        let step = delta / CGFloat(pieces)
        let t = 4 / 3 * tan(step / 4)
        func point(_ a: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(a) * cosP - ry * sin(a) * sinP,
                    y: cy + rx * cos(a) * sinP + ry * sin(a) * cosP)
        }
        func tangent(_ a: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(a) * cosP - ry * cos(a) * sinP,
                    y: -rx * sin(a) * sinP + ry * cos(a) * cosP)
        }
        var a = theta
        for _ in 0..<pieces {
            let b = a + step
            let pa = point(a), pb = point(b)
            let ta = tangent(a), tb = tangent(b)
            path.addCurve(to: pb,
                          control1: CGPoint(x: pa.x + t * ta.x, y: pa.y + t * ta.y),
                          control2: CGPoint(x: pb.x - t * tb.x, y: pb.y - t * tb.y))
            a = b
        }
    }

    /* Reads numbers and command letters out of path data. Numbers may run
       together ("1.5-2", ".5.5"), and commas are just spaces. */
    private struct Reader {
        private let chars: [Character]
        private var at = 0

        init(_ text: String) { chars = Array(text) }

        private mutating func skipSpace() {
            while at < chars.count, chars[at] == " " || chars[at] == "," || chars[at] == "\n" || chars[at] == "\t" || chars[at] == "\r" {
                at += 1
            }
        }

        /* The next command: a letter if there is one, otherwise the previous
           command again (a run of coordinates repeats it). */
        mutating func nextCommand(previous: Character) -> Character? {
            skipSpace()
            guard at < chars.count else { return nil }
            let c = chars[at]
            if c.isLetter && c != "e" && c != "E" {
                at += 1
                return c
            }
            return previous == "Z" || previous == "z" ? nil : previous
        }

        mutating func number() -> CGFloat? {
            skipSpace()
            var text = ""
            var seenDot = false, seenDigit = false, seenExp = false
            while at < chars.count {
                let c = chars[at]
                if c.isNumber {
                    seenDigit = true
                } else if c == "." {
                    if seenDot || seenExp { break }
                    seenDot = true
                } else if c == "-" || c == "+" {
                    if !text.isEmpty && !(text.last == "e" || text.last == "E") { break }
                } else if c == "e" || c == "E" {
                    if !seenDigit || seenExp { break }
                    seenExp = true
                } else {
                    break
                }
                text.append(c)
                at += 1
            }
            guard seenDigit, let v = Double(text) else { return nil }
            return CGFloat(v)
        }

        mutating func point() -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return CGPoint(x: x, y: y)
        }

        /* Arc flags are single digits and may be written without a space. */
        mutating func flag() -> Bool? {
            skipSpace()
            guard at < chars.count, chars[at] == "0" || chars[at] == "1" else { return nil }
            defer { at += 1 }
            return chars[at] == "1"
        }
    }
}

/* One icon: its box in the file's own units and what is drawn in it. */
struct Icon {
    struct Part {
        let path: Path
        let stroke: CGFloat?                     // line width, or nil for a filled shape

        static func stroke(_ d: String, _ width: CGFloat) -> Part { Part(path: SVGPath.parse(d), stroke: width) }
        static func fill(_ d: String) -> Part { Part(path: SVGPath.parse(d), stroke: nil) }
    }

    let box: CGRect
    let parts: [Part]

    init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, parts: [Part]) {
        box = CGRect(x: x, y: y, width: width, height: height)
        self.parts = parts
    }
}

/* Draws an icon `width` points wide in the current foreground colour.
   `drawn` says how much of a stroked part is drawn, from its start (1 when
   not named) - which is how a line is drawn or pulled back. */
struct IconView: View {
    let icon: Icon
    let width: CGFloat
    var drawn: [Int: CGFloat] = [:]

    var body: some View {
        let scale = width / icon.box.width
        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .translatedBy(x: -icon.box.minX, y: -icon.box.minY)
        ZStack {
            ForEach(icon.parts.indices, id: \.self) { i in
                let part = icon.parts[i]
                let shape = part.path.applying(transform)
                if let line = part.stroke {
                    let amount = drawn[i] ?? 1
                    shape
                        .trim(from: 0, to: max(0, min(1, amount)))
                        .stroke(style: StrokeStyle(lineWidth: line * scale, lineCap: .round, lineJoin: .round))
                        .opacity(amount <= 0.001 ? 0 : 1)        // a round cap would leave a dot
                } else {
                    shape.fill()
                }
            }
        }
        .frame(width: width, height: icon.box.height * scale)
    }
}
