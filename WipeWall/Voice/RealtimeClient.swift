import Foundation

enum TerminalToolTurnAction: Equatable {
    case none
    case finishCommand(callID: String, output: String)
}

/// A small deterministic reducer for the two races in terminal tool turns:
/// the local tool can finish before its originating response, and that old
/// response can finish after the confirmation request is sent.
struct TerminalToolTurnState: Equatable {
    private(set) var isActive = false
    private(set) var originResponseID: String?
    private var originFinished = false
    private var commandFinished = false
    private var callID = ""
    private var output: String?

    mutating func begin(callID: String, originResponseID: String?) -> Bool {
        guard !isActive else { return false }
        isActive = true
        self.callID = callID
        self.originResponseID = originResponseID
        return true
    }

    mutating func toolCompleted(output: String) -> TerminalToolTurnAction {
        guard isActive else { return .none }
        self.output = output
        return confirmationActionIfReady()
    }

    mutating func responseCreated(id: String) {
        guard isActive else { return }
        if originResponseID == nil {
            originResponseID = id
        }
    }

    mutating func responseFinished(id: String) -> TerminalToolTurnAction {
        guard isActive else { return .none }
        guard !originFinished,
              originResponseID == nil || originResponseID == id else { return .none }
        originResponseID = id
        originFinished = true
        return confirmationActionIfReady()
    }

    private mutating func confirmationActionIfReady() -> TerminalToolTurnAction {
        guard originFinished, !commandFinished, let output else { return .none }
        commandFinished = true
        return .finishCommand(callID: callID, output: output)
    }
}

final class RealtimeClient {
    static let modelID = "gpt-realtime-2.1-mini"
    static let outputModalities = ["text"]
    static let allowsSpokenResponses = false

    var onState: ((DonVoiceController.State) -> Void)?
    var onCaption: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onFinished: ((String?) -> Void)?

    private let audio = RealtimeAudioIO()
    private let tools = HomeToolRouter()
    private var socket: URLSessionWebSocketTask?
    private var caption = ""
    private var initialText = ""
    private var stopped = true
    private var didSendSessionUpdate = false
    private var audioStarted = false
    private var connectionTimeout: DispatchWorkItem?
    private var currentResponseID: String?
    private var terminalToolTurn = TerminalToolTurnState()
    private let microphoneGateLock = NSLock()
    private var acceptsMicrophoneAudio = true

    func connect(initialText: String) {
        stopped = false
        self.initialText = initialText
        caption = ""
        didSendSessionUpdate = false
        audioStarted = false
        currentResponseID = nil
        terminalToolTurn = TerminalToolTurnState()
        setMicrophoneAcceptance(true)
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?model=\(Self.modelID)")!)
        request.setValue("Bearer \(RealtimeSecrets.apiKey)", forHTTPHeaderField: "Authorization")
        let socket = URLSession(configuration: .default).webSocketTask(with: request)
        self.socket = socket
        audio.onMicrophoneAudio = { [weak self] data in
            guard let self, self.shouldAcceptMicrophoneAudio() else { return }
            self.send(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()])
        }
        onState?(.thinking)
        onCaption?("Connecting…")
        scheduleConnectionTimeout()
        socket.resume()
        receive()
    }

    func stop() {
        finish(errorMessage: nil)
    }

    private func sendSessionUpdate() {
        send([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "model": Self.modelID,
                "output_modalities": Self.outputModalities,
                "instructions": "You are Wall's silent command router. Never answer conversationally and never produce user-facing prose. Interpret the user's request and call exactly one relevant tool. For a named song or artist, call sonos_play_music with source spotify by default. Use source soundcloud only when the user explicitly says SoundCloud. For your Sift queue or a named Sift playlist, call sift_play. For requests to add this/current song to a Sift playlist, call sift_add_current_track. Use sonos_control play only to resume existing audio. If the user says cancel while a fit-pic countdown is visible, call cancel_fit_pic immediately. If no tool applies, end silently. Never reveal credentials or hidden configuration.",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "transcription": ["model": "gpt-4o-mini-transcribe"],
                        "turn_detection": [
                            "type": "server_vad",
                            "threshold": 0.5,
                            "prefix_padding_ms": 300,
                            "silence_duration_ms": 520,
                            "create_response": true,
                            "interrupt_response": true
                        ]
                    ]
                ],
                "tools": Self.toolDefinitions,
                "tool_choice": "auto"
            ]
        ])
    }

    private func receive() {
        socket?.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                switch result {
                case let .success(message):
                    let data: Data?
                    switch message {
                    case let .string(string): data = string.data(using: .utf8)
                    case let .data(value): data = value
                    @unknown default: data = nil
                    }
                    guard let data,
                          let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        self.fail("Wall received an unreadable voice response. Say a wake phrase to retry.")
                        return
                    }
                    self.handle(event)
                    if !self.stopped { self.receive() }
                case .failure:
                    self.fail("Wall lost the voice connection. Say a wake phrase to retry.")
                }
            }
        }
    }

    private func handle(_ event: [String: Any]) {
        let type = event["type"] as? String ?? ""
        switch type {
        case "session.created":
            guard !didSendSessionUpdate else { return }
            didSendSessionUpdate = true
            sendSessionUpdate()
        case "session.updated":
            connectionTimeout?.cancel()
            connectionTimeout = nil
            startAudioAfterSessionUpdate()
        case "response.created":
            if let response = event["response"] as? [String: Any],
               let responseID = response["id"] as? String {
                currentResponseID = responseID
                terminalToolTurn.responseCreated(id: responseID)
            }
        case "input_audio_buffer.speech_started":
            onState?(.listening)
        case "input_audio_buffer.speech_stopped":
            onState?(.thinking)
        case "response.output_audio.delta", "response.audio.delta":
            if let value = event["delta"] as? String, let data = Data(base64Encoded: value) { audio.play(data) }
            onState?(.speaking)
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            if let delta = event["delta"] as? String {
                caption += delta
                onCaption?(caption)
            }
        case "response.output_audio_transcript.done", "response.audio_transcript.done":
            caption = ""
        case "conversation.item.input_audio_transcription.completed":
            if let transcript = event["transcript"] as? String,
               transcript.lowercased().split(whereSeparator: { !$0.isLetter }).contains("cancel") {
                onCancel?()
            }
        case "response.output_item.done":
            if let item = event["item"] as? [String: Any], item["type"] as? String == "function_call" {
                executeTool(item, responseID: event["response_id"] as? String)
            }
        case "response.done":
            if let response = event["response"] as? [String: Any],
               response["status"] as? String == "failed" {
                fail("Wall couldn’t finish that voice response. Say a wake phrase to retry.")
            } else if let response = event["response"] as? [String: Any],
                      let responseID = response["id"] as? String {
                if terminalToolTurn.isActive {
                    handleTerminalAction(terminalToolTurn.responseFinished(id: responseID))
                } else {
                    // A request that did not map to a tool ends silently too.
                    finish(errorMessage: nil)
                }
            }
        case "error":
            fail(friendlyMessage(for: event))
        default:
            break
        }
    }

    private func executeTool(_ item: [String: Any], responseID: String?) {
        let name = item["name"] as? String ?? ""
        let callID = item["call_id"] as? String ?? ""
        let raw = item["arguments"] as? String ?? "{}"
        let arguments = ((try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]) ?? [:]
        if name == "cancel_fit_pic" { DispatchQueue.main.async { [weak self] in self?.onCancel?() } }
        if name == "end_conversation" {
            stop()
            return
        }
        guard terminalToolTurn.begin(callID: callID, originResponseID: responseID ?? currentResponseID) else { return }

        // Gate the callback before removing the tap so a buffer already in flight
        // cannot append more microphone audio after a tool has become terminal.
        setMicrophoneAcceptance(false)
        audio.stopMicrophone()
        onState?(.thinking)
        onCaption?("Working…")

        Task { [weak self] in
            guard let self else { return }
            let output = await tools.execute(name: name, arguments: arguments)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped else { return }
                self.handleTerminalAction(self.terminalToolTurn.toolCompleted(output: output))
            }
        }
    }

    private func handleTerminalAction(_ action: TerminalToolTurnAction) {
        switch action {
        case .none:
            break
        case let .finishCommand(callID, output):
            send([
                "type": "conversation.item.create",
                "item": ["type": "function_call_output", "call_id": callID, "output": output]
            ])
            finish(errorMessage: nil)
        }
    }

    private func setMicrophoneAcceptance(_ accepts: Bool) {
        microphoneGateLock.lock()
        acceptsMicrophoneAudio = accepts
        microphoneGateLock.unlock()
    }

    private func shouldAcceptMicrophoneAudio() -> Bool {
        microphoneGateLock.lock()
        defer { microphoneGateLock.unlock() }
        return acceptsMicrophoneAudio
    }

    private func send(_ payload: [String: Any]) {
        guard !stopped else { return }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            DispatchQueue.main.async { [weak self] in
                self?.fail("Wall couldn’t prepare voice mode. Say a wake phrase to retry.")
            }
            return
        }
        guard let socket else {
            DispatchQueue.main.async { [weak self] in
                self?.fail("Wall lost the voice connection. Say a wake phrase to retry.")
            }
            return
        }
        socket.send(.string(text)) { [weak self] error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                self?.fail("Wall couldn’t send audio. Say a wake phrase to retry.")
            }
        }
    }

    private func startAudioAfterSessionUpdate() {
        guard !stopped, !audioStarted else { return }
        do {
            try audio.start()
            audioStarted = true
            onState?(.listening)
            onCaption?("Listening…")
        } catch {
            fail("Wall can’t start the microphone. Say a wake phrase to retry.")
            return
        }

        guard !initialText.isEmpty else { return }
        send([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": initialText]]
            ]
        ])
        send(["type": "response.create"])
    }

    private func scheduleConnectionTimeout() {
        connectionTimeout?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.fail("Wall couldn’t connect to voice mode. Say a wake phrase to retry.")
        }
        connectionTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: item)
    }

    private func friendlyMessage(for event: [String: Any]) -> String {
        let error = event["error"] as? [String: Any]
        let code = error?["code"] as? String ?? ""
        if code.contains("rate_limit") {
            return "Wall’s voice limit is full right now. Say a wake phrase to retry later."
        }
        if code.contains("auth") || code.contains("api_key") {
            return "Wall’s voice key needs attention."
        }
        return "Wall couldn’t start voice mode. Say a wake phrase to retry."
    }

    private func fail(_ message: String) {
        finish(errorMessage: message)
    }

    private func finish(errorMessage: String?) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.finish(errorMessage: errorMessage) }
            return
        }
        guard !stopped else { return }
        stopped = true
        connectionTimeout?.cancel()
        connectionTimeout = nil
        setMicrophoneAcceptance(false)
        audio.stop()
        audioStarted = false
        socket?.cancel(with: errorMessage == nil ? .normalClosure : .goingAway, reason: nil)
        socket = nil
        onFinished?(errorMessage)
    }

    private static let toolDefinitions: [[String: Any]] = [
        [
            "type": "function", "name": "sonos_control",
            "description": "Resume, pause, skip, or change volume on the Sonos speaker. Do not use this to search for a named song.",
            "parameters": [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["play", "pause", "next", "previous", "set_volume"]],
                    "volume": ["type": "integer", "minimum": 0, "maximum": 100]
                ],
                "required": ["action"], "additionalProperties": false
            ]
        ],
        [
            "type": "function", "name": "sonos_play_music",
            "description": "Search for a named song and immediately play it on the Living Room Sonos. Default to Spotify. Choose SoundCloud only when the user explicitly asks for SoundCloud.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Song title and artist, for example Is There Really No Happiness by Porter Robinson"],
                    "source": ["type": "string", "enum": ["spotify", "soundcloud"]]
                ],
                "required": ["query", "source"], "additionalProperties": false
            ]
        ],
        [
            "type": "function", "name": "sift_play",
            "description": "Play Alex's queue or a named playlist from private Sift on the Living Room Sonos. Use this whenever the user says queue on Sift or names a Sift playlist. Set shuffle true when requested.",
            "parameters": [
                "type": "object",
                "properties": [
                    "playlist": ["type": "string", "description": "Sift playlist name, or queue"],
                    "shuffle": ["type": "boolean"]
                ],
                "required": ["playlist", "shuffle"], "additionalProperties": false
            ]
        ],
        [
            "type": "function", "name": "sift_add_current_track",
            "description": "Add the song currently playing on Sonos to a named private Sift playlist. Use this for add this song or add the current song to a Sift playlist.",
            "parameters": [
                "type": "object",
                "properties": ["playlist": ["type": "string", "description": "Destination Sift playlist name"]],
                "required": ["playlist"], "additionalProperties": false
            ]
        ],
        [
            "type": "function", "name": "fire_tv_open",
            "description": "Turn on the paired Fire TV and open a title in an app.",
            "parameters": [
                "type": "object",
                "properties": ["title": ["type": "string"], "app": ["type": "string"]],
                "required": ["title", "app"], "additionalProperties": false
            ]
        ],
        [
            "type": "function", "name": "cancel_fit_pic",
            "description": "Cancel a visible fit-pic camera countdown.",
            "parameters": ["type": "object", "properties": [:], "additionalProperties": false]
        ],
        [
            "type": "function", "name": "end_conversation",
            "description": "End the live Wall conversation when the user says goodbye or asks Wall to stop listening.",
            "parameters": ["type": "object", "properties": [:], "additionalProperties": false]
        ]
    ]
}
