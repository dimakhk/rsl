import CoreVideo
import Foundation
import OnnxRuntimeBindings

/* Sign recognition that runs inside the device.

   The model is easy_sign's S3D, rebuilt out of 2D operators (the same file the
   web app uses, in full precision). It reads 32 frames at a time - about one
   second of video - and names the sign in them.

   The pace sets itself. A fast device finishes a window quickly and can start
   a new one every 8 frames; a slow one gets one every 20-30. Since a rarer
   window means fewer chances to see the same sign twice, the acceptance rule
   loosens in step (see Rule). */

/* The model and the runtime under it (ONNX Runtime).

   It starts on the CPU, which always works. Core ML - Apple's own engine,
   which can use the GPU and the Neural Engine - is then tried in the
   background: the same input goes through both, and Core ML takes over only
   if it gives the same answer and gives it faster. A device where it does
   not, simply stays on the CPU. */
final class S3DModel {
    static let inputName = "frames"
    static let outputName = "logits"
    static let shape: [NSNumber] = [32, 3, 224, 224]
    static let count = 32 * 3 * 224 * 224

    private let env: ORTEnv
    private let path: String
    private let lock = NSLock()
    private var session: ORTSession
    private var engineName = "процессор"

    var engine: String {
        lock.lock(); defer { lock.unlock() }
        return engineName
    }

    init(path: String) throws {
        self.path = path
        env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
        session = try ORTSession(env: env, modelPath: path, sessionOptions: try S3DModel.cpuOptions())
    }

    private static func cpuOptions() throws -> ORTSessionOptions {
        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.all)
        // The performance cores; the rest of the device stays responsive.
        try options.setIntraOpNumThreads(Int32(max(2, min(4, ProcessInfo.processInfo.activeProcessorCount - 2))))
        return options
    }

    private static func coreMLOptions() throws -> ORTSessionOptions {
        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.all)
        var settings: [String: String] = [
            "ModelFormat": "MLProgram",
            "MLComputeUnits": "ALL",
            "RequireStaticInputShapes": "1",
        ]
        // Core ML compiles the model for the device; kept, the next start skips that.
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let dir = caches.appendingPathComponent("coreml-s3d", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            settings["ModelCacheDirectory"] = dir.path
        }
        try options.appendCoreMLExecutionProvider(withOptionsV2: settings)
        return options
    }

    private static func run(_ session: ORTSession, _ input: NSMutableData) throws -> [Float] {
        let tensor = try ORTValue(tensorData: input, elementType: ORTTensorElementDataType.float, shape: shape)
        let out = try session.run(withInputs: [inputName: tensor], outputNames: [outputName], runOptions: nil)
        guard let value = out[outputName] else {
            throw NSError(domain: "RSL", code: 1, userInfo: [NSLocalizedDescriptionKey: "no output"])
        }
        let data = try value.tensorData() as Data
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /* `input`: 32 frames of planar RGB, 0...1 (S3DModel.count floats). */
    func logits(_ input: NSMutableData) throws -> [Float] {
        lock.lock()
        let current = session
        lock.unlock()
        return try S3DModel.run(current, input)
    }

    /* A made-up but not empty picture, the same every time: for warming up,
       timing and comparing the two engines. */
    static func sample() -> NSMutableData {
        let data = NSMutableData(length: count * MemoryLayout<Float>.size)!
        let f = data.mutableBytes.bindMemory(to: Float.self, capacity: count)
        var i = 0
        for t in 0..<32 {
            for c in 0..<3 {
                for y in 0..<224 {
                    let row = 0.07 * Double(y) + 0.3 * Double(t) + Double(c)
                    for x in 0..<224 {
                        f[i] = Float(0.5 + 0.5 * sin(0.05 * Double(x) + row))
                        i += 1
                    }
                }
            }
        }
        return data
    }

    struct Trial {
        var cpuMs: Double = 0
        var coreMLMs: Double = 0
        var agrees = false
        var switched = false
        var note = ""
    }

    /* Tries Core ML and switches to it if it is right and faster. Slow (the
       first Core ML run compiles the model): call it off the main thread. */
    @discardableResult
    func tryCoreML() -> Trial {
        var trial = Trial()
        guard ORTIsCoreMLExecutionProviderAvailable() else {
            trial.note = "Core ML не входит в сборку"
            return trial
        }
        // Compiling a model this size is the one thing here that the system
        // may kill the app for on a small device. A note is left before the
        // attempt and removed after it. Three attempts in a row that never
        // got to remove it (one or two could be the person closing the app)
        // mean it takes the app down, and it is not made again in this version.
        let key = "coreml-unfinished-" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0")
        let defaults = UserDefaults.standard
        let unfinished = defaults.integer(forKey: key)
        if unfinished >= 3 {
            trial.note = "Core ML отключён: три попытки не завершились"
            return trial
        }
        defaults.set(unfinished + 1, forKey: key)
        defer { defaults.removeObject(forKey: key) }
        let input = S3DModel.sample()
        do {
            lock.lock()
            let cpu = session
            lock.unlock()
            _ = try S3DModel.run(cpu, input)
            var t0 = CFAbsoluteTimeGetCurrent()
            let reference = try S3DModel.run(cpu, input)
            trial.cpuMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

            let candidate = try ORTSession(env: env, modelPath: path, sessionOptions: try S3DModel.coreMLOptions())
            _ = try S3DModel.run(candidate, input)               // compiles and warms up
            t0 = CFAbsoluteTimeGetCurrent()
            let answer = try S3DModel.run(candidate, input)
            trial.coreMLMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

            trial.agrees = S3DModel.agree(reference, answer)
            if trial.agrees && trial.coreMLMs < trial.cpuMs * 0.9 {
                lock.lock()
                session = candidate
                engineName = "Core ML"
                lock.unlock()
                trial.switched = true
            }
        } catch {
            trial.note = error.localizedDescription
        }
        return trial
    }

    /* The same answer: the same best class, and probabilities within 3%. */
    static func agree(_ a: [Float], _ b: [Float]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        let pa = softmax(a), pb = softmax(b)
        var bestA = 0, bestB = 0
        var worst: Float = 0
        for i in 0..<a.count {
            if pa[i] > pa[bestA] { bestA = i }
            if pb[i] > pb[bestB] { bestB = i }
            worst = max(worst, abs(pa[i] - pb[i]))
        }
        return bestA == bestB && worst < 0.03
    }

    static func softmax(_ logits: [Float]) -> [Float] {
        let top = logits.max() ?? 0
        let e = logits.map { exp($0 - top) }
        let sum = e.reduce(0, +)
        return e.map { $0 / sum }
    }
}

/* When a window's answer becomes a word.

   Measured on the lesson video (in the web app, the same model): with a
   window every 8-12 frames a sign is seen several times, so demanding two
   windows in a row cuts the wrong words without losing right ones. Rarer than
   that, most signs get one window only, and the same demand would drop half
   the vocabulary. */
struct Rule {
    static let threshold: Float = 0.7            // a window counts as confident from here
    static let instant: Float = 0.9              // this sure on its own: accept without a second window
    static let dense = 12                        // up to this stride, wait for two windows in a row
    static let blank = "no"                      // the model's "no sign here" class

    private var streakLabel: String? = nil
    private var streak = 0
    private var lastAccepted: String? = nil

    enum Verdict: Equatable {
        case nothing
        case accepted(word: String?)             // word is nil when it repeats the last one
    }

    mutating func reset() {
        streakLabel = nil
        streak = 0
        lastAccepted = nil
    }

    mutating func judge(label: String, confidence: Float, stride: Int) -> Verdict {
        let need = stride <= Rule.dense ? 2 : 1
        let confident = confidence >= Rule.threshold && label != Rule.blank
        if confident && label == streakLabel {
            streak += 1
        } else if confident {
            streakLabel = label
            streak = 1
        } else {
            streakLabel = nil
            streak = 0
        }
        guard confident && (streak >= need || confidence >= Rule.instant) else { return .nothing }
        streakLabel = nil
        streak = 0
        if label != lastAccepted {
            lastAccepted = label
            return .accepted(word: label)
        }
        return .accepted(word: nil)
    }
}

struct Guess: Equatable {
    var label: String
    var p: Float
}

final class Recognizer {
    static let window = 32
    static let plane = 3 * FrameTools.side * FrameTools.side
    static let frameMs = 1000.0 / 30

    struct Stats {
        var inferMs: Double = 0
        var stride = 8
        var fps: Double = 0
        var frozen = false
        var ready = false
        var top: [Guess] = []
        var engine = ""
    }

    /* Both are called on the queue the frames arrive on. */
    var onWord: ((String) -> Void)?
    var onStats: ((Stats) -> Void)?

    private(set) var stats = Stats()
    private var model: S3DModel?
    private var labels: [String] = []

    // The ring of the last 32 frames, each as planar numbers. Touched only on
    // the queue the frames arrive on.
    private var ring: [UnsafeMutablePointer<Float>] = []
    private var head = 0                         // next slot to write
    private var filled = 0
    private var sinceInfer = 0
    private var busy = false
    private var running = false
    private var generation = 0                   // bumped on start: answers of an older run are dropped

    private var scratch = [UInt8](repeating: 0, count: FrameTools.side * FrameTools.side * 4)
    private var previousSmall: [Int16] = []
    private var motion: [Float] = []
    private var arrivals: [Double] = []
    private var recent: [Double] = []
    private var rule = Rule()

    private let inferQueue = DispatchQueue(label: "rsl.infer", qos: .userInitiated)
    private let tuneQueue = DispatchQueue(label: "rsl.tune", qos: .utility)

    var ready: Bool { model != nil }

    deinit {
        for p in ring { p.deallocate() }
    }

    /* Loads the labels and the model and warms it up. Slow: call off the main thread. */
    func load(modelPath: String, labelsPath: String) throws {
        if model != nil { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: labelsPath))
        labels = try JSONDecoder().decode([String].self, from: data)
        let loaded = try S3DModel(path: modelPath)
        _ = try loaded.logits(S3DModel.sample())                 // the first run is the slow one
        if ring.isEmpty {
            for _ in 0..<Recognizer.window {
                let p = UnsafeMutablePointer<Float>.allocate(capacity: Recognizer.plane)
                p.initialize(repeating: 0, count: Recognizer.plane)
                ring.append(p)
            }
        }
        model = loaded
        stats.ready = true
        stats.engine = loaded.engine
        tuneQueue.async { [weak self] in
            let trial = loaded.tryCoreML()
            NSLog("RSL: CPU %.0f ms, Core ML %.0f ms, agrees %d, switched %d %@",
                  trial.cpuMs, trial.coreMLMs, trial.agrees ? 1 : 0, trial.switched ? 1 : 0, trial.note)
            self?.engineNote = String(format: "ЦП %.0f мс · Core ML %.0f мс%@", trial.cpuMs, trial.coreMLMs,
                                      trial.note.isEmpty ? (trial.agrees ? "" : " · ответы расходятся") : " · " + trial.note)
        }
    }

    /* What the comparison of the two engines found (for the debug view). */
    private(set) var engineNote = ""

    func start() {
        running = true
        generation += 1
        filled = 0
        sinceInfer = 0
        head = 0
        rule.reset()
        previousSmall = []
        motion.removeAll()
        arrivals.removeAll()
        stats.frozen = false
    }

    func stop() {
        running = false
    }

    /* A frame from the camera and the part of it the model should see
       (in the frame's own pixels; nil for all of it). */
    func push(_ buffer: CVPixelBuffer, crop: CGRect?) {
        guard running, model != nil else { return }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let r = FrameTools.clamp(crop, width: width, height: height)
        let side = FrameTools.side
        let ok = scratch.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return FrameTools.scale(buffer, crop: r, into: base, outWidth: side, outHeight: side, outRowBytes: side * 4)
        }
        guard ok else { return }
        let change = scratch.withUnsafeBufferPointer { px in
            FrameTools.planes(from: px.baseAddress!, into: ring[head], previous: &previousSmall)
        }
        filed(change: change)
    }

    /* For tests: a frame already converted to planar numbers. */
    func pushPlanes(_ f: UnsafePointer<Float>) {
        guard running, model != nil else { return }
        ring[head].update(from: f, count: Recognizer.plane)
        filed(change: -1)
    }

    private func filed(change: Float) {
        head = (head + 1) % Recognizer.window
        if filled < Recognizer.window { filled += 1 }
        sinceInfer += 1

        let now = CFAbsoluteTimeGetCurrent() * 1000
        arrivals.append(now)
        if arrivals.count > 60 { arrivals.removeFirst(arrivals.count - 60) }
        if arrivals.count > 1, now > arrivals[0] {
            stats.fps = Double(arrivals.count - 1) * 1000 / (now - arrivals[0])
        }
        // A covered lens looks to the model like "no sign" for ever, which on
        // screen reads as the app being broken. Spot it instead.
        if change >= 0 {
            motion.append(change)
            if motion.count > 60 { motion.removeFirst(motion.count - 60) }
            stats.frozen = motion.count == 60 && motion.reduce(0, +) / Float(motion.count) < 0.3
        }
        maybeInfer()
    }

    private func maybeInfer() {
        guard !busy, filled >= Recognizer.window, sinceInfer >= stats.stride, let model = model else { return }
        busy = true
        sinceInfer = 0
        // The window, oldest frame first.
        let bytes = Recognizer.plane * MemoryLayout<Float>.size
        let input = NSMutableData(length: Recognizer.window * bytes)!
        for i in 0..<Recognizer.window {
            memcpy(input.mutableBytes.advanced(by: i * bytes), ring[(head + i) % Recognizer.window], bytes)
        }
        let run = generation
        let home = callbackQueue
        inferQueue.async { [weak self] in
            let t0 = CFAbsoluteTimeGetCurrent()
            let logits = try? model.logits(input)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            let engine = model.engine
            home.async { self?.finished(logits: logits, ms: ms, run: run, engine: engine) }
        }
    }

    /* The queue frames arrive on; answers come back to it. Set by the owner
       before the first frame. */
    var callbackQueue = DispatchQueue.main

    private func finished(logits: [Float]?, ms: Double, run: Int, engine: String) {
        busy = false
        guard let logits = logits else { return }
        pace(ms)
        stats.engine = engine
        guard running, run == generation else { return }
        let p = S3DModel.softmax(logits)
        let order = p.indices.sorted { p[$0] > p[$1] }.prefix(3)
        stats.top = order.map { Guess(label: $0 < labels.count ? labels[$0] : "№\($0)", p: p[$0]) }
        if let best = stats.top.first {
            if case .accepted(let word) = rule.judge(label: best.label, confidence: best.p, stride: stats.stride) {
                if let word = word { onWord?(word) }
                // Start the next window from scratch, as the reference app
                // does, so the tail of one sign cannot be read as another.
                filled = 0
                sinceInfer = 0
            }
        }
        onStats?(stats)
    }

    private func pace(_ ms: Double) {
        recent.append(ms)
        if recent.count > 5 { recent.removeFirst(recent.count - 5) }
        let median = recent.sorted()[recent.count / 2]
        stats.inferMs = median
        // Leave a little room: a window that starts before the last one is
        // done only queues up work and adds delay.
        stats.stride = min(32, max(8, Int((median * 1.15 / Recognizer.frameMs).rounded(.up))))
    }
}
