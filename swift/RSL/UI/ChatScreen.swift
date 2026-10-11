import AVFoundation
import SwiftUI
import UIKit

/* The chat: top bar, camera, messages, the wave, the three pills and the
   input strip. Every element is placed where the mockup has it, in mockup
   points from the top-left corner of the phone. */

// MARK: top bar

struct TopBar: View {
    @ObservedObject var model: ChatModel
    @Environment(\.metrics) private var m
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let u = m.u
        let cam: CGFloat = model.mode == .gesture ? 1 : 0
        ZStack(alignment: .topLeading) {
            // Icons are 24-28 wide, the button around them never less than 44.
            Button(action: model.openHistory) {
                TwoTone(cam: cam) { IconView(icon: Icons.history, width: 24 * u) }
                    .frame(width: 44 * u, height: 44 * u)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("История чатов")
            .place(x: 31 * u, y: -6 * u, width: 44 * u, height: 44 * u)

            TwoTone(cam: cam) {
                Text(model.title)
                    .font(Typeface.font(20 * u))
                    .lineLimit(1)
            }
            .place(x: 80 * u, y: 0, width: m.width - 160 * u, height: 32 * u)
            .contentShape(Rectangle())
            .onTapGesture(count: 3) { model.debugShown.toggle() }    // what the model sees, for checking
            .accessibilityAddTraits(.isHeader)

            Button(action: model.toggleSound) {
                TwoTone(cam: cam) {
                    SoundIcon(v: model.sound ? 1 : 0, width: 28 * u)
                        .animation(Motion.pick(Motion.soft, reduce: reduce), value: model.sound)
                }
                .frame(width: 44 * u, height: 44 * u)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Озвучка")
            .accessibilityValue(model.sound ? "включена" : "выключена")
            .place(x: m.width - 76 * u, y: -6 * u, width: 44 * u, height: 44 * u)
        }
        .frame(width: m.width, height: 32 * u, alignment: .topLeading)
        .animation(Motion.pick(Motion.screen, reduce: reduce), value: model.mode)
    }
}

// MARK: camera

/* The picture from the camera. The layer mirrors the front camera by itself,
   as a selfie camera shows it. */
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let running: Bool                            // changes when the camera starts, so the layer is set up then

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = Palette.uiWine
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        if let connection = view.previewLayer.connection, connection.isVideoRotationAngleSupported(90),
           connection.videoRotationAngle != 90 {
            connection.videoRotationAngle = 90               // portrait
        }
    }
}

struct CameraBlock: View {
    @ObservedObject var model: ChatModel
    @Environment(\.metrics) private var m
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var pulse = false

    var body: some View {
        let u = m.u
        let height = m.top + 408 * u                 // 467 in the mockup, 59 of it safe area
        let open = model.mode == .gesture
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: 65 * u, bottomTrailingRadius: 65 * u)
        ZStack(alignment: .top) {
            // A soft burgundy light under the camera's rounded edge while
            // someone is in the frame. Only its opacity breathes.
            shape.fill(Palette.wine)
                .shadow(color: Palette.wine.opacity(0.7), radius: 13 * u, y: 6 * u)
                .opacity(model.glow ? (pulse ? 1 : 0.35) : 0)

            ZStack(alignment: .bottom) {
                Palette.wine
                CameraPreview(session: model.capture.camera.session, running: model.cameraReady)
                    .opacity(model.cameraReady ? 1 : 0)
                    .animation(.easeInOut(duration: 0.35), value: model.cameraReady)
                // A burgundy haze at the top of the picture: the beige bar
                // over it must read on a white wall as well as in a dark room.
                LinearGradient(stops: [
                    .init(color: Palette.wine.opacity(0.72), location: 0),
                    .init(color: Palette.wine.opacity(0.45), location: 0.55),
                    .init(color: Palette.wine.opacity(0), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                    .frame(height: m.top + 78 * u)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                plaque
                    .padding(.bottom, 22 * u)
            }
            .clipShape(shape)
        }
        .frame(width: m.width, height: height)
        .offset(y: open || reduce ? 0 : -1.05 * height)
        .opacity(reduce && !open ? 0 : 1)
        .animation(Motion.pick(Motion.screen, reduce: reduce), value: model.mode)
        .onChange(of: model.glow) { _, on in
            if on && !reduce {
                pulse = false
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { pulse = true }
            } else {
                withAnimation(.easeInOut(duration: 0.5)) { pulse = on }
            }
        }
        .onAppear { model.capture.setView(aspect: m.width / height) }
        .onChange(of: m) { _, now in model.capture.setView(aspect: now.width / (now.top + 408 * now.u)) }
        .accessibilityHidden(!open)
    }

    /* «Подойдите ближе», «Встаньте по центру» ... slides up into the camera;
       a new text replaces the old one the same way. */
    private var plaque: some View {
        let u = m.u
        return ZStack {
            if let text = model.plaque {
                Text(text)
                    .font(Typeface.font(17 * u))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.beige)
                    .padding(.horizontal, 18 * u)
                    .padding(.vertical, 7 * u)
                    .background(RoundedRectangle(cornerRadius: 20 * u).fill(Palette.wine.opacity(0.78)))
                    .frame(maxWidth: 320 * u)
                    .transition(AnyTransition.rise(16 * u, reduce: reduce))
                    .id(text)
            }
        }
        .animation(Motion.pick(.spring(response: 0.32, dampingFraction: 0.85), reduce: reduce), value: model.plaque)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: messages

private let tailIcon = Icon(x: 157, y: 19, width: 22, height: 25, parts: Icons.bubble.parts)

struct BubbleRow: View {
    let message: Message
    @ObservedObject var model: ChatModel
    @Environment(\.metrics) private var m
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var flight = CGSize.zero
    @State private var took = false

    var body: some View {
        let u = m.u
        let right = message.side == .right
        HStack(spacing: 0) {
            if right { Spacer(minLength: 0) }
            content
                .padding(.horizontal, 20 * u)
                .padding(.vertical, 7.5 * u)
                .frame(minHeight: 40 * u)
                .foregroundStyle(Palette.beige)
                .background(RoundedRectangle(cornerRadius: 20 * u).fill(Palette.wine))
                // The tail is the one from icons/bubble.svg, cut out by its own bounds.
                .background(alignment: right ? .bottomTrailing : .bottomLeading) {
                    IconView(icon: tailIcon, width: 22 * u)
                        .foregroundStyle(Palette.wine)
                        .scaleEffect(x: right ? 1 : -1, y: 1)
                        .offset(x: right ? 2 * u : -2 * u, y: 4 * u)
                }
                .frame(maxWidth: 295 * u, alignment: right ? .trailing : .leading)     // ~75% of the screen
                .background(GeometryReader { g in
                    Color.clear.onAppear { takeOff(to: g.frame(in: .named("phone"))) }
                })
                .offset(flight)
            if !right { Spacer(minLength: 0) }
        }
        .padding(right ? .trailing : .leading, right ? 44 * u : 42.5 * u)
        .frame(width: m.width)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var content: some View {
        let u = m.u
        if let text = message.text {
            Text(text)
                .golos(20, line: 25, u: u)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            FlowLayout(spacing: 5.6 * u, lineHeight: 25 * u) {
                ForEach(message.words) { word in
                    Text(word.text)
                        .font(Typeface.font(20 * u))
                        // A word rises 6 points into place.
                        .transition(AnyTransition.rise(6 * u, reduce: reduce))
                }
                if message.dots {
                    DotsView()
                        .offset(y: 4.7 * u)                  // on the baseline of the text
                        .padding(.leading, message.words.isEmpty ? 0 : 0.8 * u)
                        .transition(AnyTransition.opacity)
                }
            }
        }
    }

    /* A typed message starts where the input strip's text was and lands here. */
    private func takeOff(to frame: CGRect) {
        guard !took, let from = message.flightFrom else { return }
        took = true
        flight = CGSize(width: from.minX - frame.minX, height: from.minY - frame.minY)
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { flight = .zero }
        }
    }
}

struct FeedView: View {
    @ObservedObject var model: ChatModel
    let height: CGFloat
    @Environment(\.metrics) private var m
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let u = m.u
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12 * u) {
                    ForEach(model.messages) { message in
                        BubbleRow(message: message, model: model)
                            // A bubble grows out of its tail.
                            .transition(AnyTransition.grow(from: message.side == .right ? .bottomTrailing : .bottomLeading,
                                                           reduce: reduce))
                    }
                }
                .padding(.top, 53 * u)
                .padding(.bottom, 18 * u)
                .frame(width: m.width)
                Color.clear.frame(height: 0).id("end")
            }
            .onChange(of: model.messages) { _, _ in
                withAnimation(Motion.pick(Motion.soft, reduce: reduce)) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: height) { _, _ in
                proxy.scrollTo("end", anchor: .bottom)
            }
        }
        // Messages dissolve into the edges instead of being cut off.
        .mask(LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: min(0.5, 18 * u / max(1, height))),
            .init(color: .black, location: max(0.5, 1 - 14 * u / max(1, height))),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom))
    }
}

// MARK: keyboard strip

/* A text field that grows with its text, up to four lines. Return sends. */
struct GrowingTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var focused: Bool
    var fontSize: CGFloat
    var lineHeight: CGFloat
    var inset: CGFloat
    var maxHeight: CGFloat
    var onSend: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private var attributes: [NSAttributedString.Key: Any] {
        let font = Typeface.uiFont(fontSize)
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        return [.font: font, .foregroundColor: Palette.uiBeige, .paragraphStyle: style,
                .baselineOffset: (lineHeight - font.lineHeight) / 4]
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.tintColor = Palette.uiBeige                 // the caret
        view.textColor = Palette.uiBeige
        view.font = Typeface.uiFont(fontSize)
        view.returnKeyType = .send
        view.autocapitalizationType = .sentences
        view.textContainerInset = UIEdgeInsets(top: inset, left: 0, bottom: inset, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.showsVerticalScrollIndicator = false
        view.isScrollEnabled = false
        view.typingAttributes = attributes
        view.delegate = context.coordinator
        view.accessibilityLabel = "Сообщение"
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text {
            view.text = text
            view.typingAttributes = attributes
            context.coordinator.fit(view)
        }
        if focused && !view.isFirstResponder {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        } else if !focused && view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: GrowingTextView

        init(_ parent: GrowingTextView) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            parent.text = view.text
            view.typingAttributes = parent.attributes
            fit(view)
        }

        func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n" {
                parent.onSend()
                return false
            }
            return true
        }

        func fit(_ view: UITextView) {
            let width = view.bounds.width > 0 ? view.bounds.width : 200
            let natural = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            let wanted = min(max(natural, parent.lineHeight + 2 * parent.inset), parent.maxHeight)
            view.isScrollEnabled = natural > parent.maxHeight + 0.5
            if abs(parent.height - wanted) > 0.5 {
                DispatchQueue.main.async { self.parent.height = wanted }
            }
        }
    }
}

/* The strip that rides on top of the on-screen keyboard. */
struct KeyboardBar: View {
    @ObservedObject var model: ChatModel
    @Binding var barHeight: CGFloat
    @Environment(\.metrics) private var m
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var textHeight: CGFloat = 32

    var body: some View {
        let u = m.u
        ZStack(alignment: .bottomTrailing) {
            GrowingTextView(text: $model.draft, height: $textHeight, focused: model.mode == .keys,
                            fontSize: 18 * u, lineHeight: 24 * u, inset: 4 * u, maxHeight: 104 * u,
                            onSend: model.sendTyped)
                .frame(height: max(32 * u, textHeight))
                .background(GeometryReader { g -> Color in
                    let frame = g.frame(in: .named("phone"))
                    DispatchQueue.main.async { model.inputFrame = frame }
                    return Color.clear
                })
                .padding(.leading, 22 * u)
                .padding(.trailing, 56 * u)
                .padding(.vertical, 2 * u)

            // The cross turns a quarter and the strip goes down with the keyboard.
            Button(action: model.closeKeys) {
                IconView(icon: Icons.close, width: 32 * u)
                    .rotationEffect(.degrees(Double(model.keysCloseTurns) * 90))
                    .animation(Motion.pick(Motion.bouncy, reduce: reduce), value: model.keysCloseTurns)
                    .frame(width: 44 * u, height: 44 * u)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Закрыть клавиатуру")
            .padding(.trailing, 13 * u)
            .offset(y: 4 * u)
        }
        .foregroundStyle(Palette.beige)
        .frame(width: m.width)
        .background(
            // Longer than the strip: nothing shows between it and the keyboard
            // while the two are still moving.
            UnevenRoundedRectangle(topLeadingRadius: 22 * u, topTrailingRadius: 22 * u)
                .fill(Palette.wine)
                .padding(.bottom, -80 * u)
        )
        .background(GeometryReader { g -> Color in
            let h = g.size.height
            DispatchQueue.main.async { if abs(barHeight - h) > 0.5 { barHeight = h } }
            return Color.clear
        })
    }
}
