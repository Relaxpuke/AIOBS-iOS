import AVFoundation
import Foundation
import UIKit
import HaishinKit
import SRTHaishinKit
import VideoToolbox

final class SRTCameraStreamer {
    private let mixer = MediaMixer(
        captureSessionMode: .manual
    )

    private let connection = SRTConnection()

    private lazy var stream = SRTStream(
        connection: connection
    )

    private var running = false

    @MainActor
    func start(
        host: String,
        port: Int,
        settings: CameraSettings,
        interfaceOrientation: UIInterfaceOrientation
    ) async throws {
        guard !running else {
            return
        }

        var mixerVideoSettings = await mixer.videoMixerSettings
        mixerVideoSettings.mode = .passthrough

        await mixer.setVideoMixerSettings(
            mixerVideoSettings
        )

        let fps = max(1, Int(settings.fps.rounded()))
        try await mixer.setFrameRate(fps)

        let portrait =
            interfaceOrientation == .portrait ||
            interfaceOrientation == .portraitUpsideDown

        // CameraCaptureController rotates the VideoDataOutput frames to the
        // current interface orientation. Encode the corresponding dimensions
        // so a portrait stream stays portrait on the PC side.
        let streamWidth = portrait ? settings.height : settings.width
        let streamHeight = portrait ? settings.width : settings.height

        let videoSettings = VideoCodecSettings(
            videoSize: .init(
                width: streamWidth,
                height: streamHeight
            ),
            bitRate: bitRate(
                width: streamWidth,
                height: streamHeight,
                fps: settings.fps
            ),
            profileLevel:
                kVTProfileLevel_H264_Main_AutoLevel as String,
            scalingMode: .trim,
            bitRateMode: .average,
            maxKeyFrameIntervalDuration: 1,
            allowFrameReordering: false,
            isHardwareAcceleratedEnabled: true
        )

        try await stream.setVideoSettings(
            videoSettings
        )

        await mixer.startRunning()

        await mixer.addOutput(
            stream
        )

        guard let srtURL = URL(
            string:
                "srt://\(host):\(port)?mode=caller&transtype=live"
        ) else {
            throw URLError(.badURL)
        }

        try await connection.connect(
            srtURL
        )

        await stream.publish()

        running = true
    }

    func append(
        sampleBuffer: CMSampleBuffer
    ) {
        guard running else {
            return
        }

        let mixer = self.mixer

        Task {
            await mixer.append(
                sampleBuffer
            )
        }
    }

    @MainActor
    func stop() {
        guard running else {
            return
        }

        running = false

        let stream = self.stream
        let connection = self.connection

        Task {
            await stream.close()
            await connection.close()
        }
    }

    private func bitRate(
        width: Int,
        height: Int,
        fps: Double
    ) -> Int {
        let pixels = Double(max(1, width * height))
        let frameScale = max(1.0, fps / 30.0)
        let pixelScale = pixels / Double(1280 * 720)

        let estimated = 2_000_000.0 * pixelScale * frameScale
        return Int(
            min(
                24_000_000.0,
                max(2_000_000.0, estimated)
            )
        )
    }
}
