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
        bitrateKbps: Int,
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
        try await mixer.setFrameRate(Double(fps))

        let portrait =
            interfaceOrientation == .portrait ||
            interfaceOrientation == .portraitUpsideDown

        let streamWidth = portrait ? settings.height : settings.width
        let streamHeight = portrait ? settings.width : settings.height

        let videoSettings = VideoCodecSettings(
            videoSize: .init(
                width: streamWidth,
                height: streamHeight
            ),
            bitRate: max(256_000, bitrateKbps * 1_000),
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
}
