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

final class WsClient: @unchecked Sendable {
    var onTarget: ((TargetMessage) -> Void)?
    var onStatus: ((String) -> Void)?

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?

    private var lastFrameId: Int64 = -1

    func connect(host: String, port: Int) {
        disconnect()

        guard let url = URL(string: "ws://\(host):\(port)") else {
            notify("WS_INVALID_URL")
            return
        }

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)

        self.session = session
        self.task = task
        self.lastFrameId = -1

        notify("WS_CONNECTING")

        task.resume()

        receiveLoop(task: task)
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil

        session?.invalidateAndCancel()
        session = nil

        notify("WS_DISCONNECTED")
    }

    func sendClick(x: Double, y: Double) {
        sendJSON([
            "type": "click",
            "x": max(0.0, min(1.0, x)),
            "y": max(0.0, min(1.0, y))
        ])
    }

    func sendClear() {
        sendJSON([
            "type": "clear"
        ])
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let task else {
            notify("WS_NOT_CONNECTED")
            return
        }

        guard
            JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object),
            let text = String(data: data, encoding: .utf8)
        else {
            notify("WS_ENCODE_ERROR")
            return
        }

        task.send(.string(text)) { [weak self] error in
            if let error {
                self?.notify("WS_SEND_ERROR: \(error.localizedDescription)")
            }
        }
    }

    private func receiveLoop(task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                self.handle(message)

                if self.task === task {
                    self.receiveLoop(task: task)
                }

            case .failure(let error):
                if self.task === task {
                    self.notify("WS_RECEIVE_ERROR: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?

        switch message {
        case .string(let text):
            data = text.data(using: .utf8)

        case .data(let receivedData):
            data = receivedData

        @unknown default:
            data = nil
        }

        guard let data else {
            return
        }

        do {
            let target = try JSONDecoder().decode(
                TargetMessage.self,
                from: data
            )

            guard target.type == "target" else {
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
        } catch {
            notify("WS_DECODE_ERROR")
        }
    }

    private func notify(_ status: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?(status)
        }
    }
}