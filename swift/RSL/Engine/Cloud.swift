import CoreVideo
import Foundation

/* Recognition on a GPU server (SignFlow-R), when one is reachable.

   SignFlow-R recognises more surely than the S3D model that runs in the
   device, but it is far too heavy for a phone. So the phone does what it is
   good at - camera, finding the person, cropping - and sends small frames;
   the server answers with words.

   Which server: the "url" in server.json. The copy on the site is asked
   first, because the server's address does change and the copy packed into
   the app is as old as the build; the packed one is for when the site does
   not answer. No server, or the connection drops: the app carries on with
   the model in the device, and comes back to the server when it answers.

   Frames: the crop, letterboxed into 224x224 on grey as the model was
   trained, JPEG, 15 a second - SignFlow-R reads every second frame of a
   30 fps video. About 0.6 Mbit/s. The other end is the server's own program,
   which is not in this repository. */

final class Cloud: NSObject, URLSessionWebSocketDelegate {
    static let site = URL(string: "https://dimakhk.github.io/rsl/server.json")!
    static let retrySeconds: Double = 3
    static let maxInFlight = 2

    struct Stats {
        var online = false
        var model = ""
        var ms: Double = 0
        var lag: Double = 0
        var top: [Guess] = []
        var fps: Double = 0
    }

    /* Called on the queue given to init. */
    var onWord: ((String) -> Void)?
    var onStats: ((Stats) -> Void)?

    private(set) var stats = Stats()
    var online: Bool { stats.online }

    private let queue: DispatchQueue             // the queue frames arrive on; all state lives on it
    private let encodeQueue = DispatchQueue(label: "rsl.jpeg", qos: .userInitiated)
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 8
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }()
    private var url: URL?
    private var task: URLSessionWebSocketTask?
    private var running = false
    private var tick = 0
    private var inFlight = 0
    private var sent: [Double] = []
    private var generation = UUID().uuidString
    private var lastReply = Date()
    private var lastWord = ""
    private var lastWordAt = Date.distantPast
    private var watchdog: DispatchWorkItem?
    private var token = ""
    private var ready = false

    static func validLabel(_ label: String) -> Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        label.count <= 120 && !label.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }


    init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
    }

    /* Reads server.json and connects. Without a server configured this does
       nothing and the app stays on the device's model. */
    func start(packed: URL?) {
        if let saved = UserDefaults.standard.string(forKey: "cloudEndpoint"),
           let address = URL(string: saved), address.scheme == "wss" {
            queue.async { self.url = address; if self.running { self.connect() } }
            return
        }
        var request = URLRequest(url: Cloud.site, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 4)
        request.httpMethod = "GET"
        let lookup = URLSession(configuration: .ephemeral).dataTask(with: request) { [weak self] data, response, _ in
            var config = Cloud.parse(data)
            if (response as? HTTPURLResponse)?.statusCode != 200 { config = nil }
            if config == nil, let packed = packed { config = Cloud.parse(try? Data(contentsOf: packed)) }
            guard let self = self, let found = config else { return }
            self.queue.async {
                self.url = found.url
                self.stats.model = found.model
                if self.running { self.connect() }
            }
        }
        lookup.resume()
    }

    static func parse(_ data: Data?) -> (url: URL, model: String)? {
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["url"] as? String, let url = URL(string: text),
              url.scheme == "wss", url.host != nil, url.user == nil, url.password == nil else { return nil }
        return (url, json["model"] as? String ?? "")
    }

    private func connect() {
        guard running, let url = url, let credential = CloudCredential.read(host: url.host ?? "") else { return }
        token = credential
        task?.cancel(with: .goingAway, reason: nil)
        var request = URLRequest(url: url)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let next = session.webSocketTask(with: request)
        next.maximumMessageSize = 16 * 1024
        ready = false
        lastReply = Date()
        watch(next)
        task = next
        next.resume()
        listen(next)
    }

    private func retryLater(_ failed: URLSessionWebSocketTask) {
        guard failed === task else { return }
        failed.cancel(with: .goingAway, reason: nil)
        task = nil
        ready = false
        watchdog?.cancel()
        if stats.online {
            stats.online = false
            onStats?(stats)
        }
        queue.asyncAfter(deadline: .now() + Cloud.retrySeconds) { [weak self] in
            guard let self = self, self.running, self.task == nil else { return }
            self.connect()
        }
    }

    private func watch(_ socket: URLSessionWebSocketTask) {
        watchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, socket === self.task, self.running else { return }
            if Date().timeIntervalSince(self.lastReply) > 10 {
                self.retryLater(socket)
            } else {
                self.watch(socket)
            }
        }
        watchdog = work
        queue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func listen(_ current: URLSessionWebSocketTask) {
        current.receive { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                guard current === self.task else { return }
                switch result {
                case .failure:
                    self.retryLater(current)
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    self.listen(current)
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = d["t"] as? String,
              d["session"] as? String == generation, running else { return }
        if kind == "ready" {
            ready = true
            stats.online = true
            lastReply = Date()
            onStats?(stats)
            return
        }
        guard ready else { return }
        if kind == "word" {
            guard let label = d["label"] as? String, Cloud.validLabel(label),
                  let confidence = d["p"] as? Double, confidence.isFinite,
                  (0...1).contains(confidence) else { return }
            let elapsed = Date().timeIntervalSince(lastWordAt)
            guard elapsed >= 0.3, label != lastWord || elapsed >= 2 else { return }
            lastWord = label
            lastWordAt = Date()
            onWord?(label)
        } else if kind == "top" {
            lastReply = Date()
            stats.ms = (d["ms"] as? NSNumber)?.doubleValue ?? 0
            stats.lag = (d["lag"] as? NSNumber)?.doubleValue ?? 0
            let rows = d["top"] as? [[Any]] ?? []
            stats.top = rows.prefix(5).compactMap { row in
                guard row.count >= 3, let p = (row[2] as? NSNumber)?.floatValue, p.isFinite, (0...1).contains(p) else { return nil }
                let index = (row[0] as? NSNumber)?.intValue ?? 0
                let label = (row[1] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "№\(index)"
                guard Cloud.validLabel(label) else { return nil }
                return Guess(label: label, p: p)
            }
            onStats?(stats)
        }
    }

    // MARK: URLSessionWebSocketDelegate (on `queue`)

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol `protocol`: String?) {
        guard webSocketTask === task else { return }
        let reset: [String: String] = ["t": "reset", "session": generation]
        guard running, let data = try? JSONSerialization.data(withJSONObject: reset),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocketTask.send(.string(text)) { [weak self] error in
            if error != nil { self?.queue.async { self?.retryLater(webSocketTask) } }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        retryLater(webSocketTask)
    }

    func urlSession(_ session: URLSession, task finished: URLSessionTask, didCompleteWithError error: Error?) {
        if let socket = finished as? URLSessionWebSocketTask { retryLater(socket) }
    }

    // MARK: frames

    func begin() {
        stop()
        running = true
        generation = UUID().uuidString
        lastWord = ""
        lastWordAt = .distantPast
        tick = 0
        inFlight = 0
        sent.removeAll()
        stats.top = []
        connect()
    }

    func stop() {
        running = false
        watchdog?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        ready = false
        stats.online = false
        inFlight = 0
        onStats?(stats)
    }

    /* Called for every captured frame (30 a second); every second one is sent. */
    func push(_ buffer: CVPixelBuffer, crop: CGRect?) {
        guard running, stats.online, let socket = task else { return }
        tick += 1
        if tick % 2 == 0 { return }
        if inFlight >= Cloud.maxInFlight { return }      // behind: drop rather than pile up
        let r = FrameTools.clamp(crop, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        inFlight += 1
        let run = generation
        encodeQueue.async { [weak self] in
            let jpeg = FrameTools.letterboxJPEG(buffer, crop: r)
            // 8 bytes of time (ms, little-endian double), then the picture.
            var stamp = (Date().timeIntervalSince1970 * 1000).bitPattern.littleEndian
            var packet = Data(bytes: &stamp, count: 8)
            if let jpeg = jpeg { packet.append(jpeg) }
            self?.queue.async {
                guard let self = self else { return }
                guard run == self.generation else { return }
                self.inFlight = max(0, self.inFlight - 1)
                guard jpeg != nil, self.running, self.stats.online, socket === self.task else { return }
                self.inFlight += 1
                socket.send(.data(packet)) { [weak self] error in
                    self?.queue.async {
                        guard let self = self, run == self.generation else { return }
                        self.inFlight = max(0, self.inFlight - 1)
                        if error != nil { self.retryLater(socket) }
                    }
                }
                let now = CFAbsoluteTimeGetCurrent() * 1000
                self.sent.append(now)
                if self.sent.count > 30 { self.sent.removeFirst(self.sent.count - 30) }
                if self.sent.count > 1, now > self.sent[0] {
                    self.stats.fps = Double(self.sent.count - 1) * 1000 / (now - self.sent[0])
                }
            }
        }
    }
}
