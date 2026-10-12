import AVFoundation
import Foundation
import UIKit

/* Camera and sign recognition, with no interface of their own.

   The interface asks for three things: start, stop, and to be told what
   happens - a recognised word, a message for the person in front of the
   camera, whether anyone is in the frame.

   Two recognisers, one at a time: the server's SignFlow-R while it answers
   (Cloud), the device's S3D otherwise (Recognizer). The person is found and
   cropped by Framer, which also says how to stand.

   Everything that touches frames runs on one queue (`frames`); the interface
   is called back on the main one. */

final class Capture {
    enum ModelState { case idle, loading, ready, failed }

    struct Debug {
        var online = false
        var top: [Guess] = []
        var fps: Double = 0
        var ms: Double = 0
        var stride = 0
        var engine = ""
        var note = ""
        var person = false
        var hint = ""                            // what would be said to the person (not shown for now)
    }

    /* All four are called on the main queue. */
    var onWord: ((String) -> Void)?
    var onMessage: ((String?) -> Void)?
    var onPerson: ((Bool) -> Void)?
    var onListening: ((Bool) -> Void)?
    var onCamera: ((Bool) -> Void)?              // the picture is there / is gone
    var onPicture: ((Bool) -> Void)?             // the picture under the top bar is light / is dark

    let camera = Camera()
    private let frames = DispatchQueue(label: "rsl.frames", qos: .userInitiated)
    private let recognizer = Recognizer()
    private let framer = Framer()
    private lazy var cloud = Cloud(queue: frames)

    // State below is touched only on `frames`.
    private var wanted = false                   // the interface wants recognition on
    private var cameraOn = false
    private var capturing = false
    private var captureSince: Double = 0
    private var usingCloud: Bool? = nil
    private var modelState = ModelState.idle
    private var person = false
    private var listening = false
    private var viewAspect: CGFloat = 393.0 / 467.0      // width / height of the camera block on screen
    private var barShare: CGFloat = 0.23                 // how much of that block, from the top, the bar lies over
    private var pictureLight = false
    private var frameCount = 0

    private var issues: [String: String] = [:]
    private static let order = ["camera", "model", "frozen", "pose", "slow"]
    private var shown: String? = nil

    /* Call once. Loading and warming up the model takes a second or two, so
       it starts right away. */
    func prepare() {
        recognizer.callbackQueue = frames
        framer.callbackQueue = frames
        recognizer.onWord = { [weak self] word in
            guard let self = self, self.capturing, !self.cloud.online else { return }
            DispatchQueue.main.async { self.onWord?(word) }
        }
        recognizer.onStats = { [weak self] stats in
            guard let self = self else { return }
            self.setIssue("frozen", self.capturing && stats.frozen ? "Камера закрыта: картинка не меняется" : nil)
            // The model reads 32 frames as about one second. Far fewer frames
            // per second stretch that window, the sign arrives in slow motion
            // and accuracy falls apart.
            let slow = self.capturing && self.captureSince > 0 && Capture.now() - self.captureSince > 3000 &&
                       stats.fps > 0 && stats.fps < 18
            self.setIssue("slow", slow ? String(format: "Мало кадров с камеры (%.0f/с)", stats.fps) : nil)
            if !self.cloud.online { self.hear(stats.top) }
        }
        cloud.onWord = { [weak self] word in
            guard let self = self, self.capturing else { return }
            DispatchQueue.main.async { self.onWord?(word) }
        }
        cloud.onStats = { [weak self] stats in
            guard let self = self else { return }
            if stats.online {
                self.setIssue("model", nil)
                self.setIssue("frozen", nil)     // those two are the device model's
                self.setIssue("slow", nil)
                if self.wanted && self.cameraOn && !self.capturing { self.beginCapture() }
                self.hear(stats.top)
            } else if self.modelState == .failed && self.wanted {
                self.setIssue("model", "Не удалось загрузить распознавание")
            }
        }
        camera.onFrame = { [weak self] buffer in self?.frame(buffer) }
        camera.onLost = { [weak self] in
            guard let self = self else { return }
            self.onCamera?(false)
            self.frames.async {
                self.cameraOn = false
                self.halt()
                self.setIssue("camera", "Камера отключилась")
            }
        }
        frames.async { self.loadModel() }
        cloud.start(packed: Bundle.main.url(forResource: "server", withExtension: "json"))
    }

    private static func now() -> Double { CFAbsoluteTimeGetCurrent() * 1000 }

    // MARK: messages

    /* One line at a time, the most pressing first. */
    private func setIssue(_ key: String, _ text: String?) {
        issues[key] = text
        let top = Capture.order.first { issues[$0] != nil }
        let next = top.flatMap { issues[$0] }
        if next != shown {
            shown = next
            DispatchQueue.main.async { self.onMessage?(next) }
        }
    }

    // MARK: model

    private func loadModel() {
        guard modelState == .idle else { return }
        modelState = .loading
        guard let model = Bundle.main.path(forResource: "s3d", ofType: "onnx"),
              let labels = Bundle.main.path(forResource: "labels", ofType: "json") else {
            modelState = .failed
            return
        }
        // With the server answering, the device's model is only a reserve: it
        // loads quietly and nobody has to wait for it.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try self.recognizer.load(modelPath: model, labelsPath: labels) }
            self.frames.async {
                switch result {
                case .success:
                    self.modelState = .ready
                    self.setIssue("model", nil)
                    if self.wanted && self.cameraOn { self.beginCapture() }      // asked for while it was loading
                case .failure(let error):
                    self.modelState = .failed
                    NSLog("RSL: model failed: %@", error.localizedDescription)
                    self.setIssue("model", self.cloud.online || !self.wanted ? nil : "Не удалось загрузить распознавание")
                }
            }
        }
    }

    /* A sign is taking shape when the model's best guess is not "nothing". */
    private func hear(_ top: [Guess]) {
        var now = false
        if capturing, let t = top.first {
            now = t.p >= 0.2 && t.label != Rule.blank && t.label != "№0"
        }
        if now != listening {
            listening = now
            DispatchQueue.main.async { self.onListening?(now) }
        }
    }

    // MARK: frames

    /* While nobody has been found, the model gets what the person sees: the
       part of the camera picture inside the camera block. The picture fills
       that block and is cut to it, so much of the frame never reaches the screen. */
    private func visibleCrop(width: CGFloat, height: CGFloat) -> CGRect {
        let frameAspect = width / height
        if frameAspect > viewAspect {
            let w = height * viewAspect
            return CGRect(x: (width - w) / 2, y: 0, width: w, height: height)
        }
        let h = width / viewAspect
        return CGRect(x: 0, y: (height - h) / 2, width: width, height: h)
    }

    /* Is the picture under the top bar light or dark? Looked at six times a
       second; the answer changes only past a margin, so it does not flicker
       on a picture that is in between. */
    private func watchPicture(_ buffer: CVPixelBuffer, width: CGFloat, height: CGFloat) {
        frameCount += 1
        guard frameCount % 5 == 0 else { return }
        var top = visibleCrop(width: width, height: height)
        top.size.height *= barShare
        guard let level = FrameTools.lightness(buffer, in: top) else { return }
        let light = pictureLight ? level > 0.48 : level > 0.60
        if light != pictureLight {
            pictureLight = light
            DispatchQueue.main.async { self.onPicture?(light) }
        }
    }

    private func frame(_ buffer: CVPixelBuffer) {
        let width = CGFloat(CVPixelBufferGetWidth(buffer)), height = CGFloat(CVPixelBufferGetHeight(buffer))
        watchPicture(buffer, width: width, height: height)
        guard capturing else { return }
        let now = Capture.now()
        if now < captureSince { return }                 // the screen's transition is still playing
        framer.update(buffer, now: now)
        let crop = framer.crop ?? visibleCrop(width: width, height: height)
        let online = cloud.online
        if online != usingCloud {                        // the server came or went: start clean
            usingCloud = online
            if online { cloud.begin() } else if modelState == .ready { recognizer.start() }
        }
        if online {
            cloud.push(buffer, crop: crop)
        } else if modelState == .ready {
            recognizer.push(buffer, crop: crop)
        }
        setIssue("pose", framer.advice)
        let seen = framer.crop != nil
        if seen != person {
            person = seen
            DispatchQueue.main.async { self.onPerson?(seen) }
        }
    }

    private func beginCapture() {
        guard !capturing, modelState == .ready || cloud.online else { return }
        capturing = true
        usingCloud = nil
        // Frames and inference are the heaviest work there is. Let the
        // screen's transition play out first; the model needs a second of
        // video before it can say anything anyway.
        captureSince = Capture.now() + 450
        framer.reset(now: captureSince)
    }

    private func halt() {
        capturing = false                                // not one more frame is read
        recognizer.stop()
        cloud.stop()
        for key in ["pose", "frozen", "slow", "model"] { setIssue(key, nil) }
        if person {
            person = false
            DispatchQueue.main.async { self.onPerson?(false) }
        }
        if listening {
            listening = false
            DispatchQueue.main.async { self.onListening?(false) }
        }
    }

    // MARK: interface (main queue)

    /* The shape of the camera block on screen (width / height) - for the crop
       used while nobody is found - and how much of it the top bar lies over. */
    func setView(aspect: CGFloat, bar: CGFloat) {
        guard aspect > 0 else { return }
        frames.async {
            self.viewAspect = aspect
            self.barShare = min(1, max(0.05, bar))
        }
    }

    /* Camera on and recognition running. */
    func start() {
        UIApplication.shared.isIdleTimerDisabled = true          // the screen stays on while signing
        frames.async {
            self.wanted = true
            if self.modelState == .failed && !self.cloud.online {
                self.setIssue("model", "Не удалось загрузить распознавание")
            } else if self.modelState == .loading && !self.cloud.online {
                self.setIssue("model", "Загрузка распознавания…")
            }
            if self.cameraOn {
                self.beginCapture()
                return
            }
            self.camera.start(frames: self.frames) { result in
                self.frames.async {
                    switch result {
                    case .success:
                        guard self.wanted else {                 // left the screen while the prompt was up
                            self.camera.stop()
                            return
                        }
                        self.cameraOn = true
                        self.setIssue("camera", nil)
                        DispatchQueue.main.async { self.onCamera?(true) }
                        self.beginCapture()
                    case .failure(let why):
                        self.setIssue("camera", why == .denied ? "Нет доступа к камере" : "Камера недоступна")
                    }
                }
            }
        }
    }

    /* Recognition off, the picture stays (the gesture button pressed again). */
    func pause() {
        frames.async {
            self.wanted = false
            self.halt()
        }
    }

    /* Recognition off and the camera released. */
    func stop() {
        UIApplication.shared.isIdleTimerDisabled = false
        onCamera?(false)
        frames.async {
            self.wanted = false
            self.halt()
            self.cameraOn = false
            self.camera.stop()
            self.setIssue("camera", nil)
            self.pictureLight = false
            DispatchQueue.main.async { self.onPicture?(false) }
        }
    }

    /* What the models are doing right now, for the debug view. */
    func debug(_ done: @escaping (Debug) -> Void) {
        frames.async {
            var d = Debug()
            d.online = self.cloud.online
            d.person = self.framer.crop != nil
            if d.online {
                d.top = self.cloud.stats.top
                d.fps = self.cloud.stats.fps
                d.ms = self.cloud.stats.ms
            } else {
                d.top = self.recognizer.stats.top
                d.fps = self.recognizer.stats.fps
                d.ms = self.recognizer.stats.inferMs
                d.stride = self.recognizer.stats.stride
            }
            d.hint = self.shown ?? ""
            d.engine = self.recognizer.stats.engine
            d.note = self.recognizer.engineNote
            DispatchQueue.main.async { done(d) }
        }
    }
}
