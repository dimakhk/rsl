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

    init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
    }

    /* Reads server.json and connects. Without a server configured this does
       nothing and the app stays on the device's model. */
    func start(packed: URL?) {
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
                self.connect()
            }
        }
        lookup.resume()
    }

    static func parse(_ data: Data?) -> (url: URL, model: String)? {
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["url"] as? String, let url = URL(string: text),
              url.scheme == "wss" || url.scheme == "ws" else { return nil }
        return (url, json["model"] as? String ?? "")
    }

    private func connect() {
        guard let url = url else { return }
        task?.cancel(with: .goingAway, reason: nil)
        let next = session.webSocketTask(with: url)
        next.maximumMessageSize = 1 << 20
        task = next
        next.resume()
        listen(next)
    }

    private func retryLater(_ failed: URLSessionWebSocketTask) {
        guard failed === task else { return }
        task = nil
        if stats.online {
            stats.online = false
            onStats?(stats)
        }
        queue.asyncAfter(deadline: .now() + Cloud.retrySeconds) { [weak self] in
            guard let self = self, self.task == nil else { return }
            self.connect()
        }
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
              let kind = d["t"] as? String else { return }
        if kind == "word" {
            if running, let label = d["label"] as? String { onWord?(label) }
        } else if kind == "top" {
            stats.ms = (d["ms"] as? NSNumber)?.doubleValue ?? 0
            stats.lag = (d["lag"] as? NSNumber)?.doubleValue ?? 0
            let rows = d["top"] as? [[Any]] ?? []
            stats.top = rows.compactMap { row in
                guard row.count >= 3, let p = (row[2] as? NSNumber)?.floatValue else { return nil }
                let index = (row[0] as? NSNumber)?.intValue ?? 0
                let label = (row[1] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "№\(index)"
                return Guess(label: label, p: p)
            }
            onStats?(stats)
        }
    }

    // MARK: URLSessionWebSocketDelegate (on `queue`)

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol `protocol`: String?) {
        guard webSocketTask === task else { return }
        stats.online = true
        if running { webSocketTask.send(.string("reset")) { _ in } }
        onStats?(stats)
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
        running = true
        tick = 0
        inFlight = 0
        sent.removeAll()
        stats.top = []
        if stats.online { task?.send(.string("reset")) { _ in } }
    }

    func stop() {
        running = false
    }

    /* Called for every captured frame (30 a second); every second one is sent. */
    func push(_ buffer: CVPixelBuffer, crop: CGRect?) {
        guard running, stats.online, let socket = task else { return }
        tick += 1
        if tick % 2 == 0 { return }
        if inFlight >= Cloud.maxInFlight { return }      // behind: drop rather than pile up
        let r = FrameTools.clamp(crop, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        inFlight += 1
        encodeQueue.async { [weak self] in
            let jpeg = FrameTools.letterboxJPEG(buffer, crop: r)
            // 8 bytes of time (ms, little-endian double), then the picture.
            var stamp = (Date().timeIntervalSince1970 * 1000).bitPattern.littleEndian
            var packet = Data(bytes: &stamp, count: 8)
            if let jpeg = jpeg { packet.append(jpeg) }
            self?.queue.async {
                guard let self = self else { return }
                self.inFlight = max(0, self.inFlight - 1)
                guard jpeg != nil, self.running, self.stats.online, socket === self.task else { return }
                self.inFlight += 1
                socket.send(.data(packet)) { [weak self] _ in
                    self?.queue.async { self?.inFlight = max(0, (self?.inFlight ?? 1) - 1) }
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
