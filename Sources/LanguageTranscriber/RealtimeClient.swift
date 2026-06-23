import Foundation

/// WebSocket client for OpenAI's Realtime Translation API.
///
/// Endpoint: wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate
///
/// Protocol summary (per https://developers.openai.com/api/docs/guides/realtime-translation):
///  - Client sends `session.update` with `session.audio.output.language` = target ISO code.
///  - Client streams audio chunks with `session.input_audio_buffer.append` (base64 PCM16, 24 kHz mono).
///  - Server emits delta events:
///      * `session.input_transcript.delta`   → source-language text
///      * `session.output_transcript.delta`  → translated text (target language)
///      * `session.output_audio.delta`       → translated TTS audio (we ignore — we only want text)
///  - `session.close` flushes pending output; server replies with `session.closed`.
///
/// Translation is continuous: there are no item_ids or per-turn completion events.
/// Turn boundaries are handled in the view model via a silence timer.
final class RealtimeClient: NSObject, URLSessionWebSocketDelegate {
    enum ConnectionState {
        case disconnected, connecting, connected, failed(String)
    }

    private let apiKey: String
    private let model: String
    private let targetLanguage: String

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var isReceiving = false

    var onState: ((ConnectionState) -> Void)?
    var onSourceDelta: ((String) -> Void)?      // source-language transcript delta
    var onTargetDelta: ((String) -> Void)?      // translated transcript delta (target language)
    var onError: ((String) -> Void)?
    /// Fires for EVERY incoming event with its type. For diagnostics — lets the UI surface
    /// what the server is actually emitting so we can verify our handlers match.
    var onAnyEvent: ((String) -> Void)?

    init(apiKey: String, model: String, targetLanguage: String) {
        self.apiKey = apiKey
        self.model = model
        self.targetLanguage = targetLanguage
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func connect() {
        onState?(.connecting)

        var components = URLComponents(string: "wss://api.openai.com/v1/realtime/translations")!
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        guard let url = components.url else {
            onState?(.failed("Invalid URL"))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        task = session.webSocketTask(with: request)
        task?.resume()
        startReceiving()
    }

    func disconnect() {
        if let task {
            // Politely ask the server to flush pending output before closing.
            sendJSON(["type": "session.close"], on: task)
        }
        // Give the server a brief moment to emit final deltas, then close.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.task?.cancel(with: .goingAway, reason: nil)
            self?.task = nil
            self?.isReceiving = false
            self?.onState?(.disconnected)
        }
    }

    func sendAudio(_ pcm16: Data) {
        guard let task else { return }
        let payload: [String: Any] = [
            "type": "session.input_audio_buffer.append",
            "audio": pcm16.base64EncodedString()
        ]
        sendJSON(payload, on: task)
    }

    // MARK: - Internal

    private func sendJSON(_ obj: [String: Any], on task: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return }
        task.send(.string(str)) { [weak self] error in
            if let error {
                self?.onError?("Send failed: \(error.localizedDescription)")
            }
        }
    }

    private func configureSession() {
        guard let task else { return }
        // The translation endpoint accepts only `audio.output.language` here. Adding
        // `audio.input.format` (which the transcription endpoint accepts) is rejected with
        // "Unknown parameter: 'session.audio.input.format'", which fails the whole update —
        // leaving the server with no translation target and no proper output stream.
        let payload: [String: Any] = [
            "type": "session.update",
            "session": [
                "audio": [
                    "output": [
                        "language": targetLanguage
                    ]
                ]
            ]
        ]
        sendJSON(payload, on: task)
    }

    private func startReceiving() {
        guard !isReceiving else { return }
        isReceiving = true
        receiveLoop()
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                self.receiveLoop()
            case .failure(let error):
                self.isReceiving = false
                self.onState?(.failed(error.localizedDescription))
                self.onError?("Connection error: \(error.localizedDescription)")
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        // Diagnostics: surface every received event type up to the view model.
        onAnyEvent?(type)

        switch type {
        case "session.created", "session.updated":
            if type == "session.created" {
                configureSession()
                onState?(.connected)
            }

        // Translated target-language transcript deltas.
        // (Spelling has varied across API revisions; accept the common shapes.)
        case "session.output_transcript.delta",
             "output_transcript.delta",
             "response.output_transcript.delta":
            if let delta = json["delta"] as? String, !delta.isEmpty {
                onTargetDelta?(delta)
            }

        // Source-language input transcript deltas. Several known event-name variants;
        // we accept any of them so language detection works regardless of which the
        // server happens to emit on this endpoint.
        case "session.input_transcript.delta",
             "input_transcript.delta",
             "input_audio.transcript.delta",
             "conversation.item.input_audio_transcription.delta",
             "response.input_transcript.delta":
            if let delta = json["delta"] as? String, !delta.isEmpty {
                onSourceDelta?(delta)
            }

        case "session.output_audio.delta", "output_audio.delta":
            // We don't need translated TTS audio for this app.
            break

        case "session.closed":
            onState?(.disconnected)

        case "error":
            let msg = (json["error"] as? [String: Any])?["message"] as? String
                ?? (json["message"] as? String)
                ?? "Unknown error"
            onError?(msg)

        default:
            // Last-ditch fallback: any event with a `delta: String` field and "transcript"
            // somewhere in its type that we didn't match above gets routed to source. This
            // lets new event-name spellings still feed the language detector instead of
            // being silently dropped.
            if type.contains("transcript"), type.contains("delta"),
               let delta = json["delta"] as? String, !delta.isEmpty {
                if type.contains("output") || type.contains("response") {
                    onTargetDelta?(delta)
                } else {
                    onSourceDelta?(delta)
                }
            }
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocolName: String?) {
        // Wait for `session.created` before sending session.update.
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if closeCode != .normalClosure && closeCode != .goingAway {
            onState?(.failed("WebSocket closed (code \(closeCode.rawValue)): \(reasonStr)"))
        } else {
            onState?(.disconnected)
        }
    }
}
