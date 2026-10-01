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
    @Published var interfaceOrientation: UIInterfaceOrientation = .portrait
    @Published var capabilities = CameraCapabilities.empty
    @Published var cameraSettings = CameraSettings.default
    @Published var cameraState: CameraStateSnapshot?

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

        camera.onCapabilities = { [weak self] capabilities in
            Task { @MainActor in
                self?.capabilities = capabilities
            }
        }

        camera.onCameraState = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.cameraState = state
                self.cameraSettings.resolutionID = state.resolutionID
                self.cameraSettings.width = state.width
                self.cameraSettings.height = state.height
                self.cameraSettings.fps = state.fps
                self.cameraSettings.iso = state.iso
                self.cameraSettings.exposureMode = state.exposureMode
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

    func updateInterfaceOrientation(_ orientation: UIInterfaceOrientation) {
        guard orientation != .unknown,
              orientation != .faceUp,
              orientation != .faceDown
        else {
            return
        }

        interfaceOrientation = orientation
        camera.setInterfaceOrientation(orientation)
    }

    func applyCameraSettings(_ settings: CameraSettings) {
        guard !streaming else {
            status = "STOP_STREAM_FIRST"
            return
        }

        cameraSettings = settings
        camera.apply(settings: settings)
    }

    func startTransport() {
        let host = pcHost.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !host.isEmpty else {
            status = "ENTER_PC_IP"
            return
        }

        guard cameraState != nil else {
            status = "CAMERA_NOT_READY"
            return
        }

        target = nil
        status = "STARTING"

        ws.connect(host: host, port: 8765)

        let settings = cameraSettings

        Task {
            do {
                try await streamer.start(
                    host: host,
                    port: 8890,
                    settings: settings,
                    interfaceOrientation: interfaceOrientation
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
            status = "START_STREAM_FIRST"
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

    func syncInitialOrientation(_ orientation: UIInterfaceOrientation) {
        if interfaceOrientation == .portrait {
            updateInterfaceOrientation(orientation)
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let interfaceOrientation: UIInterfaceOrientation
    let onTapNormalized: (CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()

        view.onTapNormalized = onTapNormalized
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.setInterfaceOrientation(interfaceOrientation)

        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.onTapNormalized = onTapNormalized

        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }

        uiView.previewLayer.videoGravity = .resizeAspectFill
        uiView.setInterfaceOrientation(interfaceOrientation)
    }
}

final class PreviewView: UIView {
    var onTapNormalized: ((CGPoint) -> Void)?

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            fatalError("Expected AVCaptureVideoPreviewLayer")
        }
        return layer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureGesture()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureGesture()
    }

    private func configureGesture() {
        isUserInteractionEnabled = true
        let tapGesture = UITapGestureRecognizer(
            target: self,
            action: #selector(handleTap(_:))
        )
        addGestureRecognizer(tapGesture)
    }

    func setInterfaceOrientation(_ orientation: UIInterfaceOrientation) {
        guard
            let connection = previewLayer.connection,
            connection.isVideoOrientationSupported
        else {
            return
        }

        connection.videoOrientation = orientation.aiobsVideoOrientation
    }

    @objc
    private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }

        let point = gesture.location(in: self)
        let conversionRect = CGRect(
            x: point.x,
            y: point.y,
            width: 1,
            height: 1
        )

        let metadataRect = previewLayer.metadataOutputRectConverted(
            fromLayerRect: conversionRect
        )

        let x = min(1.0, max(0.0, metadataRect.midX))
        let y = min(1.0, max(0.0, metadataRect.midY))

        onTapNormalized?(CGPoint(x: x, y: y))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }
}

struct ContentView: View {
    @StateObject private var model = TransportViewModel()
    @State private var showCameraSettings = false

    private var currentInterfaceOrientation: UIInterfaceOrientation {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: {
                $0.activationState == .foregroundActive
            })?
            .interfaceOrientation ?? .portrait
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            CameraPreview(
                session: model.camera.session,
                interfaceOrientation: model.interfaceOrientation
            ) { point in
                model.sendClick(
                    x: point.x,
                    y: point.y
                )
            }
            .ignoresSafeArea()

            if let target = model.target,
               target.status == "TRACKING" {
                GeometryReader { geometry in
                    targetOverlay(
                        target: target,
                        size: geometry.size
                    )
                }
                .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                topBar

                Spacer(minLength: 0)

                if model.cameraStatus != "CAMERA_READY" {
                    statusHint
                }

                bottomBar
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .foregroundStyle(.white)
        .onAppear {
            model.updateInterfaceOrientation(currentInterfaceOrientation)
            model.startCamera()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIDevice.orientationDidChangeNotification
            )
        ) { _ in
            let orientation = currentInterfaceOrientation

            guard orientation != .unknown else { return }
            model.updateInterfaceOrientation(orientation)
        }
        .sheet(isPresented: $showCameraSettings) {
            CameraSettingsView(model: model)
        }
        .onDisappear {
            model.stopTransport()
            model.camera.stop()
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AIOBS")
                    .font(.system(size: 20, weight: .bold))

                Text(cameraSummary)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
            }

            Spacer(minLength: 8)

            statusPill

            Button {
                showCameraSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .disabled(model.streaming)
            .opacity(model.streaming ? 0.45 : 1.0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            Text(displayStatus)
                .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(.black.opacity(0.34), in: Capsule())
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))

                TextField("PC IP", text: $model.pcHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 15, weight: .medium, design: .monospaced))

                Text(":8765")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 10) {
                Button {
                    if model.streaming {
                        model.stopTransport()
                    } else {
                        model.startTransport()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: model.streaming ? "stop.fill" : "dot.radiowaves.left.and.right")
                        Text(model.streaming ? "Stop Streaming" : "Start Streaming")
                    }
                    .font(.system(size: 15, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(
                        model.streaming ? Color.red.opacity(0.82) : Color.white,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .foregroundStyle(model.streaming ? .white : .black)
                }

                Button {
                    model.clearTarget()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 48, height: 48)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(!model.streaming)
                .opacity(model.streaming ? 1 : 0.4)
            }

            if !model.streaming {
                Text("Tap the camera view to send a target click")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
        .padding(12)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }

    private var statusHint: some View {
        Text(model.cameraStatus)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(.bottom, 8)
    }

    private var cameraSummary: String {
        guard let state = model.cameraState else {
            return "Camera starting…"
        }
        return "\(state.resolutionText) · \(state.fpsText) · \(state.isoText)"
    }

    private var displayStatus: String {
        switch model.status {
        case "SRT_RUNNING":
            return "LIVE"
        case "WS_CONNECTING":
            return "CONNECTING"
        case "STOPPED":
            return "STOPPED"
        case "CAMERA_NOT_READY":
            return "CAMERA"
        default:
            return model.status.replacingOccurrences(of: "CAMERA_", with: "")
        }
    }

    private var statusColor: Color {
        switch model.status {
        case "SRT_RUNNING", "WS_TARGET_TRACKING", "WS_CLICK_SENT":
            return .green
        case "WS_CONNECTING", "STARTING", "CAMERA_IDLE":
            return .orange
        case let value where value.hasPrefix("SRT_ERROR") || value.hasPrefix("WS_ERROR"):
            return .red
        default:
            return .white.opacity(0.45)
        }
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
            RoundedRectangle(cornerRadius: 3)
                .stroke(.green, lineWidth: 3)
                .frame(
                    width: max(4, boxWidth),
                    height: max(4, boxHeight)
                )
                .position(x: centerX, y: centerY)

            Text(
                "\(target.className ?? "target")  \(String(format: "%.2f", target.confidence))"
            )
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.black.opacity(0.7), in: Capsule())
            .position(
                x: centerX,
                y: max(18, centerY - boxHeight / 2 - 16)
            )
        }
    }
}

struct CameraSettingsView: View {
    @ObservedObject var model: TransportViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var draft = CameraSettings.default

    var body: some View {
        NavigationView {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        sectionCard(title: "Video") {
                            settingRow("Resolution") {
                                Picker(
                                    "Resolution",
                                    selection: $draft.resolutionID
                                ) {
                                    ForEach(model.capabilities.resolutions) { option in
                                        Text(option.title)
                                            .tag(option.id)
                                    }
                                }
                                .pickerStyle(.menu)
                            }

                            Divider()

                            settingRow("Frame rate") {
                                Picker(
                                    "FPS",
                                    selection: $draft.fps
                                ) {
                                    ForEach(selectedResolution?.supportedFPS ?? [], id: \.self) { fps in
                                        Text(fpsLabel(fps))
                                            .tag(fps)
                                    }
                                }
                                .pickerStyle(.menu)
                            }
                        }

                        sectionCard(title: "Exposure") {
                            Picker(
                                "Exposure",
                                selection: $draft.exposureMode
                            ) {
                                ForEach(CameraExposureMode.allCases) { mode in
                                    Text(mode.title)
                                        .tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)

                            if draft.exposureMode == .manualISO {
                                Divider()

                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("ISO")
                                            .font(.system(size: 14, weight: .semibold))
                                        Spacer()
                                        Text("\(Int(draft.iso.rounded()))")
                                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    }

                                    Slider(
                                        value: Binding(
                                            get: { Double(draft.iso) },
                                            set: { draft.iso = Float($0) }
                                        ),
                                        in: Double(isoRange.lowerBound)...Double(isoRange.upperBound),
                                        step: 1
                                    )

                                    HStack {
                                        Text("\(Int(isoRange.lowerBound.rounded()))")
                                        Spacer()
                                        Text("\(Int(isoRange.upperBound.rounded()))")
                                    }
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                }
                            }

                            if let state = model.cameraState {
                                Divider()

                                HStack {
                                    Text("Current")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(state.isoText)")
                                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                }
                            }
                        }

                        Text("All options above come from the rear camera formats currently exposed by AVFoundation. Stop streaming before changing capture settings.")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Camera Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        var settings = draft
                        if let resolution = selectedResolution {
                            settings.width = resolution.width
                            settings.height = resolution.height
                            settings.fps = normalizedFPS(for: resolution, requested: settings.fps)
                            settings.iso = min(
                                resolution.maxISO,
                                max(resolution.minISO, settings.iso)
                            )
                        }

                        model.applyCameraSettings(settings)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                draft = model.cameraSettings
            }
            .onChange(of: draft.resolutionID) { newValue in
                guard let resolution = model.capabilities.resolutions.first(where: { $0.id == newValue }) else {
                    return
                }

                draft.fps = normalizedFPS(
                    for: resolution,
                    requested: draft.fps
                )
                draft.iso = min(
                    resolution.maxISO,
                    max(resolution.minISO, draft.iso)
                )
                draft.width = resolution.width
                draft.height = resolution.height
            }
        }
        .navigationViewStyle(.stack)
    }

    private var selectedResolution: CameraResolutionOption? {
        model.capabilities.resolutions.first {
            $0.id == draft.resolutionID
        }
    }

    private var isoRange: ClosedRange<Float> {
        guard let resolution = selectedResolution else {
            return 25...1600
        }
        return resolution.minISO...resolution.maxISO
    }

    private func normalizedFPS(
        for resolution: CameraResolutionOption,
        requested: Double
    ) -> Double {
        resolution.supportedFPS.min {
            abs($0 - requested) < abs($1 - requested)
        } ?? requested
    }

    private func fpsLabel(_ fps: Double) -> String {
        if abs(fps.rounded() - fps) < 0.01 {
            return "\(Int(fps.rounded())) FPS"
        }
        return String(format: "%.1f FPS", fps)
    }

    private func settingRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .semibold))

            Spacer(minLength: 12)

            content()
        }
    }

    private func sectionCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)

            content()
        }
        .padding(16)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }
}

#Preview {
    ContentView()
}
