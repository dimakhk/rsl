import Combine
import SwiftUI

/* What is on screen, and what happens when something is pressed.

   Screens: splash -> start (empty chat) -> gestures | voice | keyboard, plus
   the history screen that slides over them.

   What is real: the camera, sign recognition and the hints about where to
   stand (Capture). What is only drawn for now, and marked TODO below: speech
   recognition, speaking the text aloud, saving what is typed, and the chat
   history. */

enum Mode: Equatable {
    case idle, gesture, voice, keys
}

struct Message: Identifiable, Equatable {
    enum Side { case left, right }               // gestures on the right, voice and keyboard on the left

    struct Word: Identifiable, Equatable {
        let id = UUID()
        var text: String
    }

    let id = UUID()
    var side: Side
    var words: [Word] = []                       // arrive one by one (gestures, the voice demo)
    var text: String? = nil                      // or a whole message at once (keyboard)
    var dots = false                             // three dots: more is coming
    var flightFrom: CGRect? = nil                // a typed message takes off from the input strip
}

final class ChatModel: ObservableObject {
    @Published var mode = Mode.idle
    @Published var gestureOn = false             // recognition running (not paused)
    @Published var micOn = false
    @Published var sound = true
    @Published var historyOpen = false
    // TODO: функция будет добавлена позже (заглушки)
    @Published var chats = ["Чат #1", "Чат #2", "Чат #3", "Чат #4"]
    @Published var current = 0
    @Published var messages: [Message] = []
    @Published var plaque: String? = nil         // «Подойдите ближе», «Встаньте по центру» ...
    @Published var personSeen = false
    @Published var cameraReady = false
    @Published var splashDone = false
    @Published var pillsIn = [false, false, false]
    @Published var introAllowed = false
    @Published var debugShown = false
    @Published var draft = ""
    @Published var plusTurns = 0
    @Published var closeTurns = 0
    @Published var keysCloseTurns = 0

    let capture = Capture()
    var reduceMotion = false
    var inputFrame = CGRect.zero                 // where the input strip's text is, in the phone's coordinates

    private var before = Mode.idle               // where the keyboard was opened from
    private var openID: UUID? = nil              // the gesture bubble still taking words
    private var phraseTimer: DispatchWorkItem?
    private var ghostTimer: DispatchWorkItem?
    private var voiceTimers: [DispatchWorkItem] = []
    private var voiceShown = false
    private var voiceID: UUID? = nil
    private var cameraRelease: DispatchWorkItem?
    private var adding = false

    static let phraseGap: Double = 2             // a pause this long ends the phrase
    static let voiceDemo = "Здравствуйте! Это пример текста из голоса."

    var title: String { chats.indices.contains(current) ? chats[current] : "" }
    var introShown: Bool { introAllowed && mode == .idle && messages.isEmpty }
    var glow: Bool { personSeen && mode == .gesture && gestureOn }

    init() {
        capture.onWord = { [weak self] word in
            guard let self = self, self.mode == .gesture, self.gestureOn else { return }
            self.gestureWord(word)
        }
        capture.onListening = { [weak self] on in
            guard let self = self, self.mode == .gesture, self.gestureOn else { return }
            self.listening(on)
        }
        capture.onMessage = { [weak self] text in
            guard let self = self else { return }
            self.plaque = self.mode == .gesture ? text : nil
        }
        capture.onPerson = { [weak self] seen in self?.personSeen = seen }
        capture.onCamera = { [weak self] on in self?.cameraReady = on }
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
            plaque = nil
            // The camera is released once its block has slid out of sight.
            cameraRelease?.cancel()
            cameraRelease = later(0.6) { [weak self] in
                guard let self = self, self.mode != .gesture else { return }
                self.capture.stop()
            }
        }
        if prev == .voice {
            micOn = false
            stopVoice()
        }
        if next == .gesture {
            cameraRelease?.cancel()
            gestureOn = true
            capture.start()
        }
        if next == .voice {
            micOn = true
            startVoice()
        }
        if next == .keys { before = prev }
        mode = next
    }

    func tapGesture() {
        if mode != .gesture { return setMode(.gesture) }
        // pressed again: pause, the picture stays
        gestureOn.toggle()
        if gestureOn {
            capture.start()
        } else {
            capture.pause()
            closePhrase()
            personSeen = false
            plaque = nil
        }
    }

    func tapVoice() {
        if mode != .voice { return setMode(.voice) }
        micOn.toggle()
        if micOn { startVoice() } else { stopVoice() }
    }

    func tapKeys() {
        setMode(.keys)
    }

    func closeKeys() {
        keysCloseTurns += 1
        setMode(before == .keys ? .idle : before)
    }

    func toggleSound() {
        sound.toggle()
        // TODO: функция будет добавлена позже (озвучка текста)
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

    /* Gestures: words join the open bubble; two seconds of silence close it. */
    func gestureWord(_ text: String) {
        ghostTimer?.cancel()
        if index(openID) == nil { openID = addBubble(.right, dots: true) }
        addWord(openID, text)
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
                    guard let self = self, self.index(self.openID) == nil,
                          self.mode == .gesture, self.gestureOn else { return }
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

    /* Enter sends: the text takes off from the strip and lands in the feed as
       a bubble on the left. */
    func sendTyped() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        // TODO: функция будет добавлена позже (сообщение нигде не сохраняется)
        var m = Message(side: .left)
        m.text = text
        m.flightFrom = reduceMotion ? nil : inputFrame
        if reduceMotion {
            animate(Motion.fade) { messages.append(m) }
        } else {
            messages.append(m)                           // it flies in by itself (BubbleRow)
        }
    }

    func clearFeed() {
        closePhrase()
        messages.removeAll()
    }

    // MARK: voice

    /* TODO: функция будет добавлена позже (распознавание речи).
       For now the screen only shows how it will look: a bubble on the left
       with three dots, then a demo line arriving word by word. No microphone
       is used. */
    private func startVoice() {
        if voiceShown { return }                         // the demo plays once per chat
        voiceShown = true
        voiceTimers.append(later(0.5) { [weak self] in
            guard let self = self else { return }
            self.voiceID = self.addBubble(.left, dots: true)
            let words = ChatModel.voiceDemo.split(separator: " ").map(String.init)
            for (i, word) in words.enumerated() {
                self.voiceTimers.append(self.later(0.7 + Double(i) * 0.32) { [weak self] in
                    guard let self = self else { return }
                    self.addWord(self.voiceID, word)
                    if i == words.count - 1 {
                        self.voiceTimers.append(self.later(0.5) { [weak self] in
                            self?.setDots(self?.voiceID, false)
                        })
                    }
                })
            }
        })
    }

    private func stopVoice() {
        voiceTimers.forEach { $0.cancel() }
        voiceTimers.removeAll()
        setDots(voiceID, false)
    }

    private func resetVoice() {
        stopVoice()
        voiceShown = false
        voiceID = nil
    }

    // MARK: history

    /* TODO: функция будет добавлена позже (история чатов).
       The list is a placeholder: nothing is stored, renamed or deleted, and
       choosing a chat only returns to the start screen. */
    func openHistory() {
        if historyOpen { return }
        if mode == .keys { closeKeys() }
        historyOpen = true
    }

    func closeHistory() {
        if !historyOpen { return }
        closeTurns += 1
        historyOpen = false
    }

    func openChat(_ index: Int) {
        // TODO: функция будет добавлена позже (чаты не сохраняются: выбранный чат открывается пустым)
        if index != current, chats.indices.contains(index) {
            current = index
            clearFeed()
            resetVoice()
        }
        setMode(.idle)
        historyOpen = false
    }

    /* «+»: a new chat unfolds in the wheel after the one in the centre, then
       opens. Returns where it was put, or nil while another is being added. */
    func addChat(after centre: Int) -> Int? {
        if adding { return nil }
        adding = true
        plusTurns += 1
        let i = min(chats.count, centre + 1)
        chats.insert("Чат #\(chats.count + 1)", at: i)
        if i <= current { current += 1 }
        return i
    }

    func chatAdded(_ index: Int) {
        _ = later(0.26) { [weak self] in
            self?.adding = false
            self?.openChat(index)
        }
    }

    // MARK: start

    func splashFinished() {
        splashDone = true
        // the pills come up from below, left to right
        for i in 0..<3 {
            _ = later(0.12 + Double(i) * 0.06) { [weak self] in self?.pillsIn[i] = true }
        }
        _ = later(0.25) { [weak self] in self?.introAllowed = true }
    }
}
