import AVFoundation
import Foundation

/* The front camera: 1280x720 at 30 frames a second, upright, as BGRA.

   The frames the models get are not mirrored - a sign made with the right
   hand stays on the signer's right, as in the videos the models learnt from.
   The picture on screen is mirrored, as a selfie camera shows it; that is
   done by the preview layer.

   Upright: the sensor sits differently in different devices (on newer iPads
   the front camera is on the long edge), so the angle is not assumed. The
   system is asked what turns the picture upright on this screen, and the
   same angle goes to the picture on screen and to the frames. */

final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Failure: Error {
        case denied                              // the person said no, or it is switched off in Settings
        case unavailable                         // no camera (the Simulator), or it would not start
    }

    let session = AVCaptureSession()

    /* Called on the queue given to `configure`, for every frame. */
    var onFrame: ((CVPixelBuffer) -> Void)?
    /* Called on the main queue when the system takes the camera away. */
    var onLost: (() -> Void)?

    private let sessionQueue = DispatchQueue(label: "rsl.camera")
    private var configured = false
    private var device: AVCaptureDevice?
    private var output: AVCaptureVideoDataOutput?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationWatch: NSKeyValueObservation?
    private var frameQueue = DispatchQueue.main
    private var observers: [NSObjectProtocol] = []

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    /* Asks for access if it has not been asked yet, then starts the camera.
       `done` is called on the main queue. */
    func start(frames queue: DispatchQueue, done: @escaping (Result<Void, Failure>) -> Void) {
        frameQueue = queue
        let finish = { (r: Result<Void, Failure>) in DispatchQueue.main.async { done(r) } }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            sessionQueue.async { finish(self.run()) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted { self.sessionQueue.async { finish(self.run()) } } else { finish(.failure(.denied)) }
            }
        default:
            finish(.failure(.denied))
        }
    }

    /* The layer that shows the picture. Call on the main queue. */
    func attach(preview layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        watchRotation()
    }

    /* Follows the angle that keeps the picture upright on this screen. */
    private func watchRotation() {
        DispatchQueue.main.async {
            guard let device = self.device, let layer = self.previewLayer else { return }
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
            self.rotation = coordinator
            self.rotationWatch = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) {
                [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                DispatchQueue.main.async { self?.turn(to: angle) }
            }
        }
    }

    private func turn(to angle: CGFloat) {
        if let connection = output?.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        if let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    /* Releases the camera, so its indicator goes out. */
    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func run() -> Result<Void, Failure> {
        if !configured {
            guard configure() else { return .failure(.unavailable) }
            configured = true
        }
        if !session.isRunning { session.startRunning() }
        return session.isRunning ? .success(()) : .failure(.unavailable)
    }

    private func configure() -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        guard session.canAddInput(input) else { return false }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true              // behind: drop rather than pile up
        output.setSampleBufferDelegate(self, queue: frameQueue)
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)

        self.device = device
        self.output = output
        if let connection = output.connection(with: .video) {
            // Portrait on a phone; corrected right away by watchRotation where it differs.
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }

        // Thirty frames a second: the models read 32 frames as about a second.
        if (try? device.lockForConfiguration()) != nil {
            let thirty = CMTime(value: 1, timescale: 30)
            let supported = device.activeFormat.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
            if supported {
                device.activeVideoMinFrameDuration = thirty
                device.activeVideoMaxFrameDuration = thirty
            }
            device.unlockForConfiguration()
        }

        watchRotation()

        // An interruption (the app goes to the background, a call comes in) ends
        // by itself and the session carries on; an error does not.
        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] _ in
                self?.onLost?()
            })
        return true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(buffer)
    }
}
