import SwiftUI
import AVFoundation
import Vision

final class Camera: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera.capture")
    private let photos = AVCapturePhotoOutput()
    private var configured = false
    private var takingPhoto = false
    private var lastValue = ""
    private var streak = 0
    private var frames = 0
    var isPole = true
    var onDetection: ((String, Double, Bool, Bool) -> Void)?
    var onPhoto: ((Data) -> Void)?
    var onError: ((String) -> Void)?
    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else { DispatchQueue.main.async { self.onError?("Camera access is required. Enable it in iPhone Settings, or use Demo mode.") }; return }
            self.queue.async {
                do {
                    if !self.configured {
                        self.session.beginConfiguration()
                        defer { self.session.commitConfiguration() }
                        self.session.sessionPreset = .photo
                        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { throw URLError(.resourceUnavailable) }
                        let input = try AVCaptureDeviceInput(device: device)
                        guard self.session.canAddInput(input) else { throw URLError(.resourceUnavailable) }
                        self.session.addInput(input)
                        let video = AVCaptureVideoDataOutput()
                        video.alwaysDiscardsLateVideoFrames = true
                        video.setSampleBufferDelegate(self, queue: self.queue)
                        guard self.session.canAddOutput(video), self.session.canAddOutput(self.photos) else { throw URLError(.resourceUnavailable) }
                        self.session.addOutput(video)
                        self.session.addOutput(self.photos)
                        self.configured = true
                    }
                    self.session.startRunning()
                } catch { DispatchQueue.main.async { self.onError?("Camera unavailable: \(error.localizedDescription)") } }
            }
        }
    }
    func stop() { queue.async { self.session.stopRunning() } }
    func capture() {
        queue.async {
            guard self.configured, self.session.isRunning, !self.takingPhoto else {
                DispatchQueue.main.async { self.onError?("Camera is not ready. Please try again.") }; return
            }
            self.takingPhoto = true
            if let connection = self.photos.connection(with: .video), connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            self.photos.capturePhoto(with: AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg]), delegate: self)
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        queue.async { self.takingPhoto = false }
        DispatchQueue.main.async {
            if let data, error == nil { self.onPhoto?(data) }
            else { self.onError?(error?.localizedDescription ?? "Photo capture failed. Try again.") }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frames += 1
        guard frames % 8 == 0, !takingPhoto, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right)
        do {
            var value = ""
            var score = 0.0
            if isPole {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.regionOfInterest = CGRect(x: 0.12, y: 0.3, width: 0.76, height: 0.4)
                try handler.perform([request])
                let candidates = (request.results ?? []).compactMap { $0.topCandidates(1).first }.filter { CaptureRules.valid($0.string) }
                // Ambiguous labels must be verified; do not auto-select among multiple IDs.
                if let best = candidates.max(by: { $0.confidence < $1.confidence }) {
                    value = best.string
                    score = candidates.count == 1 ? Double(best.confidence) : min(Double(best.confidence), 0.5)
                }
            } else {
                let request = VNDetectBarcodesRequest()
                request.symbologies = [.qr]
                try handler.perform([request])
                let codes = (request.results ?? []).compactMap(\.payloadStringValue)
                if codes.count == 1 { value = CaptureRules.serial(codes[0]) }
            }
            if value.isEmpty { lastValue = ""; streak = 0 }
            else if value == lastValue { streak += 1 }
            else { lastValue = value; streak = 1 }
            if !isPole { score = value.isEmpty ? 0 : min(Double(streak) / 3, 1) }
            let high = CaptureRules.valid(value) && score >= CaptureRules.threshold && streak >= 3
            let stable = streak >= 3
            DispatchQueue.main.async { self.onDetection?(value, score, high, stable) }
        } catch { lastValue = ""; streak = 0 }
    }
}

struct CameraPreview: UIViewRepresentable {
    let camera: Camera
    class Preview: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    func makeUIView(context: Context) -> Preview {
        let view = Preview()
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ uiView: Preview, context: Context) {
        if let connection = uiView.previewLayer.connection, connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
    }
}
