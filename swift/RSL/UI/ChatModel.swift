import Combine
import SwiftUI
import UIKit

/* What is on screen, and what happens when something is pressed.

   Screens: splash -> start (empty chat) -> gestures | voice | keyboard, plus
   the history screen that slides over them.

   The three buttons at the bottom are switches. Pressing one opens its mode;
   pressing it again closes the mode and brings back the start screen, with
   the messages that are already there.

   Who says what: gestures go to the right of the chat and are spoken aloud;
   what is typed goes to the left and is spoken when sent; what the
   microphone hears goes to the left and is not spoken (it was just said).

   Chats: every start of the app begins a new chat; «+» in the history begins
   one too. The earlier ones stay in the history under a name made from
   their own words (ChatStore), and any of them can be opened and continued. */

enum Mode: Equatable {
    case idle, gesture, voice, keys
}

struct Message: Identifiable, Equatable {
    enum Side { case left, right }               // gestures on the right, voice and keyboard on the left

    struct Word: Identifiable, Equatable {
        var id = UUID()
        var text: String
    }

    let id = UUID()
    var side: Side
    var words: [Word] = []                       // they arrive one by one
    var dots = false                             // three dots: more is coming

    var text: String { words.map(\.text).joined(separator: " ") }

    init(side: Side, dots: Bool = false) {
        self.side = side
        self.dots = dots
    }

    init(_ line: StoredChat.Line) {
        side = line.right ? .right : .left
        words = Message.split(line.text).map { Word(text: $0) }
    }

    static func split(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }
}

final class ChatModel: ObservableObject {
    @Published private(set) var mode = Mode.idle
    @Published private(set) var sound: Bool
    @Published private(set) var voice: Speaker.Voice
    @Published private(set) var historyOpen = false
    @Published private(set) var chats: [StoredChat]      // oldest first; the open one is among them
    @Published private(set) var current: Int
    @Published private(set) var messages: [Message] = []
    @Published private(set) var personSeen = false
    @Published private(set) var cameraReady = false
    @Published private(set) var cameraSide = Camera.Side.front
    @Published private(set) var cameraTurns = 0          // the switch button turns half a circle each time
    @Published private(set) var pictureIsLight = false   // the top of the camera picture, under the bar
    @Published private(set) var splashDone = false
    @Published private(set) var pillsIn = [false, false, false]
    @Published private(set) var introAllowed = false
    @Published var debugShown = false
    @Published private(set) var plusTurns = 0
    @Published private(set) var closeTurns = 0
    @Published private(set) var typed = ""       // what the keyboard has written and not yet sent

    let capture = Capture()
    let speaker = Speaker()
    let listener = Listener()
    var reduceMotion = false

    private let store: ChatStore
    private var saving: AnyCancellable?
    private var leaving: NSObjectProtocol?
    private var openID: UUID? = nil              // the gesture bubble still taking words
    private var draftID: UUID? = nil             // the bubble being typed
    private var remarkID: UUID? = nil            // the bubble of what is being said into the microphone
    private var phraseTimer: DispatchWorkItem?
    private var ghostTimer: DispatchWorkItem?
    private var cameraRelease: DispatchWorkItem?
    private var adding = false

    static let phraseGap: Double = 2             // a pause this long ends the phrase

    /* The name of the open chat: from its finished messages. */
    var title: String {
        ChatTitle.make(from: messages.filter { !$0.dots }.map(\.text)) ?? ChatTitle.new
    }

    /* The names in the history, in the order of `chats`. */
    var chatTitles: [String] {
        chats.indices.map { $0 == current ? title : chats[$0].title }
    }

    var introShown: Bool { introAllowed && mode == .idle && messages.isEmpty }
    var glow: Bool { personSeen && mode == .gesture }
    var audioNote: String { [listener.note, "голос: " + voice.spokenName].filter { !$0.isEmpty }.joined(separator: " · ") }

    init() {
        let store = ChatStore(persistent: !Launch.noStore)
        self.store = store
        // Every start of the app begins a new chat; the earlier ones are the history.
        var all = store.load()
        all.append(StoredChat())
        chats = all
        current = all.count - 1
        let soundOn = UserDefaults.standard.object(forKey: "sound") == nil ? true : UserDefaults.standard.bool(forKey: "sound")
        sound = soundOn
        voice = .milena
        // (everything has a value from here on)
        voice = speaker.voice
        speaker.enabled = soundOn

        capture.onWord = { [weak self] word in
            guard let self = self, self.mode == .gesture else { return }
            self.gestureWord(word)
        }
        capture.onListening = { [weak self] on in
            guard let self = self, self.mode == .gesture else { return }
            self.listening(on)
        }
        // Hints for the person in front of the camera («Подойдите ближе» ...)
        // are switched off for now. Capture still works them out (onMessage).
        capture.onPerson = { [weak self] seen in self?.personSeen = seen }
        capture.onCamera = { [weak self] on in self?.cameraReady = on }
        capture.onPicture = { [weak self] light in self?.pictureIsLight = light }

        listener.onText = { [weak self] text in self?.heard(text, complete: false) }
        listener.onRemark = { [weak self] text in self?.heard(text, complete: true) }
        listener.onStopped = { [weak self] _ in
            // No access, or no recogniser: the mode has nothing to do.
            guard let self = self, self.mode == .voice else { return }
            self.setMode(.idle)
        }

        // The chat is written down a moment after it changes, and when the app is left.
        saving = $messages
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.keep() }
        leaving = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.keep()
            }
    }

    deinit {
        if let leaving = leaving { NotificationCenter.default.removeObserver(leaving) }
    }

    private func animate(_ animation: Animation, _ change: () -> Void) {
        withAnimation(Motion.pick(animation, reduce: reduceMotion), change)
    }

    private func later(_ seconds: Double, _ work: @escaping () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }

    // MARK: screens

    func setMode(_ next: Mode) {
        let prev = mode
        if next == prev { return }

        if prev == .gesture {
            capture.pause()
            closePhrase()
            personSeen = false
            // The camera is released once its block has slid out of sight.
            cameraRelease?.cancel()
            cameraRelease = later(0.6) { [weak self] in
                guard let self = self, self.mode != .gesture else { return }
                self.capture.stop()
            }
        }
        if prev == .voice { stopListening() }
        if prev == .keys { sendTyped() }

        mode = next
        // While the microphone is on the app keeps quiet: it would hear itself.
        speaker.muted = next == .voice

        if next == .gesture {
            cameraRelease?.cancel()
            capture.start()
        }
        if next == .voice && !Launch.noAudio { listener.start() }
    }

    /* The three buttons: open the mode, or close it if it is the open one. */
    func tapGesture() { setMode(mode == .gesture ? .idle : .gesture) }
    func tapVoice() { setMode(mode == .voice ? .idle : .voice) }
    func tapKeys() { setMode(mode == .keys ? .idle : .keys) }

    /* The keyboard was put away: a tap beside it, or a swipe down. */
    func closeKeys() {
        if mode == .keys { setMode(.idle) }
    }

    /* Front camera <-> back camera. */
    func flipCamera() {
        cameraSide = cameraSide.other
        cameraTurns += 1
        capture.useCamera(cameraSide)
        closePhrase()
    }

    // MARK: sound

    func toggleSound() {
        sound.toggle()
        speaker.enabled = sound
        UserDefaults.standard.set(sound, forKey: "sound")
    }

    /* Milena <-> Yuri (a long press on the sound button). The voice says its name. */
    func switchVoice() {
        speaker.choose(voice.other)
        voice = speaker.voice
        speaker.stop()
        speaker.say(voice.spokenName, force: true)
    }

    // MARK: feed

    private func index(_ id: UUID?) -> Int? {
        guard let id = id else { return nil }
        return messages.firstIndex { $0.id == id }
    }

    private func addBubble(_ side: Message.Side, dots: Bool) -> UUID {
        let m = Message(side: side, dots: dots)
        animate(Motion.bouncy) { messages.append(m) }
        return m.id
    }

    private func addWord(_ id: UUID?, _ text: String) {
        guard let i = index(id) else { return }
        animate(.spring(response: 0.3, dampingFraction: 0.9)) {
            messages[i].words.append(Message.Word(text: text))
        }
    }

    private func setDots(_ id: UUID?, _ on: Bool) {
        guard let i = index(id), messages[i].dots != on else { return }
        animate(.spring(response: 0.3, dampingFraction: 0.9)) { messages[i].dots = on }
    }

    private func remove(_ id: UUID?) {
        guard let i = index(id) else { return }
        animate(Motion.soft) { _ = messages.remove(at: i) }
    }

    /* Text that is still changing - being typed, or being heard - shown in a
       bubble on the left with three dots. A word keeps its place while it
       changes; only a new word arrives. Empty text takes the bubble away. */
    private func write(_ text: String, into id: inout UUID?) {
        let parts = Message.split(text)
        if parts.isEmpty {
            if id != nil {
                remove(id)
                id = nil
            }
            return
        }
        if index(id) == nil { id = addBubble(.left, dots: true) }
        guard let i = index(id) else { return }
        let old = messages[i].words
        let words = parts.enumerated().map { n, part in
            Message.Word(id: n < old.count ? old[n].id : UUID(), text: part)
        }
        guard words != old else { return }
        animate(.spring(response: 0.3, dampingFraction: 0.9)) { messages[i].words = words }
    }

    /* Gestures: words join the open bubble; two seconds of silence close it.
       Each word is spoken as it comes. */
    func gestureWord(_ text: String) {
        ghostTimer?.cancel()
        if index(openID) == nil { openID = addBubble(.right, dots: true) }
        addWord(openID, text)
        speaker.say(text)
        phraseTimer?.cancel()
        phraseTimer = later(ChatModel.phraseGap) { [weak self] in self?.closePhrase() }
    }

    /* The model sees a sign taking shape: three dots, as in a messenger. If
       no word comes of it, the empty bubble goes away again. */
    func listening(_ on: Bool) {
        ghostTimer?.cancel()
        if on {
            if index(openID) == nil {
                ghostTimer = later(0.4) { [weak self] in
                    guard let self = self, self.index(self.openID) == nil, self.mode == .gesture else { return }
                    self.openID = self.addBubble(.right, dots: true)
                }
            }
        } else if let i = index(openID), messages[i].words.isEmpty {
            ghostTimer = later(1.5) { [weak self] in
                guard let self = self, let i = self.index(self.openID), self.messages[i].words.isEmpty else { return }
                self.remove(self.openID)
                self.openID = nil
            }
        }
    }

    func closePhrase() {
        phraseTimer?.cancel()
        ghostTimer?.cancel()
        guard let i = index(openID) else {
            openID = nil
            return
        }
        if messages[i].words.isEmpty { remove(openID) } else { setDots(openID, false) }
        openID = nil
    }

    // MARK: keyboard

    /* There is no input field: what is typed is written straight into the
       chat. Return sends it; putting the keyboard away sends it too, so
       nothing typed is lost. A sent message is spoken. */
    func keyboardWrote(_ text: String) {
        typed = text
        write(text, into: &draftID)
    }

    func sendTyped() {
        if let i = index(draftID) { speaker.say(messages[i].text) }
        setDots(draftID, false)
        draftID = nil
        typed = ""
    }

    // MARK: voice

    /* What the microphone hears: the remark so far, and then the remark complete. */
    func heard(_ text: String, complete: Bool) {
        write(text, into: &remarkID)
        if complete {
            setDots(remarkID, false)
            remarkID = nil
        }
    }

    private func stopListening() {
        listener.stop()
        setDots(remarkID, false)
        remarkID = nil
    }

    // MARK: chats

    /* Writes the open chat down. Bubbles still without words are not messages yet. */
    private func keep() {
        guard chats.indices.contains(current) else { return }
        let lines = messages.filter { !$0.words.isEmpty }.map {
            StoredChat.Line(right: $0.side == .right, text: $0.text)
        }
        if chats[current].lines != lines { chats[current].lines = lines }
        store.save(chats)
    }

    func openHistory() {
        if historyOpen { return }
        setMode(.idle)
        keep()
        historyOpen = true
    }

    func closeHistory() {
        if !historyOpen { return }
        closeTurns += 1
        historyOpen = false
    }

    /* Opens a chat from the history, to read and to go on with. A chat left
       empty is not kept. */
    func openChat(_ index: Int) {
        guard chats.indices.contains(index) else { return }
        setMode(.idle)
        if index != current {
            keep()
            let was = current
            current = index
            if chats[was].isEmpty {
                chats.remove(at: was)
                if was < current { current -= 1 }
            }
            openID = nil
            draftID = nil
            remarkID = nil
            typed = ""
            messages = chats[current].lines.map { Message($0) }
        }
        historyOpen = false
    }

    /* «+»: a new chat unfolds at the end of the wheel, then opens. Returns
       where it was put - or nil when there is nothing to add: the open chat
       is still empty (it is the new chat), or one is being added already. */
    func addChat() -> Int? {
        if adding { return nil }
        plusTurns += 1
        keep()
        if chats.indices.contains(current), chats[current].isEmpty {
            historyOpen = false
            return nil
        }
        adding = true
        chats.append(StoredChat())
        return chats.count - 1
    }

    func chatAdded(_ index: Int) {
        _ = later(0.26) { [weak self] in
            self?.adding = false
            self?.openChat(index)
        }
    }

    // MARK: checking

    /* For screenshots in the Simulator, which has no camera: as if the camera
       were showing a light or a dark picture. */
    @Published private(set) var pretendedPicture: Bool? = nil

    func pretendPicture(light: Bool) {
        pretendedPicture = light
        cameraReady = true
        pictureIsLight = light
    }

    /* For screenshots: earlier chats in the history and a few messages in the open one. */
    func seed() {
        let earlier = [["Где находится аптека?", "За углом, направо."], ["Здравствуйте!", "Сколько стоит билет?"]]
        let old = earlier.map { remarks in
            StoredChat(lines: remarks.enumerated().map { StoredChat.Line(right: $0.offset % 2 == 0, text: $0.element) })
        }
        chats.insert(contentsOf: old, at: 0)
        current += old.count
        for word in ["Привет", "как", "дела"] { gestureWord(word) }
        closePhrase()
        keyboardWrote("Здравствуйте! Всё хорошо.")
        sendTyped()
    }

    // MARK: start

    func splashFinished() {
        splashDone = true
        if !Launch.noAudio { speaker.warmUp() }
        // the pills come up from below, left to right
        for i in 0..<3 {
            _ = later(0.12 + Double(i) * 0.06) { [weak self] in self?.pillsIn[i] = true }
        }
        _ = later(0.25) { [weak self] in self?.introAllowed = true }
    }
}
