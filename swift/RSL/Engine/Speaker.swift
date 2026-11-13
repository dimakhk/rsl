import AVFoundation
import Foundation

/* Says text aloud with the voice synthesiser built into iOS
   (AVSpeechSynthesizer). It needs no connection and no download.

   Two Russian voices, Milena and Yuri. Whichever is asked for is used if the
   device has it; otherwise the other one, otherwise any Russian voice.

   No long waits: one synthesiser is kept for the whole run and is woken up
   at the start, and what has to be said is queued, so a word is spoken as
   soon as the one before it ends. */

final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    enum Voice: String, CaseIterable {
        case milena = "Milena"
        case yuri = "Yuri"

        var spokenName: String { self == .milena ? "Милена" : "Юрий" }
        var other: Voice { self == .milena ? .yuri : .milena }
    }

    var enabled = true {
        didSet { if !enabled { synthesizer.stopSpeaking(at: .immediate) } }
    }

    /* Recording is on: the microphone would hear the phone talking to itself. */
    var muted = false {
        didSet { if muted { synthesizer.stopSpeaking(at: .immediate) } }
    }

    private(set) var voice: Voice
    private let synthesizer = AVSpeechSynthesizer()
    private static let key = "voice"

    override init() {
        voice = Voice(rawValue: UserDefaults.standard.string(forKey: Speaker.key) ?? "") ?? .milena
        super.init()
        synthesizer.delegate = self
    }

    /* The system voice with this name: the best quality the device has. */
    static func systemVoice(_ wanted: Voice) -> AVSpeechSynthesisVoice? {
        let russian = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("ru") }
        func named(_ v: Voice) -> AVSpeechSynthesisVoice? {
            russian
                .filter { $0.name.localizedCaseInsensitiveContains(v.rawValue) ||
                          $0.identifier.localizedCaseInsensitiveContains(v.rawValue) ||
                          $0.name.localizedCaseInsensitiveContains(v.spokenName) }
                .max { $0.quality.rawValue < $1.quality.rawValue }
        }
        return named(wanted) ?? named(wanted.other) ?? russian.first ?? AVSpeechSynthesisVoice(language: "ru-RU")
    }

    /* The first utterance of a run is the slow one: get it over with, silently. */
    func warmUp() {
        let silent = AVSpeechUtterance(string: " ")
        silent.volume = 0
        silent.voice = Speaker.systemVoice(voice)
        synthesizer.speak(silent)
    }

    func choose(_ next: Voice) {
        voice = next
        UserDefaults.standard.set(next.rawValue, forKey: Speaker.key)
    }

    /* Queued behind whatever is being said. `force` says it even with the
       sound off (the voice introducing itself when it is chosen). */
    func say(_ text: String, force: Bool = false) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !muted, enabled || force else { return }
        Speaker.playbackSession()
        let utterance = AVSpeechUtterance(string: clean)
        utterance.voice = Speaker.systemVoice(voice)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /* Sound through the speaker, also with the ring switch on silent: for
       somebody who speaks through this app, silence is the app not working. */
    static func playbackSession() {
        let session = AVAudioSession.sharedInstance()
        guard session.category != .playback && session.category != .playAndRecord else { return }
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
    }
}
