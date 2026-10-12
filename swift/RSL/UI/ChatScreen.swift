import AVFoundation
import SwiftUI
import UIKit

/* The chat: top bar, camera, messages and the keyboard's input. Every element
   is placed where the mockup has it, in mockup points from the top-left
   corner of the phone. */

// MARK: top bar

/* The bar's colour follows what is under it: burgundy on the beige screen;
   over the camera, beige on a dark picture and black on a light one. */
struct TopBar: View {
    @ObservedObject var model: ChatModel
    @Environment(\.metrics) private var m
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var soundPressed = false

    var body: some View {
        let u = m.u
        let overCamera = model.mode == .gesture
        let light = model.cameraReady && model.pictureIsLight
        let color: Color = overCamera ? (light ? .black : Palette.beige) : Palette.wine
        ZStack(alignment: .topLeading) {
            // Icons are 24-28 wide, the button around them never less than 44.
            Button(action: model.openHistory) {
                IconView(icon: Icons.history, width: 24 * u)
                    .frame(width: 44 * u, height: 44 * u)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("История чатов")
            .place(x: 31 * u, y: -6 * u, width: 44 * u, height: 44 * u)

            Text(model.title)
                .font(Typeface.font(20 * u))
                .lineLimit(1)
                .frame(width: m.width - 160 * u, height: 32 * u)
                // The tap area is set before the title is moved into place:
                // set after, it stays where the title was laid out - at the
                // left edge, over the history button.
                .contentShape(Rectangle())
                .onTapGesture(count: 3) { model.debugShown.toggle() }    // what the model sees, for checking
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("chat-title")
                .offset(x: 80 * u)

            // A tap turns speaking on and off; a long press changes the voice.
            SoundIcon(v: model.sound ? 1 : 0, width: 28 * u)
                .animation(Motion.pick(Motion.soft, reduce: reduce), value: model.sound)
                .frame(width: 44 * u, height: 44 * u)
                .contentShape(Rectangle())
                .scaleEffect(soundPressed ? 0.88 : 1)
                .animation(Motion.press, value: soundPressed)
                .onTapGesture { model.toggleSound() }
                .onLongPressGesture(minimumDuration: 0.5, perform: { model.switchVoice() },
                                    onPressingChanged: { soundPressed = $0 })
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Озвучка")
                .accessibilityValue((model.sound ? "включена" : "выключена") + ", голос " + model.voice.spokenName)
                .accessibilityAction { model.toggleSound() }
                .accessibilityAction(named: "Сменить голос") { model.switchVoice() }
            .place(x: m.width - 76 * u, y: -6 * u, width: 44 * u, height: 44 * u)
        }
        .foregroundStyle(color)
        .frame(width: m.width, height: 32 * u, alignment: .topLeading)
        .animation(Motion.pick(Motion.screen, reduce: reduce), value: model.mode)
        .animation(Motion.pick(.easeInOut(duration: 0.3), reduce: reduce), value: light)
    }
}

// MARK: camera

/* The picture from the camera. The layer mirrors the front camera by itself,
   as a selfie camera shows it. */
struct CameraPreview: UIViewRepresentable {
    let camera: Camera

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = Palette.uiWine
        view.isUserInteractionEnabled = false
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspectFill
        camera.attach(preview: view.previewLayer)            // the camera keeps it upright
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}
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

            ZStack(alignment: .bottomTrailing) {
                Palette.wine
                CameraPreview(camera: model.capture.camera)
                    .opacity(model.cameraReady ? 1 : 0)
                    .animation(.easeInOut(duration: 0.35), value: model.cameraReady)
                    .allowsHitTesting(false)
                if let light = model.pretendedPicture {      // Simulator screenshots only
                    Color(white: light ? 0.9 : 0.15)
                }
                // Front camera <-> back camera. The arrows turn half a circle
                // on every change and come to rest looking the same.
                Button(action: model.flipCamera) {
                    IconView(icon: Icons.spin, width: 26 * u)
                        .foregroundStyle(Palette.beige)
                        .rotationEffect(.degrees(Double(model.cameraTurns) * 180))
                        .animation(Motion.pick(.spring(response: 0.55, dampingFraction: 0.7), reduce: reduce),
                                   value: model.cameraTurns)
                        .frame(width: 44 * u, height: 44 * u)
                        .background(Circle().fill(Palette.wine.opacity(0.78)))
                        .contentShape(Circle())
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("Сменить камеру")
                .accessibilityValue(model.cameraSide == .front ? "передняя" : "задняя")
                .padding(.trailing, 22 * u)
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
        .onAppear { model.capture.setView(aspect: m.width / height, bar: (m.top + 50 * u) / height) }
        .onChange(of: m) { _, now in
            let h = now.top + 408 * now.u
            model.capture.setView(aspect: now.width / h, bar: (now.top + 50 * now.u) / h)
        }
        .accessibilityHidden(!open)
    }
}

// MARK: messages

/* A message bubble: the rounded body and its tail are one outline.

   The measures are the designer's (icons/bubble.svg: a 177x40 body with
   corners of 20 and a tail at the bottom corner), so a one-line bubble is
   exactly that drawing, and a taller one keeps the same corner. The tail
   reaches a little outside the bubble's own box: 1.4 to the side, 3.1 down. */
struct BubbleShape: Shape {
    var tailOnRight: Bool
    var u: CGFloat

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let r = min(20 * u, h / 2, w / 2)
        var p = Path()
        p.move(to: CGPoint(x: r, y: 0))
        p.addLine(to: CGPoint(x: w - r, y: 0))
        p.addArc(center: CGPoint(x: w - r, y: r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        // down the side to the tail, round its tip, and back along the bottom
        p.addLine(to: CGPoint(x: w, y: max(r, h - 21 * u)))
        p.addLine(to: CGPoint(x: w + 1.194 * u, y: h - 1.497 * u))
        p.addCurve(to: CGPoint(x: w - 3.441 * u, y: h + 2.696 * u),
                   control1: CGPoint(x: w + 1.351 * u, y: h + 1.064 * u),
                   control2: CGPoint(x: w - 0.909 * u, y: h + 3.108 * u))
        p.addLine(to: CGPoint(x: max(r, w - 20 * u), y: h))
        p.addLine(to: CGPoint(x: r, y: h))
        p.addArc(center: CGPoint(x: r, y: h - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: 0, y: r))
        p.addArc(center: CGPoint(x: r, y: r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        // drawn with the tail on the right; mirrored for the other side
        var place = CGAffineTransform(translationX: rect.minX, y: rect.minY)
        if !tailOnRight { place = place.translatedBy(x: w, y: 0).scaledBy(x: -1, y: 1) }
        return p.applying(place)
    }
}

struct BubbleRow: View {
    let message: Message
    @Environment(\.metrics) private var m
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let u = m.u
        let right = message.side == .right
        HStack(spacing: 0) {
            if right { Spacer(minLength: 0) }
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
            .padding(.horizontal, 20 * u)
            .padding(.vertical, 7.5 * u)
            .frame(minHeight: 40 * u)
            .foregroundStyle(Palette.beige)
            .background(BubbleShape(tailOnRight: right, u: u).fill(Palette.wine))
            .frame(maxWidth: 295 * u, alignment: right ? .trailing : .leading)     // ~75% of the screen
            if !right { Spacer(minLength: 0) }
        }
        .padding(right ? .trailing : .leading, right ? 44 * u : 42.5 * u)
        .frame(width: m.width)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message.text)
        .accessibilityIdentifier("message")
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
                        BubbleRow(message: message)
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
            // With the keyboard up: a swipe down the messages puts it away...
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.messages) { _, _ in
                withAnimation(Motion.pick(Motion.soft, reduce: reduce)) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: height) { _, _ in
                proxy.scrollTo("end", anchor: .bottom)
            }
        }
        // ...and so does a tap anywhere on them.
        .contentShape(Rectangle())
        .onTapGesture { model.closeKeys() }
        // Messages dissolve into the edges instead of being cut off.
        .mask(LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: min(0.5, 18 * u / max(1, height))),
            .init(color: .black, location: max(0.5, 1 - 14 * u / max(1, height))),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom))
    }
}

// MARK: keyboard

/* What the keyboard types into. It is not shown: the text appears in the
   chat as it is typed (ChatModel.keyboardWrote). Return sends. */
struct KeyboardInput: UIViewRepresentable {
    @ObservedObject var model: ChatModel

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.textColor = .clear
        view.tintColor = .clear                          // no caret
        view.returnKeyType = .send
        view.autocapitalizationType = .sentences
        view.isScrollEnabled = false
        view.delegate = context.coordinator
        view.accessibilityLabel = "Сообщение"
        view.accessibilityIdentifier = "message-input"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != model.typed { view.text = model.typed }
        let wanted = model.mode == .keys
        if wanted && !view.isFirstResponder {
            DispatchQueue.main.async { if self.model.mode == .keys { view.becomeFirstResponder() } }
        } else if !wanted && view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let model: ChatModel

        init(_ model: ChatModel) { self.model = model }

        func textViewDidChange(_ view: UITextView) {
            model.keyboardWrote(view.text)
        }

        func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n" {
                model.sendTyped()
                view.text = ""
                return false
            }
            return true
        }

        /* The keyboard went away by itself (swiped down): leave the mode too. */
        func textViewDidEndEditing(_ view: UITextView) {
            model.closeKeys()
        }
    }
}
