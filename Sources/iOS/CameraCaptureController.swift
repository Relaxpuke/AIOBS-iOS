import AVFoundation
import Foundation

final class CameraCaptureController: NSObject {

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(
        label: "com.relaxpuke.aiobs.ios.camera"
    )

    private let videoOutput = AVCaptureVideoDataOutput()

    private var configured = false

    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    func requestPermissionAndStart() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted else {
                return
            }

            self?.configureAndStart()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else {
                return
            }

            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else {
                return
            }

            if !self.configured {
                self.configureSession()
                self.configured = true
            }

            guard !self.session.isRunning else {
                return
            }

            self.session.startRunning()
        }
    }

    private func configureSession() {
        session.beginConfiguration()

        session.sessionPreset = .hd1280x720

        defer {
            session.commitConfiguration()
        }

        guard let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) else {
            return
        }

        guard let input = try? AVCaptureDeviceInput(device: camera) else {
            return
        }

        guard session.canAddInput(input) else {
            return
        }

        session.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]

        videoOutput.setSampleBufferDelegate(
            self,
            queue: sessionQueue
        )

        guard session.canAddOutput(videoOutput) else {
            return
        }

        session.addOutput(videoOutput)

        if let connection = videoOutput.connection(
            with: .video
        ) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }
    }
}

extension CameraCaptureController:
    AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onSampleBuffer?(sampleBuffer)
    }
}