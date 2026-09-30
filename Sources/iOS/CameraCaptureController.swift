import AVFoundation
import Foundation

final class CameraCaptureController: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()

    var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onStatus: ((String) -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.relaxpuke.aiobs.camera")
    private let videoOutput = AVCaptureVideoDataOutput()

    private var configured = false

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            sessionQueue.async { [weak self] in
                self?.configureAndStart()
            }

        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }

                if granted {
                    self.sessionQueue.async {
                        self.configureAndStart()
                    }
                } else {
                    DispatchQueue.main.async {
                        self.onStatus?("CAMERA_DENIED")
                    }
                }
            }

        case .denied, .restricted:
            DispatchQueue.main.async { [weak self] in
                self?.onStatus?("CAMERA_DENIED")
            }

        @unknown default:
            DispatchQueue.main.async { [weak self] in
                self?.onStatus?("CAMERA_UNKNOWN")
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if self.session.isRunning {
                self.session.stopRunning()
            }

            DispatchQueue.main.async { [weak self] in
                self?.onStatus?("CAMERA_STOPPED")
            }
        }
    }

    private func configureAndStart() {
        if !configured {
            session.beginConfiguration()
            session.sessionPreset = .hd1280x720

            guard
                let camera = AVCaptureDevice.default(
                    .builtInWideAngleCamera,
                    for: .video,
                    position: .back
                )
            else {
                session.commitConfiguration()

                DispatchQueue.main.async { [weak self] in
                    self?.onStatus?("CAMERA_NOT_FOUND")
                }
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: camera)

                guard session.canAddInput(input) else {
                    session.commitConfiguration()

                    DispatchQueue.main.async { [weak self] in
                        self?.onStatus?("CAMERA_INPUT_FAILED")
                    }
                    return
                }

                session.addInput(input)

                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String:
                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                ]

                guard session.canAddOutput(videoOutput) else {
                    session.commitConfiguration()

                    DispatchQueue.main.async { [weak self] in
                        self?.onStatus?("CAMERA_OUTPUT_FAILED")
                    }
                    return
                }

                videoOutput.setSampleBufferDelegate(
                    self,
                    queue: sessionQueue
                )

                session.addOutput(videoOutput)

                configured = true
                session.commitConfiguration()
            } catch {
                session.commitConfiguration()

                DispatchQueue.main.async { [weak self] in
                    self?.onStatus?("CAMERA_CONFIG_ERROR: \(error.localizedDescription)")
                }
                return
            }
        }

        if !session.isRunning {
            session.startRunning()
        }

        DispatchQueue.main.async { [weak self] in
            self?.onStatus?("CAMERA_READY")
        }
    }
}

extension CameraCaptureController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onSampleBuffer?(sampleBuffer)
    }
}