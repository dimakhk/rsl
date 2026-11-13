import SwiftUI
import UIKit

/* The look of the app, after the Figma mockup (393x852, iPhone 15/16).

   Two colours and nothing else. Every size is mockup points times `u`, so on
   a 393-wide phone it is 1:1 and on any other it scales by width. Things at
   the top hang from the top safe area, things at the bottom stand on the
   bottom one. */

enum Palette {
    static let beige = Color(red: 0xEE / 255, green: 0xED / 255, blue: 0xDE / 255)
    static let wine = Color(red: 0x82 / 255, green: 0x14 / 255, blue: 0x14 / 255)
    static let uiBeige = UIColor(red: 0xEE / 255, green: 0xED / 255, blue: 0xDE / 255, alpha: 1)
    static let uiWine = UIColor(red: 0x82 / 255, green: 0x14 / 255, blue: 0x14 / 255, alpha: 1)
}

struct Metrics: Equatable {
    var u: CGFloat = 1                           // points per mockup point
    var width: CGFloat = 393                     // the phone-shaped column
    var height: CGFloat = 852
    var top: CGFloat = 59                        // safe areas
    var bottom: CGFloat = 34

    init() {}

    /* On a wide screen (an iPad) the app stays a phone-shaped column. */
    init(size: CGSize, safeTop: CGFloat, safeBottom: CGFloat) {
        width = min(size.width, size.height * 0.6)
        height = size.height
        u = width / 393
        top = safeTop
        bottom = safeBottom
    }
}

private struct MetricsKey: EnvironmentKey {
    static let defaultValue = Metrics()
}

extension EnvironmentValues {
    var metrics: Metrics {
        get { self[MetricsKey.self] }
        set { self[MetricsKey.self] = newValue }
    }
}

/* Springs given the way Apple gives them: a response time and a damping
   ratio. A spring starts from what is on screen and keeps its velocity when
   retargeted, so every transition can be interrupted. With "Reduce Motion"
   on, the same values are reached by a short fade. */
enum Motion {
    static let soft = Animation.spring(response: 0.4, dampingFraction: 1)       // settles without overshoot
    static let screen = Animation.spring(response: 0.5, dampingFraction: 1)     // the big moves between screens
    static let bouncy = Animation.spring(response: 0.35, dampingFraction: 0.6)  // a little overshoot
    static let press = Animation.spring(response: 0.28, dampingFraction: 0.55)
    static let fade = Animation.linear(duration: 0.15)

    static func pick(_ animation: Animation, reduce: Bool) -> Animation {
        reduce ? fade : animation
    }
}

enum Typeface {
    static let name = "Golos Text"

    static func font(_ size: CGFloat) -> Font {
        .custom(name, fixedSize: size)
    }

    static func uiFont(_ size: CGFloat) -> UIFont {
        UIFont(name: name, size: size) ?? UIFont(name: "GolosText-Regular", size: size) ?? .systemFont(ofSize: size)
    }

    /* Extra space between lines that makes them `line` apart, as in the mockup. */
    static func spacing(size: CGFloat, line: CGFloat) -> CGFloat {
        max(0, line - uiFont(size).lineHeight)
    }
}

extension View {
    /* Text of the mockup: a size and a line height, both in mockup points. */
    func golos(_ size: CGFloat, line: CGFloat, u: CGFloat) -> some View {
        font(Typeface.font(size * u))
            .lineSpacing(Typeface.spacing(size: size * u, line: line * u))
    }

    /* Puts a view at a place given from the top-left corner of the phone.
       The parent is a ZStack aligned to the top-left. */
    func place(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> some View {
        frame(width: width, height: height)
            .offset(x: x, y: y)
    }
}

/* A press: squeeze and spring back. */
struct PressStyle: ButtonStyle {
    var depth: CGFloat = 0.12

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1 - depth : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

extension AnyTransition {
    /* Fades in while rising `y` points into place. */
    static func rise(_ y: CGFloat, reduce: Bool) -> AnyTransition {
        reduce ? AnyTransition.opacity : AnyTransition.opacity.combined(with: AnyTransition.offset(x: 0, y: y))
    }

    /* Grows out of a corner: scale 0.8 -> 1 and a fade. */
    static func grow(from anchor: UnitPoint, reduce: Bool) -> AnyTransition {
        reduce ? AnyTransition.opacity
               : AnyTransition.scale(scale: 0.8, anchor: anchor).combined(with: AnyTransition.opacity)
    }
}

func clamp01(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }
