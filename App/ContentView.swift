import AVFoundation
import Combine
import SwiftUI
import UIKit

@MainActor
final class TransportViewModel: ObservableObject {
    let camera = CameraCaptureController()
    let streamer = SRTCameraStreamer()
    let ws = WsClient()

    @Published var pcHost = ""
    @Published var status = "IDLE"
    @Published var streaming = false
    @Published var target: TargetMessage?
    @Published var cameraStatus = "CAMERA_IDLE"

    init() {
        let streamer = self.streamer

        camera.onSampleBuffer = { [weak streamer] sampleBuffer in
            streamer?.append(sampleBuffer: sampleBuffer)
        }

        camera.onStatus = { [weak self] status in
            Task { @MainActor in
                self?.cameraStatus = status
            }
        }

        ws.onStatus = { [weak self] status in
            Task { @MainActor in
                self?.status = status
            }
        }

        ws.onTarget = { [weak self] target in
            Task { @MainActor in
                self?.target = target
            }
        }
    }

    func startCamera() {
        camera.start()
    }

    func startTransport() {
        let host = pcHost.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !host.isEmpty else {
            status = "ENTER_PC_IP"
            return
        }

        target = nil
        status = "STARTING"

        ws.connect(host: host, port: 8765)

        Task {
            do {
                try await streamer.start(
                    host: host,
                    port: 8890
                )

                streaming = true
                status = "SRT_RUNNING"

            } catch {
                streaming = false
                ws.disconnect()
                status = "SRT_ERROR: \(error.localizedDescription)"
            }
        }
    }

    func stopTransport() {
        streamer.stop()
        ws.disconnect()

        streaming = false
        target = nil
        status = "STOPPED"
    }

    func sendClick(x: Double, y: Double) {
        guard streaming else {
            return
        }

        ws.sendClick(
            x: x,
            y: y
        )
    }

    func clearTarget() {
        ws.sendClear()
        target = nil
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()

        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill

        if let connection = view.previewLayer.connection,
           connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }

        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }

        if let connection = uiView.previewLayer.connection,
           connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            fatalError("Expected AVCaptureVideoPreviewLayer")
        }

        return layer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }
}

struct ContentView: View {
    @StateObject private var model = TransportViewModel()

    var body: some View {
        VStack(spacing: 0) {
            controlPanel

            GeometryReader { geometry in
                ZStack {
                    Color.black

                    CameraPreview(
                        session: model.camera.session
                    )
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.height
                    )

                    if let target = model.target,
                       target.status == "TRACKING" {
                        targetOverlay(
                            target: target,
                            size: geometry.size
                        )
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            let x = max(
                                0.0,
                                min(
                                    1.0,
                                    value.location.x / max(
                                        1.0,
                                        geometry.size.width
                                    )
                                )
                            )

                            let y = max(
                                0.0,
                                min(
                                    1.0,
                                    value.location.y / max(
                                        1.0,
                                        geometry.size.height
                                    )
                                )
                            )

                            model.sendClick(
                                x: x,
                                y: y
                            )
                        }
                )
            }

            bottomPanel
        }
        .background(Color.black)
        .foregroundStyle(.white)
        .onAppear {
            model.startCamera()
        }
        .onDisappear {
            model.stopTransport()
            model.camera.stop()
        }
    }

    private var controlPanel: some View {
        VStack(spacing: 8) {
            HStack {
                Text("AIOBS iOS")
                    .font(.headline)

                Spacer()

                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)

                Text(model.status)
                    .font(.caption)
            }

            HStack {
                TextField(
                    "PC IP, e.g. 192.168.1.100",
                    text: $model.pcHost
                )
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                Button(
                    model.streaming ? "Stop" : "Start"
                ) {
                    if model.streaming {
                        model.stopTransport()
                    } else {
                        model.startTransport()
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            HStack {
                Text("Camera: \(model.cameraStatus)")
                Spacer()
                Text("SRT 8890")
                Text("WS 8765")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.black)
    }

    private var bottomPanel: some View {
        HStack(spacing: 12) {
            Button("Clear") {
                model.clearTarget()
            }
            .buttonStyle(.bordered)

            Spacer()

            if let target = model.target {
                Text(
                    "\(target.status) \(target.className ?? "") \(String(format: "%.2f", target.confidence))"
                )
                .font(.caption)
            } else {
                Text("Tap video to send target click")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.black)
    }

    private func targetOverlay(
        target: TargetMessage,
        size: CGSize
    ) -> some View {
        let boxWidth = target.w * size.width
        let boxHeight = target.h * size.height

        let centerX = target.cx * size.width
        let centerY = target.cy * size.height

        return ZStack {
            Rectangle()
                .stroke(Color.green, lineWidth: 3)
                .frame(
                    width: max(4, boxWidth),
                    height: max(4, boxHeight)
                )
                .position(
                    x: centerX,
                    y: centerY
                )

            Text(
                "\(target.className ?? "target") \(String(format: "%.2f", target.confidence))"
            )
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.7))
            .position(
                x: centerX,
                y: max(
                    16,
                    centerY - boxHeight / 2 - 14
                )
            )
        }
    }

    private var statusColor: Color {
        switch model.status {
        case "SRT_RUNNING", "WS_TARGET_TRACKING":
            return .green

        case "WS_CONNECTING", "STARTING":
            return .orange

        case "SRT_ERROR", "WS_RECEIVE_ERROR", "WS_SEND_ERROR":
            return .red

        default:
            return .gray
        }
    }
}

#Preview {
    ContentView()
}