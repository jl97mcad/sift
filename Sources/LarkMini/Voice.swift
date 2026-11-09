import AppKit
import AVFoundation
import Combine
import Foundation

/// OpenRouter speech (ADR 0012): Whisper turbo hears you, Fish Audio Drama 3 speaks back.
struct SpeechAPI {
    static let transcriptionModel = "openai/whisper-large-v3-turbo"
    static let speechModel = "fish-audio/drama-3"
    static let voice = "alloy"
    private static let base = URL(string: "https://openrouter.ai/api/v1")!

    static var keyFile: URL { AppPaths.supportDirectory.appendingPathComponent("openrouter-key") }

    static func storedKey() -> String? {
        guard let text = try? String(contentsOf: keyFile, encoding: .utf8) else { return nil }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    static func saveKey(_ key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw SpeechError("The OpenRouter key is empty.") }
        try Data(key.utf8).write(to: keyFile, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
    }

    let key: String

    func transcribe(_ audio: Data, filename: String) async throws -> String {
        let boundary = "sift-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", Self.transcriptionModel)
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = request("audio/transcriptions", contentType: "multipart/form-data; boundary=\(boundary)")
        request.httpBody = body
        let data = try await Self.send(request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else { throw SpeechError("OpenRouter sent no transcript.") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// MP3 audio of the text.
    func speak(_ text: String) async throws -> Data {
        var request = request("audio/speech", contentType: "application/json")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": Self.speechModel, "input": text, "voice": Self.voice, "response_format": "mp3",
        ])
        return try await Self.send(request)
    }

    private func request(_ path: String, contentType: String) -> URLRequest {
        var request = URLRequest(url: Self.base.appendingPathComponent(path), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("Sift", forHTTPHeaderField: "X-Title")
        return request
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? "HTTP \(code)"
            throw SpeechError("OpenRouter: \(detail)")
        }
        return data
    }
}

struct SpeechError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Turns an agent's Markdown into text that reads well aloud, in sentence-sized pieces.
enum Spoken {
    static func plain(_ markdown: String) -> String {
        var text = markdown
        let rules: [(String, String)] = [
            (#"```[\s\S]*?(```|$)"#, " "),                 // code blocks are not read out
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),             // [label](url) -> label
            (#"https?://\S+"#, "a link"),
            (#"`([^`]*)`"#, "$1"),
            (#"(?m)^\s{0,3}(#{1,6}|>|[-*+]|\d+[.)])\s+"#, ""), // headings, quotes, list markers
            (#"(?m)^\s*\|?[-:| ]+\|[-:| ]*$"#, ""),         // table rules
            (#"\|"#, ", "),
            (#"(\*\*|__|\*|_|~~)(?=\S)(.+?)(?<=\S)\1"#, "$2"),
            (#"[ \t]+"#, " "),
        ]
        for (pattern, template) in rules {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// End of the last complete sentence: what can be spoken while the agent is still writing.
    static func settledLength(_ text: String) -> Int {
        guard let match = text.range(of: #"[.!?:;]["')\]]*\s|\n"#, options: [.regularExpression, .backwards]) else { return 0 }
        return text.distance(from: text.startIndex, to: match.upperBound)
    }

    /// Sentences, joined up to a comfortable length so short ones share one request.
    static func pieces(_ text: String, limit: Int = 280) -> [String] {
        var pieces: [String] = []
        var current = ""
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            guard let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty else { return }
            // The first piece goes alone so the voice starts as soon as possible.
            if !current.isEmpty, pieces.isEmpty || current.count + sentence.count + 1 > limit {
                pieces.append(current)
                current = sentence
            } else {
                current = current.isEmpty ? sentence : current + " " + sentence
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}

/// Talk to a seat: hold the hotkey (or tap it twice, or the mic button) to speak; its reply is read
/// out sentence by sentence as it arrives. Speaking again cuts the voice off.
@MainActor
final class VoiceMode: ObservableObject {
    enum Phase: Equatable { case idle, listening, transcribing, waiting, speaking }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var seatId: String?

    /// Tells the agent its reply will be heard, not read.
    nonisolated static let preamble = "(Spoken through Sift voice. Reply in a few short plain sentences that read well aloud; no tables or code unless asked.)\n\n"
    private static let holdThreshold: TimeInterval = 0.4
    private static let followFor: TimeInterval = 15 * 60

    weak var store: Store?
    private var recorder: AVAudioRecorder?
    private var recording: URL { FileManager.default.temporaryDirectory.appendingPathComponent("sift-voice.m4a") }
    private var pressedAt: Date?
    private var keyHeld = false

    private var following: AnyCancellable?
    private var followUntil = Date.distantPast
    private var baseline = Set<String>()
    private var spokenUpTo: [String: Int] = [:]
    private var lines: [String] = []
    private var speaker: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var playerDone: (() -> Void)?
    private let playerDelegate = PlayerDelegate()

    // MARK: Hotkey: hold to talk, or a quick tap to start and another to send.

    func keyDown() {
        guard !keyHeld else { return }
        keyHeld = true
        if phase == .listening { finish(); return }
        guard let seat = store?.seat else { store?.errorText = "Add an agent seat to talk to."; return }
        start(seat)
        pressedAt = Date()
    }

    func keyUp() {
        keyHeld = false
        if phase == .listening, let pressedAt, Date().timeIntervalSince(pressedAt) > Self.holdThreshold { finish() }
        pressedAt = nil
    }

    /// The mic button: start, send, or stop the voice.
    func toggle(_ seat: SeatSession) {
        switch phase {
        case .listening: finish()
        case .speaking: stopSpeaking()
        default: start(seat)
        }
    }

    func start(_ seat: SeatSession) {
        stopSpeaking()
        stopFollowing()
        guard SpeechAPI.storedKey() != nil else {
            store?.errorText = "Voice needs an OpenRouter key: sift voice key - (key on stdin)."
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return
        default:
            store?.errorText = "Sift can't use the microphone. Allow it in System Settings → Privacy & Security → Microphone."
            return
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        do {
            let recorder = try AVAudioRecorder(url: recording, settings: settings)
            guard recorder.record() else { throw SpeechError("The microphone did not start.") }
            self.recorder = recorder
            seatId = seat.id
            phase = .listening
            NSSound(named: "Tink")?.play()
        } catch {
            store?.errorText = error.localizedDescription
        }
    }

    func finish() {
        guard let recorder, phase == .listening else { return }
        let length = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        NSSound(named: "Pop")?.play()
        guard length > 0.3, let seat = store?.seats.first(where: { $0.id == seatId }),
              let key = SpeechAPI.storedKey(), let audio = try? Data(contentsOf: recording) else {
            phase = .idle
            return
        }
        phase = .transcribing
        Task {
            do {
                let text = try await SpeechAPI(key: key).transcribe(audio, filename: "speech.m4a")
                guard phase == .transcribing else { return }
                guard !text.isEmpty else { phase = .idle; return }
                follow(seat)
                if await !seat.send(text: Self.preamble + text) { stopFollowing() }
            } catch {
                store?.errorText = "Voice: \(error.localizedDescription)"
                phase = .idle
            }
        }
    }

    // MARK: Reading the reply

    private func follow(_ seat: SeatSession) {
        baseline = Set(seat.messages.filter(\.isAssistant).map(\.id))
        spokenUpTo = [:]
        followUntil = Date().addingTimeInterval(Self.followFor)
        phase = .waiting
        following = seat.$messages.combineLatest(seat.$status, seat.$sending).receive(on: RunLoop.main)
            .sink { [weak self] messages, status, sending in
                MainActor.assumeIsolated { self?.heard(messages, running: status == "running" || sending) }
            }
    }

    private func heard(_ messages: [AgentMessage], running: Bool) {
        guard Date() < followUntil else { stopFollowing(); return }
        let replies = messages.filter { $0.isAssistant && !baseline.contains($0.id) }
        for (index, reply) in replies.enumerated() {
            let text = Spoken.plain(reply.text)
            let finished = index < replies.count - 1 || !running
            let ready = finished ? text.count : Spoken.settledLength(text)
            let done = spokenUpTo[reply.id] ?? 0
            guard ready > done else { continue }
            spokenUpTo[reply.id] = ready
            let start = text.index(text.startIndex, offsetBy: done)
            let end = text.index(text.startIndex, offsetBy: ready)
            say(String(text[start..<end]))
        }
        // The turn is over once a reply exists and the agent stopped; what is queued still plays.
        if !running, !replies.isEmpty { stopFollowing() }
    }

    private func say(_ text: String) {
        lines += Spoken.pieces(text)
        guard speaker == nil, !lines.isEmpty, let key = SpeechAPI.storedKey() else { return }
        let api = SpeechAPI(key: key)
        speaker = Task { [weak self] in
            var next: Task<Data, Error>?
            while let self = self, !Task.isCancelled {
                let current: Task<Data, Error>
                if let next { current = next } else if !self.lines.isEmpty {
                    let line = self.lines.removeFirst()
                    current = Task { try await api.speak(line) }
                } else { break }
                // Fetch the next piece while this one plays.
                next = self.lines.isEmpty ? nil : { let line = self.lines.removeFirst(); return Task { try await api.speak(line) } }()
                do {
                    let audio = try await current.value
                    guard !Task.isCancelled else { break }
                    self.phase = .speaking
                    await self.play(audio)
                } catch {
                    self.store?.errorText = "Voice: \(error.localizedDescription)"
                }
            }
            guard let self = self, !Task.isCancelled else { return }
            self.speaker = nil
            if self.phase == .speaking { self.phase = self.following == nil ? .idle : .waiting }
        }
    }

    private func play(_ audio: Data) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            guard let player = try? AVAudioPlayer(data: audio) else { done.resume(); return }
            var resumed = false
            let finish = { if !resumed { resumed = true; done.resume() } }
            playerDone = finish
            playerDelegate.finished = { [weak self] in MainActor.assumeIsolated { self?.playerDone?(); self?.playerDone = nil } }
            player.delegate = playerDelegate
            self.player = player
            if !player.play() { finish() }
        }
        player = nil
    }

    func stopSpeaking() {
        lines = []
        speaker?.cancel()
        speaker = nil
        player?.stop()
        player = nil
        playerDone?()
        playerDone = nil
        if phase == .speaking { phase = following == nil ? .idle : .waiting }
    }

    private func stopFollowing() {
        following = nil
        if phase == .waiting { phase = .idle }
    }

    /// Stops everything, e.g. when the seat goes away.
    func cancel() {
        recorder?.stop()
        recorder = nil
        stopSpeaking()
        stopFollowing()
        phase = .idle
    }
}

private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var finished: (() -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = finished
        DispatchQueue.main.async { finished?() }
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let finished = finished
        DispatchQueue.main.async { finished?() }
    }
}
