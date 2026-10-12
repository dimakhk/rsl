import AVFoundation
import Foundation
import Speech

/* Turns speech into text with the recogniser built into iOS (Speech).

   Russian, with punctuation put in by the system. Where the device can
   recognise by itself it does, and then needs no connection; otherwise the
   sound goes to Apple's servers, as dictation on the keyboard does.

   The recogniser does not say where one remark ends, so that is decided
   here: when the text has not changed for a moment, the remark is closed and
   a new one is started. */

final class Listener {
    enum Failure: Error {
        case denied                              // no access to the microphone or to speech recognition
        case unavailable                         // no recogniser for Russian, or no microphone
    }

    static let pause: TimeInterval = 1.6         // silence this long ends a remark

    /* All called on the main queue. */
    var onText: ((String) -> Void)?              // the remark so far; replaces what was sent before
    var onRemark: ((String) -> Void)?            // the remark is complete
    var onStopped: ((Failure?) -> Void)?         // listening ended by itself

    private(set) var note = ""                   // for the debug view

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var wanted = false
    private var tapped = false
    private var heard = ""
    private var quiet: DispatchWorkItem?
    private var round = 0                        // answers of an older request are dropped
    private var failures = 0                     // requests in a row that ended in an error with nothing heard

    /* Asks for access if it has not been asked yet, then listens. */
    func start() {
        wanted = true
        failures = 0
        Listener.authorize { [weak self] allowed in
            guard let self = self, self.wanted else { return }
            guard allowed else { return self.fail(.denied) }
            self.listen()
        }
    }

    func stop() {
        wanted = false
        quiet?.cancel()
        finish()
        if engine.isRunning { engine.stop() }
        if tapped {
            engine.inputNode.removeTap(onBus: 0)
            tapped = false
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    }

    private static func authorize(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else { return DispatchQueue.main.async { done(false) } }
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async { done(granted) }
            }
        }
    }

    private func fail(_ why: Failure) {
        stop()
        note = why == .denied ? "речь: нет доступа" : "речь: недоступна"
        onStopped?(why)
    }

    private func listen() {
        guard let recognizer = recognizer, recognizer.isAvailable else { return fail(.unavailable) }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
            try session.setActive(true)
        } catch {
            return fail(.unavailable)
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // No microphone (the Simulator): a tap with such a format would stop the app.
        guard format.sampleRate > 0, format.channelCount > 0 else { return fail(.unavailable) }
        if !tapped {
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.request?.append(buffer)
            }
            tapped = true
        }
        begin(recognizer)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            return fail(.unavailable)
        }
        note = recognizer.supportsOnDeviceRecognition ? "речь: на устройстве" : "речь: через сервер Apple"
    }

    /* One remark = one request to the recogniser. */
    private func begin(_ recognizer: SFSpeechRecognizer) {
        round += 1
        let mine = round
        heard = ""
        let next = SFSpeechAudioBufferRecognitionRequest()
        next.shouldReportPartialResults = true
        next.addsPunctuation = true
        next.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition { next.requiresOnDeviceRecognition = true }
        request = next
        task = recognizer.recognitionTask(with: next) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self, mine == self.round else { return }
                if let result = result {
                    self.failures = 0
                    let text = result.bestTranscription.formattedString
                    if text != self.heard {
                        self.heard = text
                        if !text.isEmpty { self.onText?(text) }
                        self.waitForQuiet()
                    }
                    if result.isFinal { return self.close(failed: false) }
                }
                if error != nil { self.close(failed: true) }
            }
        }
    }

    private func waitForQuiet() {
        quiet?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.request?.endAudio() }     // the final text follows
        quiet = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Listener.pause, execute: item)
    }

    /* The remark is over (or the request failed): hand it on and start the
       next. A request that fails with nothing heard - silence that went on
       too long, a dropped connection - is tried again after a breath, and
       given up on if it keeps failing. */
    private func close(failed: Bool) {
        quiet?.cancel()
        let said = heard
        finish()
        if !said.isEmpty { onRemark?(said) }
        guard wanted, let recognizer = recognizer else { return }
        if failed && said.isEmpty { failures += 1 }
        if failures >= 8 || !recognizer.isAvailable { return fail(.unavailable) }
        let again = round
        DispatchQueue.main.asyncAfter(deadline: .now() + (failed ? 0.5 : 0)) { [weak self] in
            guard let self = self, self.wanted, again == self.round else { return }
            self.begin(recognizer)
        }
    }

    private func finish() {
        round += 1
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        heard = ""
    }
}
