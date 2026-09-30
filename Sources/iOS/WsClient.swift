import Foundation

final class WsClient {

    struct TargetMessage: Codable {
        let type: String
        let status: String
        let `class`: String?
        let confidence: Float?
        let cx: Float?
        let cy: Float?
        let w: Float?
        let h: Float?
        let frameId: Int64?
        let ts: Int64?

        enum CodingKeys: String, CodingKey {
            case type
            case status
            case `class`
            case confidence
            case cx
            case cy
            case w
            case h
            case frameId = "frame_id"
            case ts
        }
    }

    private var task: URLSessionWebSocketTask?

    var onTarget: ((TargetMessage) -> Void)?
    var onStateChanged: ((Bool) -> Void)?

    func connect(url: String) {
        disconnect()

        guard let url = URL(string: url) else {
            return
        }

        let session = URLSession(
            configuration: .default
        )

        let task = session.webSocketTask(
            with: url
        )

        self.task = task

        task.resume()

        onStateChanged?(true)

        receiveNext()
    }

    func disconnect() {
        task?.cancel(
            with: .goingAway,
            reason: nil
        )

        task = nil

        onStateChanged?(false)
    }

    func sendClick(
        x: Float,
        y: Float
    ) {
        let payload: [String: Any] = [
            "type": "click",
            "x": max(0, min(1, x)),
            "y": max(0, min(1, y))
        ]

        sendJSON(payload)
    }

    func sendClear() {
        sendJSON([
            "type": "clear"
        ])
    }

    private func sendJSON(
        _ payload: [String: Any]
    ) {
        guard let task else {
            return
        }

        guard JSONSerialization.isValidJSONObject(payload) else {
            return
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: payload
        ) else {
            return
        }

        guard let string = String(
            data: data,
            encoding: .utf8
        ) else {
            return
        }

        task.send(.string(string)) { error in
            if let error {
                print("[WS] send error: \(error)")
            }
        }
    }

    private func receiveNext() {
        guard let task else {
            return
        }

        task.receive { [weak self] result in
            guard let self else {
                return
            }

            switch result {
            case .failure(let error):
                print("[WS] receive error: \(error)")
                self.onStateChanged?(false)

            case .success(let message):
                self.handle(message)
                self.receiveNext()
            }
        }
    }

    private func handle(
        _ message: URLSessionWebSocketTask.Message
    ) {
        let data: Data?

        switch message {
        case .string(let text):
            data = text.data(using: .utf8)

        case .data(let value):
            data = value

        @unknown default:
            data = nil
        }

        guard let data else {
            return
        }

        guard let target = try? JSONDecoder().decode(
            TargetMessage.self,
            from: data
        ) else {
            return
        }

        onTarget?(target)
    }
}