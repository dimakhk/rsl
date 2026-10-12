import Combine
import SwiftUI

/* What is on screen, and what happens when something is pressed.

   Screens: splash -> start (empty chat) -> gestures | voice | keyboard, plus
   the history screen that slides over them.

   The three buttons at the bottom are switches. Pressing one opens its mode;
   pressing it again closes the mode and brings back the start screen, with
   the messages that are already there.

   What is real: the camera and sign recognition (Capture). What is only drawn
   for now, and marked TODO below: speech recognition, speaking the text
   aloud, saving what is typed, and the chat history. */

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
}

final class ChatModel: ObservableObject {
    @Published private(set) var mode = Mode.idle
    @Published var sound = true
    @Published private(set) var historyOpen = false
    // TODO: функция будет добавлена позже (заглушки)
    @Published private(set) var chats = ["Чат #1", "Чат #2", "Чат #3", "Чат #4"]
    @Published private(set) var current = 0
    @Published private(set) var messages: [Message] = []
    @Published private(set) var personSeen = false
    @Published private(set) var cameraReady = false
    @Published private(set) var pictureIsLight = false   // the top of the camera picture, under the bar
    @Published private(set) var splashDone = false
    @Published private(set) var pillsIn = [false, false, false]
    @Published private(set) var introAllowed = false
    @Published var debugShown = false
    @Published private(set) var plusTurns = 0
    @Published private(set) var closeTurns = 0
    @Published private(set) var typed = ""       // what the keyboard has written and not yet sent

    let capture = Capture()
    var reduceMotion = false

    private var openID: UUID? = nil              // the gesture bubble still taking words
    private var draftID: UUID? = nil             // the bubble being typed
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
    var glow: Bool { personSeen && mode == .gesture }

    init() {
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
        if prev == .voice { stopVoice() }
        if prev == .keys { finishTyping() }

        if next == .gesture {
            cameraRelease?.cancel()
            capture.start()
        }
        if next == .voice { startVoice() }
        mode = next
    }

    /* The three buttons: open the mode, or close it if it is the open one. */
    func tapGesture() { setMode(mode == .gesture ? .idle : .gesture) }
    func tapVoice() { setMode(mode == .voice ? .idle : .voice) }
    func tapKeys() { setMode(mode == .keys ? .idle : .keys) }

    /* The keyboard was put away: a tap beside it, or a swipe down. */
    func closeKeys() {
        if mode == .keys { setMode(.idle) }
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

    func clearFeed() {
        closePhrase()
        draftID = nil
        typed = ""
        messages.removeAll()
    }

    // MARK: keyboard

    /* There is no input field: what is typed is written straight into the
       chat, as a bubble on the left with three dots while it is being typed.
       Return sends it; putting the keyboard away sends it too, so nothing
       typed is lost. */
    func keyboardWrote(_ text: String) {
        typed = text
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        if parts.isEmpty {
            if draftID != nil {
                remove(draftID)
                draftID = nil
            }
            return
        }
        if index(draftID) == nil { draftID = addBubble(.left, dots: true) }
        guard let i = index(draftID) else { return }
        // A word keeps its place while it is being typed; only a new word arrives.
        let old = messages[i].words
        let words = parts.enumerated().map { n, part in
            Message.Word(id: n < old.count ? old[n].id : UUID(), text: part)
        }
        animate(.spring(response: 0.3, dampingFraction: 0.9)) { messages[i].words = words }
    }

    func sendTyped() {
        // TODO: функция будет добавлена позже (сообщение нигде не сохраняется)
        setDots(draftID, false)
        draftID = nil
        typed = ""
    }

    private func finishTyping() {
        sendTyped()
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
        closeKeys()
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

    /* For screenshots in the Simulator, which has no camera: as if the camera
       were showing a light or a dark picture. */
    @Published private(set) var pretendedPicture: Bool? = nil

    func pretendPicture(light: Bool) {
        pretendedPicture = light
        cameraReady = true
        pictureIsLight = light
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
