import Combine
import SwiftUI
import UIKit

/* Puts the screens together. Layers, from the back: messages, the hint text,
   the camera, the wave, the pills, the top bar, the input strip; over them
   the history screen and, at the start, the splash. */

struct RootView: View {
    @StateObject private var model = ChatModel()
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var keyboard: CGFloat = 0
    // Three ways to learn where the keyboard is; the app takes the largest sane answer.
    @State private var fromSafeArea: CGFloat = 0
    @State private var fromNotice: CGFloat = 0
    @State private var fromGuide: CGFloat = 0

    private let keyboardFrames = NotificationCenter.default
        .publisher(for: UIResponder.keyboardWillChangeFrameNotification)

    /* The screen's own safe areas. Asked from the window, because SwiftUI's
       numbers grow by the keyboard's height while it is up. */
    private static func windowInsets() -> UIEdgeInsets? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        return (windows.first { $0.isKeyWindow } ?? windows.first)?.safeAreaInsets
    }

    var body: some View {
        ZStack {
            // Sees the keyboard: this one does not ignore the safe area, and
            // the system counts the keyboard into the bottom of it.
            GeometryReader { probe in
                Color.clear.preference(key: BottomInsetKey.self, value: probe.safeAreaInsets.bottom)
            }
            screen
        }
        .onPreferenceChange(BottomInsetKey.self) { inset in
            fromSafeArea = inset
            settleKeyboard()
        }
        .onReceive(keyboardFrames) { note in
            guard let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
            let screen = UIScreen.main.bounds
            let covered = screen.intersection(end)
            fromNotice = covered.isNull || covered.maxY < screen.maxY - 1 ? 0 : covered.height
            settleKeyboard()
        }
        // Light text in the status bar over burgundy (the splash, the camera), dark over beige.
        .preferredColorScheme(!model.splashDone || (model.mode == .gesture && !model.historyOpen) ? .dark : .light)
        .onAppear {
            model.reduceMotion = reduce
            model.debugShown = Launch.debug
            // Under the unit tests the app is only a host: the tests load the model themselves.
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                model.capture.prepare()
            }
        }
        .onChange(of: reduce) { _, now in model.reduceMotion = now }
    }

    private func settleKeyboard() {
        let home = RootView.windowInsets()?.bottom ?? 0
        let limit = UIScreen.main.bounds.height * 0.6
        let height = [fromSafeArea, fromNotice, fromGuide].filter { $0 > home + 1 && $0 < limit }.max() ?? 0
        guard abs(height - keyboard) > 0.5 else { return }
        // The curve the keyboard itself moves on.
        withAnimation(reduce ? Motion.fade : .interpolatingSpring(mass: 3, stiffness: 1000, damping: 500, initialVelocity: 0)) {
            keyboard = height
        }
    }

    private var screen: some View {
        GeometryReader { geo in
            let insets = RootView.windowInsets()
            let top = insets?.top ?? geo.safeAreaInsets.top
            let bottom = insets?.bottom ?? geo.safeAreaInsets.bottom
            let size = CGSize(width: geo.size.width, height: geo.size.height)
            let m = Metrics(size: size, safeTop: top, safeBottom: bottom)
            ZStack {
                Palette.beige
                KeyboardGuide { height in
                    fromGuide = height
                    settleKeyboard()
                }
                PhoneView(model: model, keyboard: keyboard,
                          keyboardNote: String(format: "клавиатура %.0f: зона %.0f · уведомление %.0f · направляющая %.0f",
                                               keyboard, fromSafeArea, fromNotice, fromGuide))
                    .frame(width: m.width, height: m.height)
                    .clipped()
                    .coordinateSpace(name: "phone")
                    .environment(\.metrics, m)
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
    }
}

/* Asks UIKit where the top of the keyboard is (its keyboard layout guide). */
struct KeyboardGuide: UIViewRepresentable {
    var onChange: (CGFloat) -> Void

    final class GuideView: UIView {
        var onChange: ((CGFloat) -> Void)?
        private let marker = UIView()
        private var last: CGFloat = -1

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            marker.isUserInteractionEnabled = false
            marker.translatesAutoresizingMaskIntoConstraints = false
            addSubview(marker)
            NSLayoutConstraint.activate([
                marker.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
                marker.leadingAnchor.constraint(equalTo: leadingAnchor),
                marker.widthAnchor.constraint(equalToConstant: 1),
                marker.heightAnchor.constraint(equalToConstant: 1),
            ])
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            let height = max(0, bounds.height - marker.frame.minY)
            guard abs(height - last) > 0.5 else { return }
            last = height
            let report = onChange
            DispatchQueue.main.async { report?(height) }
        }
    }

    func makeUIView(context: Context) -> GuideView {
        let view = GuideView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: GuideView, context: Context) {
        view.onChange = onChange
    }
}

private struct BottomInsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PhoneView: View {
    @ObservedObject var model: ChatModel
    let keyboard: CGFloat
    var keyboardNote = ""
    @Environment(\.metrics) private var m
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var barHeight: CGFloat = 36

    private static let intro = "Чтобы начать чат\nвыберите один из способов взаимодействия."

    var body: some View {
        let u = m.u
        ZStack(alignment: .topLeading) {
            chat
                // The chat behind the history steps back a little and comes
                // forward again when it closes.
                .scaleEffect(model.historyOpen && !reduce ? 0.96 : 1)

            HistoryScreen(model: model)
                .offset(y: model.historyOpen || reduce ? 0 : 1.02 * m.height)
                .opacity(reduce && !model.historyOpen ? 0 : 1)
                .accessibilityHidden(!model.historyOpen)

            SplashScreen(skip: Launch.noSplash, frozenAt: Launch.splashAt, onDone: {
                model.splashFinished()
                Launch.apply(to: model)
            })

            if model.debugShown {
                DebugBox(model: model, keyboardNote: keyboardNote)
                    .place(x: 8 * u, y: m.top + 50 * u, width: 300 * u, height: 150 * u)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: m.width, height: m.height, alignment: .topLeading)
        .background(Palette.beige)
        .animation(Motion.pick(Motion.screen, reduce: reduce), value: model.historyOpen)
    }

    private var chat: some View {
        let u = m.u
        let cameraOpen = model.mode == .gesture
        let keys = model.mode == .keys

        // The messages: y 150 without the camera, under it (467) with.
        let feedTop = m.top + (cameraOpen ? 408 : 91) * u
        // How far the feed's bottom edge stands off the bottom of the screen.
        var feedBottom = m.bottom + 83 * u                       // above the pills
        if model.mode == .voice { feedBottom = m.bottom + 131 * u }      // above the wave
        if keys { feedBottom = keyboard + barHeight + 6 * u }
        let feedHeight = max(0, m.height - feedTop - feedBottom)
        let waveHeight = m.bottom + 121 * u                      // its crests reach y 697

        return ZStack(alignment: .topLeading) {
            FeedView(model: model, height: feedHeight)
                .place(x: 0, y: feedTop, width: m.width, height: feedHeight)
                .animation(Motion.pick(Motion.screen, reduce: reduce), value: model.mode)

            // «Чтобы начать чат…»: comes up from below, leaves upwards.
            ZStack {
                if model.introShown {
                    Text(PhoneView.intro)
                        .golos(20, line: 25, u: u)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Palette.wine.opacity(0.76))
                        .frame(width: 358 * u)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(reduce ? AnyTransition.opacity : AnyTransition.asymmetric(
                            insertion: AnyTransition.rise(14 * u, reduce: false),
                            removal: AnyTransition.rise(-14 * u, reduce: false)))
                }
            }
            // three lines of 25: the block is centred on y 425.5, as in the mockup
            .place(x: (m.width - 358 * u) / 2, y: m.height / 2 - 38 * u, width: 358 * u, height: 75 * u)
            .animation(Motion.pick(Motion.soft, reduce: reduce), value: model.introShown)
            .allowsHitTesting(false)

            CameraBlock(model: model)

            WaveView()
                .offset(y: m.height - waveHeight + (model.mode == .voice || reduce ? 0 : 1.12 * waveHeight))
                .opacity(reduce && model.mode != .voice ? 0 : 1)
                .animation(Motion.pick(Motion.screen, reduce: reduce), value: model.mode)

            dock

            TopBar(model: model)
                .offset(y: m.top + 12 * u)

            KeyboardBar(model: model, barHeight: $barHeight)
                .frame(width: m.width, height: m.height, alignment: .bottom)
                .offset(y: -keyboard + (keys || reduce ? 0 : 1.15 * barHeight + 80 * u))
                .opacity(reduce && !keys ? 0 : 1)
                .animation(Motion.pick(Motion.soft, reduce: reduce), value: model.mode)
                .accessibilityHidden(!keys)
        }
        .frame(width: m.width, height: m.height, alignment: .topLeading)
    }

    /* The three pills. Each has one offset: its entrance from below after the
       splash, and the whole dock leaving when the keyboard opens. */
    private var dock: some View {
        let u = m.u
        let y = m.height - m.bottom - 69 * u
        let keys = model.mode == .keys
        let onWave = model.mode == .voice
        let gesture = model.mode == .gesture && model.gestureOn
        let voice = model.mode == .voice && model.micOn

        func slot<V: View>(_ index: Int, x: CGFloat, label: String, pressed: Bool, action: @escaping () -> Void,
                           @ViewBuilder _ pill: () -> V) -> some View {
            Button(action: action, label: pill)
                .buttonStyle(PressStyle(depth: 0.08))
                .accessibilityLabel(label)
                .accessibilityAddTraits(pressed ? .isSelected : [])
                .offset(y: model.pillsIn[index] || reduce ? 0 : 110 * u)
                .opacity(reduce && !model.pillsIn[index] ? 0 : 1)
                .animation(Motion.pick(.spring(response: 0.5, dampingFraction: 0.75), reduce: reduce), value: model.pillsIn[index])
                .offset(y: keys && !reduce ? 130 * u : 0)
                .opacity(reduce && keys ? 0 : 1)
                .animation(Motion.pick(Motion.soft, reduce: reduce), value: keys)
                .place(x: x, y: y, width: 88 * u, height: 60 * u)
        }

        return ZStack(alignment: .topLeading) {
            slot(0, x: 41 * u, label: "Жесты", pressed: gesture, action: model.tapGesture) {
                PillView(active: gesture, onWave: onWave, breathing: gesture) {
                    IconView(icon: Icons.hand, width: 32 * u)
                }
            }
            slot(1, x: 152 * u, label: "Голос", pressed: voice, action: model.tapVoice) {
                PillView(active: voice, onWave: onWave, breathing: false) {
                    MicIcon(v: model.micOn ? 1 : 0, width: 32 * u)
                        .animation(Motion.pick(Motion.soft, reduce: reduce), value: model.micOn)
                }
            }
            slot(2, x: 263 * u, label: "Клавиатура", pressed: keys, action: model.tapKeys) {
                PillView(active: keys, onWave: onWave, breathing: false) {
                    IconView(icon: Icons.keyboard, width: 32 * u)
                }
            }
        }
        .frame(width: m.width, height: m.height, alignment: .topLeading)
        .allowsHitTesting(!keys)
    }
}

/* ?debug of the web app: the model's three best guesses and how fast it runs.
   Shown by a triple tap on the chat's title. */
struct DebugBox: View {
    @ObservedObject var model: ChatModel
    let keyboardNote: String
    @State private var info = Capture.Debug()
    private let clock = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(info.top.prefix(3).enumerated()), id: \.offset) { _, guess in
                Text(String(format: "%3.0f%%  %@", guess.p * 100, guess.label))
            }
            Text(info.online
                 ? String(format: "сервер · %.0f к/с · %.0f мс", info.fps, info.ms)
                 : String(format: "устройство (%@) · %.0f к/с · %.0f мс · шаг %d", info.engine, info.fps, info.ms, info.stride))
            Text(info.person ? "человек найден" : "кадр по экрану")
            if !info.note.isEmpty { Text(info.note) }
            Text(keyboardNote)
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.white)
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.72)))
        .onReceive(clock) { _ in
            model.capture.debug { info = $0 }
        }
    }
}

/* Launch arguments, for checking the screens against the mockup in the
   Simulator:  -nosplash 1   -screen gesture|voice|keys|history   -seed 1
               -splashAt 900 (the splash as it is that many ms in)   -debug 1 */
enum Launch {
    static var noSplash: Bool { UserDefaults.standard.bool(forKey: "nosplash") }
    static var debug: Bool { UserDefaults.standard.bool(forKey: "debug") }
    static var splashAt: Double? {
        UserDefaults.standard.object(forKey: "splashAt") == nil ? nil : UserDefaults.standard.double(forKey: "splashAt")
    }

    static func apply(to model: ChatModel) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "seed") {
            for word in ["Привет", "как", "дела"] { model.gestureWord(word) }
            model.closePhrase()
            model.draft = "Здравствуйте! Всё хорошо."
            model.sendTyped()
        }
        switch defaults.string(forKey: "screen") {
        case "gesture": model.setMode(.gesture)
        case "voice": model.setMode(.voice)
        case "keys": model.setMode(.keys)
        case "history": model.openHistory()
        default: break
        }
    }
}
