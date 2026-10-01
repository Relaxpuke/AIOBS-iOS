import AVFoundation
import CoreMedia
import Foundation

struct CameraResolutionOption: Identifiable, Hashable, Sendable {
    let id: Int
    let width: Int
    let height: Int
    let supportedFPS: [Double]
    let minISO: Float
    let maxISO: Float

    var title: String {
        "\(width)×\(height)"
    }
}

struct CameraCapabilities: Sendable {
    let resolutions: [CameraResolutionOption]

    static let empty = CameraCapabilities(resolutions: [])
}

enum CameraExposureMode: String, CaseIterable, Identifiable, Sendable {
    case auto
    case manualISO

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:
            return "Auto"
        case .manualISO:
            return "Manual ISO"
        }
    }
}

struct CameraSettings: Equatable, Sendable {
    var resolutionID: Int
    var width: Int
    var height: Int
    var fps: Double
    var exposureMode: CameraExposureMode
    var iso: Float

    static let `default` = CameraSettings(
        resolutionID: 0,
        width: 1280,
        height: 720,
        fps: 30,
        exposureMode: .auto,
        iso: 100
    )
}

struct CameraStateSnapshot: Sendable {
    let resolutionID: Int
    let width: Int
    let height: Int
    let fps: Double
    let iso: Float
    let minISO: Float
    let maxISO: Float
    let exposureMode: CameraExposureMode

    var resolutionText: String {
        "\(width)×\(height)"
    }

    var fpsText: String {
        if abs(fps.rounded() - fps) < 0.01 {
            return "\(Int(fps.rounded())) FPS"
        }
        return String(format: "%.1f FPS", fps)
    }

    var isoText: String {
        if exposureMode == .auto {
            return "ISO Auto"
        }
        return "ISO \(Int(iso.rounded()))"
    }
}

func cameraFPSValues(for format: AVCaptureDevice.Format) -> [Double] {
    let commonValues: [Double] = [24, 25, 30, 48, 50, 60, 90, 120, 240]
    var values = Set<Int>()

    for range in format.videoSupportedFrameRateRanges {
        for value in commonValues {
            if value >= range.minFrameRate - 0.01,
               value <= range.maxFrameRate + 0.01 {
                values.insert(Int(value.rounded()))
            }
        }

        let minimum = Int(range.minFrameRate.rounded())
        let maximum = Int(range.maxFrameRate.rounded())

        if minimum > 0 && minimum <= 240 {
            values.insert(minimum)
        }
        if maximum > 0 && maximum <= 240 {
            values.insert(maximum)
        }
    }

    return values.sorted().map(Double.init)
}

func cameraSupportsFPS(
    _ fps: Double,
    format: AVCaptureDevice.Format
) -> Bool {
    format.videoSupportedFrameRateRanges.contains { range in
        fps >= range.minFrameRate - 0.01 &&
        fps <= range.maxFrameRate + 0.01
    }
}

func cameraFormatDimensions(
    _ format: AVCaptureDevice.Format
) -> (width: Int, height: Int) {
    let dimensions = CMVideoFormatDescriptionGetDimensions(
        format.formatDescription
    )

    return (
        width: Int(dimensions.width),
        height: Int(dimensions.height)
    )
}
