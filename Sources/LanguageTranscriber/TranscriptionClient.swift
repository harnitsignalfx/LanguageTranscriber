import Foundation

/// File-based diagnostic logger that bypasses macOS's unified-log redaction.
/// Writes to /tmp/language-transcriber-debug.log so we can grep it from the terminal.
private enum DebugLog {
    private static let url = URL(fileURLWithPath: "/tmp/language-transcriber-debug.log")
    private static let queue = DispatchQueue(label: "com.languagetranscriber.debuglog")
    nonisolated(unsafe) private static var didInitFile = false

    static func log(_ tag: String, _ msg: String) {
        queue.async {
            if !didInitFile {
                try? "--- LanguageTranscriber session start \(Date()) ---\n".write(to: url, atomically: false, encoding: .utf8)
                didInitFile = true
            }
            let line = "\(Date().timeIntervalSince1970) [\(tag)] \(msg)\n"
            if let data = line.data(using: .utf8),
               let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        }
    }
}

/// WebSocket client for OpenAI's Realtime Transcription endpoint.
///
/// Endpoint: wss://api.openai.com/v1/realtime?intent=transcription
///
/// Unlike `RealtimeClient` (which uses the translation endpoint), this session does *not*
/// translate — it just produces source-language transcripts via VAD-bounded utterances.
/// We use its output purely to figure out which language the speaker actually used, then
/// run the accumulated text through `NLLanguageRecognizer` in the view model.
///
/// Protocol summary:
///  - Configure via `transcription_session.update` with the transcription model and (no)
///    language hint — leaving `language` unset gives us auto-detection.
///  - Send audio as `input_audio_buffer.append` (NOTE: no `session.` prefix here, unlike
///    the translation endpoint).
///  - Receive `conversation.item.input_audio_transcription.delta` and `.completed`.
final class TranscriptionClient: NSObject, URLSessionWebSocketDelegate {
    enum ConnectionState {
        case disconnected, connecting, connected, failed(String)
    }

    private let apiKey: String
    private let model: String

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var isReceiving = false
    private var commitTimer: DispatchSourceTimer?
    private var bytesSinceLastCommit: Int = 0
    private let commitIntervalSeconds: Double = 2.0
    private let commitMinBytes: Int = 4800  // ~100 ms of 24 kHz mono PCM16; avoids committing silence

    var onState: ((ConnectionState) -> Void)?
    var onPartialTranscript: ((String) -> Void)?      // delta — partial text
    var onFinalTranscript:   ((String) -> Void)?      // completed — final text for an utterance
    var onError:             ((String) -> Void)?
    /// Fires for EVERY incoming event with its type. Lets the view model surface what the
    /// server is actually emitting so we can spot silent failures.
    var onAnyEvent:          ((String) -> Void)?

    init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func connect() {
        onState?(.connecting)
        // The session KIND is chosen by `?intent=transcription` on the URL — NOT by a model
        // param and NOT by session.type alone. A transcription session must NOT carry a
        // `model` query param (the server rejects it). The model is declared later inside
        // session.update at `audio.input.transcription.model`. With this URL, session.update
        // WITH `session.type:"transcription"` becomes legal (on the plain /v1/realtime URL it
        // is rejected as "not allowed on a realtime session"). No `OpenAI-Beta` header — that
        // beta was retired; sending it causes an immediate handshake close.
        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
        components.queryItems = [URLQueryItem(name: "intent", value: "transcription")]
        guard let url = components.url else {
            onState?(.failed("Invalid URL"))
            return
        }
        DebugLog.log("transcription", "connect → \(url.absoluteString) (transcription model: \(model))")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        task = session.webSocketTask(with: request)
        task?.resume()
        startReceiving()
        startCommitTimer()
    }

    func disconnect() {
        stopCommitTimer()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isReceiving = false
        onState?(.disconnected)
    }

    func sendAudio(_ pcm16: Data) {
        guard let task else { return }
        let payload: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": pcm16.base64EncodedString()
        ]
        sendJSON(payload, on: task)
        bytesSinceLastCommit &+= pcm16.count
    }

    // MARK: - Manual commit
    //
    // `gpt-realtime-whisper` doesn't support server-side VAD turn detection, so we drive
    // commits ourselves: every ~2 s, if we've actually sent audio, ask the server to flush
    // and emit a transcript for what's in the buffer.

    private func startCommitTimer() {
        stopCommitTimer()
        let queue = DispatchQueue(label: "com.languagetranscriber.transcription.commit")
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + commitIntervalSeconds, repeating: commitIntervalSeconds)
        t.setEventHandler { [weak self] in self?.commitIfPending() }
        t.resume()
        commitTimer = t
    }

    private func stopCommitTimer() {
        commitTimer?.cancel()
        commitTimer = nil
        bytesSinceLastCommit = 0
    }

    private func commitIfPending() {
        guard let task, bytesSinceLastCommit >= commitMinBytes else { return }
        bytesSinceLastCommit = 0
        sendJSON(["type": "input_audio_buffer.commit"], on: task)
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
        // Legal on a `?intent=transcription` socket: set session.type = "transcription",
        // declare the audio format, and put the transcription model under
        // audio.input.transcription.model. Omit `language` → auto-detect source language.
        // turn_detection: null disables server VAD so it can't auto-commit out from under
        // us; we drive commits ourselves via the commit timer (the only committer).
        let payload: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24000
                        ],
                        "transcription": [
                            "model": model
                        ],
                        "turn_detection": NSNull()
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
                let nserr = error as NSError
                let detail = "\(error.localizedDescription) (domain=\(nserr.domain) code=\(nserr.code))"
                DebugLog.log("transcription", "receive failed: \(detail)")
                self.onState?(.failed(detail))
                self.onError?("Transcription connection error: \(detail)")
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        // Surface every received event type up to the view model (drives the LID chip).
        // Only error payloads are written to the debug log — per-event logging was just
        // for protocol bring-up.
        if type == "error" {
            DebugLog.log("transcription", "ERROR payload: \(text)")
        }
        onAnyEvent?(type)

        switch type {
        case "session.created", "transcription_session.created":
            configureSession()
            onState?(.connected)

        case "transcription_session.updated", "session.updated":
            break

        case "conversation.item.input_audio_transcription.delta":
            if let delta = json["delta"] as? String, !delta.isEmpty {
                onPartialTranscript?(delta)
            }

        case "conversation.item.input_audio_transcription.completed":
            if let transcript = json["transcript"] as? String, !transcript.isEmpty {
                onFinalTranscript?(transcript)
            }

        case "error":
            let msg = (json["error"] as? [String: Any])?["message"] as? String
                ?? (json["message"] as? String)
                ?? "Unknown error"
            onError?(msg)

        case "input_audio_buffer.speech_started",
             "input_audio_buffer.speech_stopped",
             "input_audio_buffer.committed",
             "rate_limits.updated":
            break

        default:
            break
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocolName: String?) {
        // Wait for session.created before configuring.
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        DebugLog.log("transcription", "WS closed code=\(closeCode.rawValue) reason=\(reasonStr)")
        if closeCode != .normalClosure && closeCode != .goingAway {
            onState?(.failed("Transcription WS closed (code \(closeCode.rawValue)): \(reasonStr)"))
        } else {
            onState?(.disconnected)
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // Catches HTTP-level failures (401 / 403 / 404 etc.) that the WS upgrade rejected.
        if let httpResp = task.response as? HTTPURLResponse {
            DebugLog.log("transcription", "HTTP response: status=\(httpResp.statusCode) headers=\(httpResp.allHeaderFields)")
        }
        if let error {
            let nserr = error as NSError
            DebugLog.log("transcription", "didCompleteWithError: \(error.localizedDescription) (domain=\(nserr.domain) code=\(nserr.code))")
            onState?(.failed("\(error.localizedDescription) (domain=\(nserr.domain) code=\(nserr.code))"))
        }
    }
}
