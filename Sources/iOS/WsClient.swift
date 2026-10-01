import Foundation

struct TargetMessage: Codable, Sendable {
    let type: String
    let status: String
    let className: String?
    let confidence: Double
    let cx: Double
    let cy: Double
    let w: Double
    let h: Double
    let frameId: Int64
    let ts: Int64

    enum CodingKeys: String, CodingKey {
        case type
        case status
        case className = "class"
        case confidence
        case cx
        case cy
        case w
        case h
        case frameId = "frame_id"
        case ts
    }
}

struct PCTelemetryMessage: Codable, Sendable {
    let type: String
    let state: String
    let sourceFPS: Double
    let displayFPS: Double
    let aiFPS: Double
    let aiMs: Double
    let mode: String
    let frameId: Int64
    let ts: Int64

    enum CodingKeys: String, CodingKey {
        case type
        case state
        case sourceFPS = "source_fps"
        case displayFPS = "display_fps"
        case aiFPS = "ai_fps"
        case aiMs = "ai_ms"
        case mode
        case frameId = "frame_id"
        case ts
    }
}

private struct MessageEnvelope: Codable {
    let type: String
}

final class WsClient: @unchecked Sendable {
    var onTarget: ((TargetMessage) -> Void)?
    var onTelemetry: ((PCTelemetryMessage) -> Void)?
    var onStatus: ((String) -> Void)?

    private let stateQueue = DispatchQueue(label: "com.relaxpuke.aiobs.ws")

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var ready = false
    private var helloRetryCount = 0
    private var pendingJSON: String?

    private var lastFrameId: Int64 = -1
    private var nextRequestId: Int64 = 1

    func connect(
        host: String,
        port: Int,
        streamBitrateKbps: Int,
        cameraFPS: Double
    ) {
        stateQueue.async { [weak self] in
            guard let self else { return }

            self.disconnectLocked(notify: false)

            guard let url = URL(string: "ws://\(host):\(port)") else {
                self.notify("WS_INVALID_URL")
                return
            }

            let session = URLSession(configuration: .default)
            let task = session.webSocketTask(with: url)

            self.session = session
            self.task = task
            self.ready = false
            self.helloRetryCount = 0
            self.pendingJSON = nil
            self.lastFrameId = -1
            self.nextRequestId = 1

            self.notify("WS_CONNECTING")

            task.resume()
            self.sendHelloLocked(
                task: task,
                streamBitrateKbps: streamBitrateKbps,
                cameraFPS: cameraFPS
            )
            self.receiveLoop(task: task)
        }
    }

    func disconnect() {
        stateQueue.async { [weak self] in
            self?.disconnectLocked(notify: true)
        }
    }

    func sendClick(x: Double, y: Double) {
        let clampedX = max(0.0, min(1.0, x))
        let clampedY = max(0.0, min(1.0, y))

        stateQueue.async { [weak self] in
            guard let self else { return }

            let requestId = self.nextRequestId
            self.nextRequestId += 1

            let json = self.makeJSON([
                "type": "click",
                "x": clampedX,
                "y": clampedY,
                "request_id": requestId,
                "client_ts": Int(Date().timeIntervalSince1970 * 1000)
            ])

            guard let json else {
                self.notify("WS_ENCODE_ERROR")
                return
            }

            if self.ready {
                self.sendJSONLocked(json, commandName: "CLICK")
            } else {
                self.pendingJSON = json
                self.notify("WS_WAITING_CONNECTION")
            }
        }
    }

    func sendClear() {
        stateQueue.async { [weak self] in
            guard let self else { return }

            let json = self.makeJSON([
                "type": "clear"
            ])

            guard let json else {
                self.notify("WS_ENCODE_ERROR")
                return
            }

            if self.ready {
                self.sendJSONLocked(json, commandName: "CLEAR")
            } else {
                self.pendingJSON = json
                self.notify("WS_WAITING_CONNECTION")
            }
        }
    }

    private func disconnectLocked(notify shouldNotify: Bool) {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        ready = false
        pendingJSON = nil
        helloRetryCount = 0

        if shouldNotify {
            notify("WS_DISCONNECTED")
        }
    }

    private func sendHelloLocked(
        task: URLSessionWebSocketTask,
        streamBitrateKbps: Int,
        cameraFPS: Double
    ) {
        let payload: [String: Any] = [
            "type": "hello",
            "role": "ios",
            "protocol": 1,
            "coordinate_space": "normalized_0_1",
            "stream_bitrate_kbps": streamBitrateKbps,
            "camera_fps": cameraFPS
        ]

        guard let text = makeJSON(payload) else {
            notify("WS_ENCODE_ERROR")
            return
        }

        task.send(.string(text)) { [weak self] error in
            guard let self else { return }

            if let error {
                self.stateQueue.async {
                    guard self.task === task else { return }
                    self.helloRetryCount += 1
                    let attempt = self.helloRetryCount

                    if attempt <= 10 {
                        self.notify(
                            "WS_HELLO_RETRY_\(attempt): \(self.errorText(error))"
                        )
                        self.stateQueue.asyncAfter(deadline: .now() + 0.3) {
                            guard self.task === task, !self.ready else { return }
                            self.sendHelloLocked(
                                task: task,
                                streamBitrateKbps: streamBitrateKbps,
                                cameraFPS: cameraFPS
                            )
                        }
                    } else {
                        self.notify(
                            "WS_ERROR: \(self.errorText(error))"
                        )
                    }
                }
            }
        }
    }

    private func sendJSONLocked(_ text: String, commandName: String) {
        guard let task else {
            pendingJSON = text
            notify("WS_NOT_CONNECTED")
            return
        }

        task.send(.string(text)) { [weak self] error in
            guard let self else { return }

            if let error {
                self.stateQueue.async {
                    if self.task === task {
                        self.ready = false
                        self.pendingJSON = text
                        self.notify(
                            "WS_SEND_ERROR: \(self.errorText(error))"
                        )
                    }
                }
                return
            }

            self.notify("WS_\(commandName)_SENT")
        }
    }

    private func flushPendingLocked() {
        guard ready, let pending = pendingJSON else {
            return
        }
        pendingJSON = nil
        sendJSONLocked(pending, commandName: "PENDING")
    }

    private func receiveLoop(task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }

            self.stateQueue.async {
                guard self.task === task else { return }

                switch result {
                case .success(let message):
                    self.handleLocked(message)
                    self.receiveLoop(task: task)

                case .failure(let error):
                    self.ready = false
                    self.notify(
                        "WS_RECEIVE_ERROR: \(self.errorText(error))"
                    )
                }
            }
        }
    }

    private func handleLocked(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?

        switch message {
        case .string(let text):
            data = text.data(using: .utf8)
        case .data(let receivedData):
            data = receivedData
        @unknown default:
            data = nil
        }

        guard let data,
              let envelope = try? JSONDecoder().decode(
                  MessageEnvelope.self,
                  from: data
              ) else {
            notify("WS_DECODE_ERROR")
            return
        }

        switch envelope.type {
        case "hello_ack":
            ready = true
            helloRetryCount = 0
            notify("WS_CONNECTED")
            flushPendingLocked()

        case "click_ack":
            if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let accepted = payload["accepted"] as? Bool {
                notify(accepted ? "WS_CLICK_ACK" : "WS_CLICK_REJECTED")
            }

        case "target":
            guard let target = try? JSONDecoder().decode(
                TargetMessage.self,
                from: data
            ) else {
                notify("WS_TARGET_DECODE_ERROR")
                return
            }

            guard target.frameId > lastFrameId else {
                return
            }

            lastFrameId = target.frameId

            DispatchQueue.main.async { [weak self] in
                self?.onTarget?(target)
            }

            notify("WS_TARGET_\(target.status)")

        case "telemetry":
            guard let telemetry = try? JSONDecoder().decode(
                PCTelemetryMessage.self,
                from: data
            ) else {
                notify("WS_TELEMETRY_DECODE_ERROR")
                return
            }

            DispatchQueue.main.async { [weak self] in
                self?.onTelemetry?(telemetry)
            }

        default:
            break
        }
    }

    private func makeJSON(_ object: [String: Any]) -> String? {
        guard
            JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: []
            ),
            let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return text
    }

    private func errorText(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain)/\(ns.code) \(ns.localizedDescription)"
    }

    private func notify(_ status: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?(status)
        }
    }
}
