import AVFoundation
import CoreMedia
import Foundation
import UIKit

extension UIInterfaceOrientation {
    var aiobsVideoOrientation: AVCaptureVideoOrientation {
        switch self {
        case .portrait:
            return .portrait
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .landscapeLeft:
            return .landscapeLeft
        case .landscapeRight:
            return .landscapeRight
        default:
            return .portrait
        }
    }
}

final class CameraCaptureController: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()

    var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onStatus: ((String) -> Void)?
    var onCapabilities: ((CameraCapabilities) -> Void)?
    var onCameraState: ((CameraStateSnapshot) -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.relaxpuke.aiobs.camera")
    private let videoOutput = AVCaptureVideoDataOutput()

    private var configured = false
    private var requestedInterfaceOrientation: UIInterfaceOrientation = .portrait
    private var camera: AVCaptureDevice?

    private var capabilities: CameraCapabilities = .empty
    private var currentSettings = CameraSettings.default

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

    func setInterfaceOrientation(_ orientation: UIInterfaceOrientation) {
        requestedInterfaceOrientation = orientation

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.applyVideoOrientationLocked()
        }
    }

    func apply(settings: CameraSettings) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.applySettingsLocked(settings)
        }
    }

    private func configureAndStart() {
        if !configured {
            session.beginConfiguration()

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
                self.camera = camera

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

                capabilities = buildCapabilities(for: camera)
                currentSettings = chooseDefaultSettings(for: capabilities)

                applySettingsLocked(
                    currentSettings,
                    withinExistingConfiguration: true,
                    publishCapabilitiesAfterApply: false
                )

                applyVideoOrientationLocked()
                session.commitConfiguration()
            } catch {
                session.commitConfiguration()

                DispatchQueue.main.async { [weak self] in
                    self?.onStatus?(
                        "CAMERA_CONFIG_ERROR: \(error.localizedDescription)"
                    )
                }
                return
            }
        } else {
            applyVideoOrientationLocked()
        }

        publishCapabilities()
        publishCameraState()

        if !session.isRunning {
            session.startRunning()
        }

        DispatchQueue.main.async { [weak self] in
            self?.onStatus?("CAMERA_READY")
        }
    }

    private func buildCapabilities(
        for camera: AVCaptureDevice
    ) -> CameraCapabilities {
        var groups: [String: (
            width: Int,
            height: Int,
            fps: Set<Int>,
            minISO: Float,
            maxISO: Float
        )] = [:]

        for format in camera.formats {
            let dimensions = cameraFormatDimensions(format)
            guard dimensions.width > 0, dimensions.height > 0 else {
                continue
            }

            let fpsValues = cameraFPSValues(for: format)
            guard !fpsValues.isEmpty else {
                continue
            }

            let key = "\(dimensions.width)x\(dimensions.height)"

            if var group = groups[key] {
                group.fps.formUnion(
                    fpsValues.map { Int($0.rounded()) }
                )
                group.minISO = min(group.minISO, format.minISO)
                group.maxISO = max(group.maxISO, format.maxISO)
                groups[key] = group
            } else {
                groups[key] = (
                    width: dimensions.width,
                    height: dimensions.height,
                    fps: Set(fpsValues.map { Int($0.rounded()) }),
                    minISO: format.minISO,
                    maxISO: format.maxISO
                )
            }
        }

        let resolutions = groups.values
            .map { group in
                CameraResolutionOption(
                    id: group.width * 10_000 + group.height,
                    width: group.width,
                    height: group.height,
                    supportedFPS: group.fps.sorted().map(Double.init),
                    minISO: group.minISO,
                    maxISO: group.maxISO
                )
            }
            .filter { !$0.supportedFPS.isEmpty }
            .sorted {
                let lhsPixels = $0.width * $0.height
                let rhsPixels = $1.width * $1.height
                if lhsPixels != rhsPixels {
                    return lhsPixels > rhsPixels
                }
                return $0.title < $1.title
            }

        return CameraCapabilities(resolutions: resolutions)
    }

    private func chooseDefaultSettings(
        for capabilities: CameraCapabilities
    ) -> CameraSettings {
        guard !capabilities.resolutions.isEmpty else {
            return .default
        }

        let preferredResolutions = [
            (1920, 1080),
            (1280, 720)
        ]

        for preferred in preferredResolutions {
            if let option = capabilities.resolutions.first(where: {
                $0.width == preferred.0 && $0.height == preferred.1
            }) {
                let fps = option.supportedFPS.contains(30)
                    ? 30
                    : nearestFPS(to: 30, in: option.supportedFPS)

                return CameraSettings(
                    resolutionID: option.id,
                    width: option.width,
                    height: option.height,
                    fps: fps,
                    exposureMode: .auto,
                    iso: max(option.minISO, min(100, option.maxISO))
                )
            }
        }

        let option = capabilities.resolutions.first!
        return CameraSettings(
            resolutionID: option.id,
            width: option.width,
            height: option.height,
            fps: nearestFPS(to: 30, in: option.supportedFPS),
            exposureMode: .auto,
            iso: max(option.minISO, min(100, option.maxISO))
        )
    }

    private func nearestFPS(
        to target: Double,
        in values: [Double]
    ) -> Double {
        values.min {
            abs($0 - target) < abs($1 - target)
        } ?? target
    }

    private func applySettingsLocked(
        _ settings: CameraSettings,
        withinExistingConfiguration: Bool = false,
        publishCapabilitiesAfterApply: Bool = true
    ) {
        guard configured, let camera else { return }

        let requestedResolution = capabilities.resolutions.first {
            $0.id == settings.resolutionID
        } ?? capabilities.resolutions.first

        guard let resolution = requestedResolution else {
            DispatchQueue.main.async { [weak self] in
                self?.onStatus?("CAMERA_NO_FORMAT")
            }
            return
        }

        guard let formatIndex = bestFormatIndex(
            camera: camera,
            resolution: resolution,
            fps: settings.fps
        ) else {
            DispatchQueue.main.async { [weak self] in
                self?.onStatus?("CAMERA_FPS_UNSUPPORTED")
            }
            return
        }

        let format = camera.formats[formatIndex]
        let actualFPS = nearestSupportedFPS(
            requested: settings.fps,
            format: format
        )

        let minISO = format.minISO
        let maxISO = format.maxISO
        let clampedISO = min(
            maxISO,
            max(minISO, settings.iso)
        )

        do {
            try camera.lockForConfiguration()

            camera.activeFormat = format

            let duration = CMTime(
                value: 1,
                timescale: Int32(max(1, Int(actualFPS.rounded())))
            )

            camera.activeVideoMinFrameDuration = duration
            camera.activeVideoMaxFrameDuration = duration

            if settings.exposureMode == .manualISO {
                camera.setExposureModeCustom(
                    duration: camera.exposureDuration,
                    iso: clampedISO
                )
            } else if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            } else if camera.isExposureModeSupported(.autoExpose) {
                camera.exposureMode = .autoExpose
            }

            camera.unlockForConfiguration()

            currentSettings = CameraSettings(
                resolutionID: resolution.id,
                width: resolution.width,
                height: resolution.height,
                fps: actualFPS,
                exposureMode: settings.exposureMode,
                iso: clampedISO
            )

            if publishCapabilitiesAfterApply {
                capabilities = buildCapabilities(for: camera)
            }

            applyVideoOrientationLocked()
        } catch {
            try? camera.unlockForConfiguration()

            DispatchQueue.main.async { [weak self] in
                self?.onStatus?(
                    "CAMERA_SETTINGS_ERROR: \(error.localizedDescription)"
                )
            }
            return
        }

        publishCapabilities()
        publishCameraState()

        DispatchQueue.main.async { [weak self] in
            self?.onStatus?("CAMERA_SETTINGS_APPLIED")
        }
    }

    private func bestFormatIndex(
        camera: AVCaptureDevice,
        resolution: CameraResolutionOption,
        fps: Double
    ) -> Int? {
        let candidates = camera.formats.enumerated().compactMap { index, format -> (Int, Double, Double)? in
            let dimensions = cameraFormatDimensions(format)

            guard dimensions.width == resolution.width,
                  dimensions.height == resolution.height,
                  cameraSupportsFPS(fps, format: format)
            else {
                return nil
            }

            let maxFPS = format.videoSupportedFrameRateRanges
                .map(\.maxFrameRate)
                .max() ?? fps
            let minFPS = format.videoSupportedFrameRateRanges
                .map(\.minFrameRate)
                .min() ?? 0

            return (index, maxFPS, minFPS)
        }

        return candidates.min {
            let lhsDelta = abs($0.1 - fps)
            let rhsDelta = abs($1.1 - fps)

            if lhsDelta != rhsDelta {
                return lhsDelta < rhsDelta
            }

            return $0.2 > $1.2
        }?.0
    }

    private func nearestSupportedFPS(
        requested: Double,
        format: AVCaptureDevice.Format
    ) -> Double {
        let values = cameraFPSValues(for: format)
        return nearestFPS(to: requested, in: values)
    }

    private func publishCapabilities() {
        let value = capabilities
        DispatchQueue.main.async { [weak self] in
            self?.onCapabilities?(value)
        }
    }

    private func publishCameraState() {
        guard let camera else { return }

        let dimensions = cameraFormatDimensions(camera.activeFormat)
        let snapshot = CameraStateSnapshot(
            resolutionID: currentSettings.resolutionID,
            width: dimensions.width,
            height: dimensions.height,
            fps: currentSettings.fps,
            iso: camera.iso,
            minISO: camera.activeFormat.minISO,
            maxISO: camera.activeFormat.maxISO,
            exposureMode: currentSettings.exposureMode
        )

        DispatchQueue.main.async { [weak self] in
            self?.onCameraState?(snapshot)
        }
    }

    private func applyVideoOrientationLocked() {
        guard configured else { return }

        guard let connection = videoOutput.connection(with: .video) else {
            return
        }

        let orientation = requestedInterfaceOrientation.aiobsVideoOrientation

        if connection.isVideoOrientationSupported {
            connection.videoOrientation = orientation
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
