import AVFoundation
import Foundation
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

    func start(
        host: String,
        port: Int
    ) async throws {

        guard !running else {
            return
        }

        var mixerVideoSettings = await mixer.videoMixerSettings
        mixerVideoSettings.mode = .passthrough

        await mixer.setVideoMixerSettings(
            mixerVideoSettings
        )

        await mixer.setFrameRate(30)

        let videoSettings = VideoCodecSettings(
            videoSize: .init(
                width: 1280,
                height: 720
            ),
            bitRate: 4 * 1000 * 1000,
            profileLevel:
                kVTProfileLevel_H264_Main_AutoLevel as String,
            scalingMode: .trim,
            bitRateMode: .average,
            maxKeyFrameIntervalDuration: 1,
            allowFrameReordering: false,
            isHardwareEncoderEnabled: true
        )

        await stream.setVideoSettings(
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

        Task {
            await mixer.append(
                sampleBuffer
            )
        }
    }

    func stop() {
        guard running else {
            return
        }

        running = false

        Task {
            await stream.close()
            await connection.close()
        }
    }
}