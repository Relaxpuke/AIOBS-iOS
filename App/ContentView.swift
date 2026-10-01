import AVFoundation
import Combine
import SwiftUI
import UIKit

@MainActor
final class TransportViewModel: ObservableObject {
    let camera = CameraCaptureController()
    let streamer = SRTCameraStreamer()
    let ws = WsClient()

    @Published var status = "IDLE"
    @Published var streaming = false
    @Published var target: TargetMessage?
    @Published var cameraStatus = "CAMERA_IDLE"
    @Published var interfaceOrientation: UIInterfaceOrientation = .portrait
    @Published var capabilities = CameraCapabilities.empty
    @Published var cameraSettings = CameraSettings.default
    @Published var cameraState: CameraStateSnapshot?
    @Published var cameraFPS = 0.0

    @Published var pcConnected = false
    @Published var pcSourceFPS = 0.0
    @Published var pcDisplayFPS = 0.0
    @Published var pcAIFPS = 0.0
    @Published var pcAIMs = 0.0
    @Published var pcMode = "IDLE"

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
                self?.cameraState = state
                self?.cameraSettings.resolutionID = state.resolutionID
                self?.cameraSettings.width = state.width
                self?.cameraSettings.height = state.height
                self?.cameraSettings.fps = state.fps
                self?.cameraSettings.iso = state.iso
                self?.cameraSettings.exposureMode = state.exposureMode
                self?.cameraSettings.exposureDurationSeconds = state.exposureDurationSeconds
                self?.cameraSettings.exposureBiasEV = state.exposureBiasEV
                self?.cameraSettings.focusMode = state.focusMode
                self?.cameraSettings.focusPosition = state.focusPosition
                self?.cameraSettings.whiteBalanceMode = state.whiteBalanceMode
                self?.cameraSettings.whiteBalanceTemperature = state.whiteBalanceTemperature
                self?.cameraSettings.whiteBalanceTint = state.whiteBalanceTint
                self?.cameraSettings.zoomFactor = state.zoomFactor
            }
        }

        camera.onRuntimeStats = { [weak self] stats in
            Task { @MainActor in
                self?.cameraFPS = stats.fps
            }
        }

        ws.onStatus = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.status = status
                switch status {
                case "WS_CONNECTED":
                    self.pcConnected = true
                case "WS_DISCONNECTED":
                    self.pcConnected = false
                default:
                    if status.hasPrefix("WS_ERROR") ||
                        status.hasPrefix("WS_RECEIVE_ERROR") {
                        self.pcConnected = false
                    }
                }
            }
        }

        ws.onTarget = { [weak self] target in
            Task { @MainActor in
                self?.target = target
            }
        }

        ws.onTelemetry = { [weak self] telemetry in
            Task { @MainActor in
                self?.pcSourceFPS = telemetry.sourceFPS
                self?.pcDisplayFPS = telemetry.displayFPS
                self?.pcAIFPS = telemetry.aiFPS
                self?.pcAIMs = telemetry.aiMs
                self?.pcMode = telemetry.mode
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

    func startTransport(host: String, bitrateKbps: Int) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        pcHost = host

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

        let settings = cameraSettings

        Task {
            do {
                try await streamer.start(
                    host: host,
                    port: 8890,
                    settings: settings,
                    bitrateKbps: bitrateKbps,
                    interfaceOrientation: interfaceOrientation
                )

                streaming = true
                status = "SRT_RUNNING"

                ws.connect(
                    host: host,
                    port: 8765,
                    streamBitrateKbps: bitrateKbps,
                    cameraFPS: cameraFPS
                )
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
        pcConnected = false
        target = nil
        pcSourceFPS = 0
        pcDisplayFPS = 0
        pcAIFPS = 0
        pcAIMs = 0
        pcMode = "IDLE"
        status = "STOPPED"
    }

    func sendClick(x: Double, y: Double) {
        guard streaming else {
            status = "START_STREAM_FIRST"
            return
        }

        ws.sendClick(x: x, y: y)
    }

    func clearTarget() {
        ws.sendClear()
        target = nil
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

    @AppStorage("aiobs.pc.host") private var pcHost = ""
    @AppStorage("aiobs.srt.bitrate.kbps") private var streamBitrateKbps = 4000

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
                model.sendClick(x: point.x, y: point.y)
            }
            .ignoresSafeArea()

            if let target = model.target,
               target.status == "TRACKING" {
                GeometryReader { geometry in
                    targetOverlay(target: target, size: geometry.size)
                }
                .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                topHUD
                Spacer(minLength: 0)
                bottomControls
            }
            .padding(.horizontal, 7)
            .padding(.top, 4)
            .padding(.bottom, 5)
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
            CameraSettingsView(
                model: model,
                streamBitrateKbps: $streamBitrateKbps
            )
        }
        .onDisappear {
            model.stopTransport()
            model.camera.stop()
        }
    }

    private var topHUD: some View {
        VStack(spacing: 4) {
            HStack(spacing: 7) {
                Text("AIOBS")
                    .font(.system(size: 18, weight: .bold))

                Spacer(minLength: 2)

                statusPill

                Button {
                    showCameraSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .disabled(model.streaming)
                .opacity(model.streaming ? 0.45 : 1)
            }

            HStack(spacing: 8) {
                Text(cameraSummary)
                Spacer(minLength: 2)
                Text(telemetrySummary)
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.82))
            .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Color.black.opacity(0.42),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(displayStatus)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
        }
        .padding(.horizontal, 7)
        .frame(height: 26)
        .background(.black.opacity(0.34), in: Capsule())
    }

    private var bottomControls: some View {
        VStack(spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))

                TextField("PC IP", text: $pcHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .frame(height: 28)

                Text(":8765")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.52))
            }
            .padding(.horizontal, 8)
            .background(
                Color.black.opacity(0.48),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )

            HStack(spacing: 5) {
                Button {
                    if model.streaming {
                        model.stopTransport()
                    } else {
                        model.startTransport(
                            host: pcHost,
                            bitrateKbps: streamBitrateKbps
                        )
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: model.streaming ? "stop.fill" : "dot.radiowaves.left.and.right")
                        Text(model.streaming ? "STOP" : "START")
                    }
                    .font(.system(size: 11, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(
                        model.streaming ? Color.red.opacity(0.82) : Color.white.opacity(0.92),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .foregroundStyle(model.streaming ? .white : .black)
                }

                Button {
                    model.clearTarget()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .disabled(!model.streaming)
                .opacity(model.streaming ? 1 : 0.4)
            }

            if model.status.hasPrefix("WS_") && !model.status.hasPrefix("WS_TARGET") {
                Text(model.status)
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
        }
    }

    private var cameraSummary: String {
        guard let state = model.cameraState else {
            return "CAM starting…"
        }
        let actual = model.cameraFPS > 0 ? model.cameraFPS : state.fps
        return String(
            format: "%@  CAM %.1f  EXP %@  Z%.1f",
            state.resolutionText,
            actual,
            state.exposureSummary,
            state.zoomFactor
        )
    }

    private var telemetrySummary: String {
        let bitrate = streamBitrateKbps >= 1000
            ? String(format: "%.1fM", Double(streamBitrateKbps) / 1000.0)
            : "\(streamBitrateKbps)K"
        let ws = model.pcConnected ? "WS OK" : "WS --"
        let pc = model.pcSourceFPS > 0
            ? String(format: "PC %.1f/%.1f AI %.1f/%.1fms", model.pcSourceFPS, model.pcDisplayFPS, model.pcAIFPS, model.pcAIMs)
            : "PC --"
        return "SRT \(bitrate)  \(pc)  \(ws)"
    }

    private var displayStatus: String {
        switch model.status {
        case "SRT_RUNNING":
            return model.pcConnected ? "LIVE · WS" : "LIVE · WS..."
        case "WS_CONNECTED":
            return "WS OK"
        case "WS_CONNECTING", "WS_WAITING_CONNECTION":
            return "WS..."
        case "STOPPED":
            return "STOP"
        default:
            if model.status.hasPrefix("WS_ERROR") || model.status.hasPrefix("WS_RECEIVE_ERROR") {
                return "WS ERR"
            }
            return model.status
                .replacingOccurrences(of: "CAMERA_", with: "")
                .replacingOccurrences(of: "SRT_", with: "SRT ")
        }
    }

    private var statusColor: Color {
        if model.status.hasPrefix("WS_ERROR") || model.status.hasPrefix("WS_RECEIVE_ERROR") {
            return .red
        }
        if model.pcConnected || model.status == "SRT_RUNNING" {
            return .green
        }
        if model.status.hasPrefix("WS_") || model.status == "STARTING" {
            return .orange
        }
        return .white.opacity(0.5)
    }

    private func targetOverlay(target: TargetMessage, size: CGSize) -> some View {
        let boxWidth = target.w * size.width
        let boxHeight = target.h * size.height
        let centerX = target.cx * size.width
        let centerY = target.cy * size.height

        return ZStack {
            RoundedRectangle(cornerRadius: 3)
                .stroke(.green, lineWidth: 2)
                .frame(width: max(4, boxWidth), height: max(4, boxHeight))
                .position(x: centerX, y: centerY)

            Text(
                "\(target.className ?? "target") \(String(format: "%.2f", target.confidence))"
            )
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(.black.opacity(0.65), in: Capsule())
            .position(
                x: centerX,
                y: max(14, centerY - boxHeight / 2 - 12)
            )
        }
    }
}

struct CameraSettingsView: View {
    @ObservedObject var model: TransportViewModel
    @Binding var streamBitrateKbps: Int
    @Environment(\.dismiss) private var dismiss

    @State private var draft = CameraSettings.default

    var body: some View {
        NavigationView {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 9) {
                        sectionCard(title: "Video") {
                            settingRow("Resolution") {
                                Picker("Resolution", selection: $draft.resolutionID) {
                                    ForEach(model.capabilities.resolutions) { option in
                                        Text(option.title).tag(option.id)
                                    }
                                }
                                .pickerStyle(.menu)
                            }

                            Divider()

                            settingRow("Frame rate") {
                                Picker("FPS", selection: $draft.fps) {
                                    ForEach(selectedResolution?.supportedFPS ?? [], id: \.self) { fps in
                                        Text(fpsLabel(fps)).tag(fps)
                                    }
                                }
                                .pickerStyle(.menu)
                            }

                            Divider()

                            compactSlider(
                                title: "Stream bitrate",
                                valueText: bitrateLabel,
                                value: Binding(
                                    get: { Double(streamBitrateKbps) },
                                    set: { streamBitrateKbps = Int($0.rounded()) }
                                ),
                                range: 512...20_000,
                                step: 128
                            )
                        }

                        sectionCard(title: "Exposure") {
                            Picker("Exposure", selection: $draft.exposureMode) {
                                ForEach(CameraExposureMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)

                            if draft.exposureMode == .manual {
                                Divider()

                                compactSlider(
                                    title: "ISO",
                                    valueText: "\(Int(draft.iso.rounded()))",
                                    value: Binding(
                                        get: { Double(draft.iso) },
                                        set: { draft.iso = Float($0) }
                                    ),
                                    range: safeRange(
                                        lower: Double(isoRange.lowerBound),
                                        upper: Double(isoRange.upperBound),
                                        fallback: Double(isoRange.lowerBound)
                                    ),
                                    step: 1
                                )

                                Divider()

                                settingRow("Shutter") {
                                    Picker("Shutter", selection: $draft.exposureDurationSeconds) {
                                        ForEach(shutterOptions, id: \.self) { value in
                                            Text(shutterLabel(value)).tag(value)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                }
                            }

                            Divider()

                            compactSlider(
                                title: "Exposure EV",
                                valueText: String(format: "%+.1f", draft.exposureBiasEV),
                                value: Binding(
                                    get: { Double(draft.exposureBiasEV) },
                                    set: { draft.exposureBiasEV = Float($0) }
                                ),
                                range: safeRange(
                                    lower: Double(model.capabilities.minExposureBias),
                                    upper: Double(model.capabilities.maxExposureBias),
                                    fallback: 0
                                ),
                                step: 0.1
                            )
                        }

                        sectionCard(title: "Focus") {
                            Picker("Focus", selection: $draft.focusMode) {
                                ForEach(CameraFocusMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)

                            if draft.focusMode == .manual {
                                Divider()
                                compactSlider(
                                    title: "Lens",
                                    valueText: String(format: "%.2f", draft.focusPosition),
                                    value: Binding(
                                        get: { Double(draft.focusPosition) },
                                        set: { draft.focusPosition = Float($0) }
                                    ),
                                    range: 0...1,
                                    step: 0.01
                                )
                            }
                        }

                        sectionCard(title: "White Balance") {
                            Picker("White Balance", selection: $draft.whiteBalanceMode) {
                                ForEach(CameraWhiteBalanceMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)

                            if draft.whiteBalanceMode == .manual {
                                Divider()

                                compactSlider(
                                    title: "Temperature",
                                    valueText: "\(Int(draft.whiteBalanceTemperature.rounded()))K",
                                    value: Binding(
                                        get: { Double(draft.whiteBalanceTemperature) },
                                        set: { draft.whiteBalanceTemperature = Float($0) }
                                    ),
                                    range: 2000...8000,
                                    step: 100
                                )

                                Divider()

                                compactSlider(
                                    title: "Tint",
                                    valueText: String(format: "%+.0f", draft.whiteBalanceTint),
                                    value: Binding(
                                        get: { Double(draft.whiteBalanceTint) },
                                        set: { draft.whiteBalanceTint = Float($0) }
                                    ),
                                    range: -150...150,
                                    step: 1
                                )
                            }
                        }

                        sectionCard(title: "Lens") {
                            compactSlider(
                                title: "Zoom",
                                valueText: String(format: "%.1f×", draft.zoomFactor),
                                value: Binding(
                                    get: { Double(draft.zoomFactor) },
                                    set: { draft.zoomFactor = Float($0) }
                                ),
                                range: safeRange(
                                    lower: 1,
                                    upper: Double(max(1, model.capabilities.maxZoomFactor)),
                                    fallback: 1
                                ),
                                step: 0.1
                            )
                        }

                        if let state = model.cameraState {
                            Text(
                                "Current: \(state.resolutionText) · \(state.fpsText) · \(state.exposureSummary) · \(state.focusSummary) · \(state.whiteBalanceSummary) · Z\(String(format: "%.1f", state.zoomFactor))"
                            )
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(12)
                }
            }
            .navigationTitle("Camera / Stream")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        applyDraft()
                        dismiss()
                    }
                }
            }
            .onAppear {
                draft = model.cameraSettings
            }
            .onChange(of: draft.resolutionID) { newValue in
                guard let resolution = model.capabilities.resolutions.first(where: { $0.id == newValue }) else {
                    return
                }

                draft.fps = normalizedFPS(for: resolution, requested: draft.fps)
                draft.iso = min(
                    resolution.maxISO,
                    max(resolution.minISO, draft.iso)
                )
                draft.exposureDurationSeconds = clampedShutter(
                    resolution: resolution,
                    fps: draft.fps,
                    requested: draft.exposureDurationSeconds
                )
                draft.width = resolution.width
                draft.height = resolution.height
            }
            .onChange(of: draft.fps) { newFPS in
                guard let resolution = selectedResolution else { return }
                draft.exposureDurationSeconds = clampedShutter(
                    resolution: resolution,
                    fps: newFPS,
                    requested: draft.exposureDurationSeconds
                )
            }
        }
        .navigationViewStyle(.stack)
    }

    private var selectedResolution: CameraResolutionOption? {
        model.capabilities.resolutions.first { $0.id == draft.resolutionID }
    }

    private var isoRange: ClosedRange<Float> {
        selectedResolution.map { $0.minISO...$0.maxISO } ?? 25...1600
    }

    private var shutterOptions: [Double] {
        guard let resolution = selectedResolution else {
            let frameMax = 1.0 / max(1.0, draft.fps)
            return [1.0 / 1000, 1.0 / 500, 1.0 / 250, 1.0 / 125, 1.0 / 60, 1.0 / 30, 1.0 / 15, 1.0 / 8, 1.0 / 4, 1.0 / 2]
                .filter { $0 <= frameMax + 0.000_000_1 }
        }

        let raw: [Double] = [
            1.0 / 8000, 1.0 / 4000, 1.0 / 2000, 1.0 / 1000,
            1.0 / 500, 1.0 / 250, 1.0 / 240, 1.0 / 125,
            1.0 / 120, 1.0 / 100, 1.0 / 60, 1.0 / 50,
            1.0 / 30, 1.0 / 15, 1.0 / 8, 1.0 / 4,
            1.0 / 2, 1.0
        ]

        let frameMax = 1.0 / max(1.0, draft.fps)
        var values = raw.filter {
            $0 >= resolution.minExposureSeconds - 0.000_000_1 &&
            $0 <= resolution.maxExposureSeconds + 0.000_000_1 &&
            $0 <= frameMax + 0.000_000_1
        }

        if !values.contains(where: { abs($0 - draft.exposureDurationSeconds) < 0.000_001 }) {
            values.append(draft.exposureDurationSeconds)
        }

        return Array(Set(values)).sorted()
    }

    private var bitrateLabel: String {
        streamBitrateKbps >= 1000
            ? String(format: "%.1f Mbps", Double(streamBitrateKbps) / 1000.0)
            : "\(streamBitrateKbps) kbps"
    }

    private func normalizedFPS(
        for resolution: CameraResolutionOption,
        requested: Double
    ) -> Double {
        resolution.supportedFPS.min {
            abs($0 - requested) < abs($1 - requested)
        } ?? requested
    }

    private func applyDraft() {
        guard let resolution = selectedResolution else {
            return
        }

        var settings = draft
        settings.width = resolution.width
        settings.height = resolution.height
        settings.fps = normalizedFPS(
            for: resolution,
            requested: settings.fps
        )
        settings.iso = min(
            resolution.maxISO,
            max(resolution.minISO, settings.iso)
        )
        settings.exposureDurationSeconds = clampedShutter(
            resolution: resolution,
            fps: settings.fps,
            requested: settings.exposureDurationSeconds
        )
        settings.exposureBiasEV = min(
            model.capabilities.maxExposureBias,
            max(model.capabilities.minExposureBias, settings.exposureBiasEV)
        )
        settings.focusPosition = min(1, max(0, settings.focusPosition))
        settings.whiteBalanceTemperature = min(8000, max(2000, settings.whiteBalanceTemperature))
        settings.whiteBalanceTint = min(150, max(-150, settings.whiteBalanceTint))
        settings.zoomFactor = min(
            model.capabilities.maxZoomFactor,
            max(1, settings.zoomFactor)
        )

        model.applyCameraSettings(settings)
    }

    private func clampedShutter(
        resolution: CameraResolutionOption,
        fps: Double,
        requested: Double
    ) -> Double {
        let minExposure = max(1e-6, resolution.minExposureSeconds)
        let maxExposure = min(
            max(minExposure, resolution.maxExposureSeconds),
            1.0 / max(1.0, fps)
        )
        return min(maxExposure, max(minExposure, requested))
    }

    private func fpsLabel(_ fps: Double) -> String {
        abs(fps.rounded() - fps) < 0.01
            ? "\(Int(fps.rounded())) FPS"
            : String(format: "%.1f FPS", fps)
    }

    private func shutterLabel(_ seconds: Double) -> String {
        seconds >= 0.5
            ? String(format: "%.2fs", seconds)
            : "1/\(max(1, Int((1.0 / seconds).rounded())))"
    }

    private func safeRange(lower: Double, upper: Double, fallback: Double) -> ClosedRange<Double> {
        let lo = min(lower, upper)
        let hi = max(lower, upper)
        return lo == hi ? (fallback...fallback) : (lo...hi)
    }

    private func compactSlider(
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(valueText)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
            }

            Slider(value: value, in: range, step: step)
        }
    }

    private func settingRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 8)
            content()
        }
    }

    private func sectionCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)

            content()
        }
        .padding(10)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}

#Preview {
    ContentView()
}
