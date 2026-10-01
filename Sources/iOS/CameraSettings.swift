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
    let minExposureSeconds: Double
    let maxExposureSeconds: Double

    var title: String {
        "\(width)×\(height)"
    }
}

struct CameraCapabilities: Sendable {
    let resolutions: [CameraResolutionOption]
    let minExposureBias: Float
    let maxExposureBias: Float
    let maxZoomFactor: Float

    static let empty = CameraCapabilities(
        resolutions: [],
        minExposureBias: -8,
        maxExposureBias: 8,
        maxZoomFactor: 1
    )
}

enum CameraExposureMode: String, CaseIterable, Identifiable, Sendable {
    case auto
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:
            return "Auto"
        case .manual:
            return "Manual"
        }
    }
}

enum CameraFocusMode: String, CaseIterable, Identifiable, Sendable {
    case auto
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:
            return "Auto"
        case .manual:
            return "Manual"
        }
    }
}

enum CameraWhiteBalanceMode: String, CaseIterable, Identifiable, Sendable {
    case auto
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:
            return "Auto"
        case .manual:
            return "Manual"
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
    var exposureDurationSeconds: Double
    var exposureBiasEV: Float

    var focusMode: CameraFocusMode
    var focusPosition: Float

    var whiteBalanceMode: CameraWhiteBalanceMode
    var whiteBalanceTemperature: Float
    var whiteBalanceTint: Float

    var zoomFactor: Float

    static let `default` = CameraSettings(
        resolutionID: 0,
        width: 1280,
        height: 720,
        fps: 30,
        exposureMode: .auto,
        iso: 100,
        exposureDurationSeconds: 1.0 / 30.0,
        exposureBiasEV: 0,
        focusMode: .auto,
        focusPosition: 0.5,
        whiteBalanceMode: .auto,
        whiteBalanceTemperature: 5000,
        whiteBalanceTint: 0,
        zoomFactor: 1
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
    let exposureDurationSeconds: Double
    let exposureBiasEV: Float

    let focusMode: CameraFocusMode
    let focusPosition: Float

    let whiteBalanceMode: CameraWhiteBalanceMode
    let whiteBalanceTemperature: Float
    let whiteBalanceTint: Float

    let zoomFactor: Float

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

    var shutterText: String {
        guard exposureDurationSeconds > 0 else {
            return "Auto"
        }
        if exposureDurationSeconds >= 0.5 {
            return String(format: "%.2fs", exposureDurationSeconds)
        }
        return "1/\(max(1, Int((1.0 / exposureDurationSeconds).rounded())))"
    }

    var exposureSummary: String {
        if exposureMode == .auto {
            return "Auto"
        }
        return "ISO \(Int(iso.rounded())) · \(shutterText)"
    }

    var focusSummary: String {
        focusMode == .auto ? "Focus Auto" : String(format: "Focus %.2f", focusPosition)
    }

    var whiteBalanceSummary: String {
        if whiteBalanceMode == .auto {
            return "WB Auto"
        }
        return "WB \(Int(whiteBalanceTemperature.rounded()))K"
    }
}

struct CameraRuntimeStats: Sendable {
    let fps: Double
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
