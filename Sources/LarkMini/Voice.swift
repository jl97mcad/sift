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
            (#"\*\*|__|~~"#, ""),                          // emphasis split across pieces
            (#"[ \t]+"#, " "),
        ]
        for (pattern, template) in rules {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let sentenceEnd = try! Regex(#"[.!?:;]["')\]]*\s|\n"#)

    /// End of the last complete sentence: what can be spoken while the agent is still writing.
    /// Never inside an open code block, whose lines must not be read out.
    static func settledLength(_ text: String) -> Int {
        var text = text[...]
        let fences = text.ranges(of: "```")
        if fences.count % 2 == 1, let open = fences.last { text = text[..<open.lowerBound] }
        // Foundation ignores .backwards for regular expressions, so take the last match.
        guard let match = text.matches(of: sentenceEnd).last else { return 0 }
        return text.distance(from: text.startIndex, to: match.range.upperBound)
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

    /// Whisper may change case and punctuation; the words must survive.
    static func sameWords(_ said: String, _ heard: String) -> Bool {
        func words(_ text: String) -> [String] {
            text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        }
        let expected = words(said), got = Set(words(heard))
        guard !expected.isEmpty else { return false }
        return Double(expected.filter(got.contains).count) / Double(expected.count) >= 0.8
    }
}

/// Talk to a seat: hold the hotkey (or tap it, talk, tap again, or use the mic button); its reply
/// is read out sentence by sentence as it arrives. Talking again cuts the voice off.
@MainActor
final class VoiceMode: ObservableObject {
    enum Phase: Equatable { case idle, listening, transcribing, waiting, speaking }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var seatId: String?

    /// Tells the agent its reply will be heard, not read.
    nonisolated static let preamble = "(Spoken through Sift voice. Reply in a few short plain sentences that read well aloud; no tables or code unless asked.)\n\n"
    private static let holdThreshold: TimeInterval = 0.4
    private static let followFor: UInt64 = 15 * 60
    /// A reply that stopped changing while the seat shows no turn is treated as finished.
    private static let quietFor: UInt64 = 4

    weak var store: Store?
    private var recorder: AVAudioRecorder?
    private var recording: URL { FileManager.default.temporaryDirectory.appendingPathComponent("sift-voice.m4a") }
    private var pressedAt: Date?

    private var following: AnyCancellable?
    private var followGeneration = 0
    private var expiry: Task<Void, Never>?
    private var quiet: Task<Void, Never>?
    private var sawRunning = false
    private var baseline = Set<String>()
    /// Per reply, how much of its raw Markdown has been spoken. Raw text only grows, so it is stable.
    private var spokenUpTo: [String: Int] = [:]
    private var lines: [String] = []
    private var speaker: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var playerDelegate: PlayerDelegate?
    private var playerDone: (() -> Void)?

    // MARK: Hotkey: hold to talk, or tap to start and tap again to send.
    // Carbon hot keys do not auto-repeat, so a press while listening is always the second tap.

    func keyDown() {
        if phase == .listening { finish(); return }
        guard let seat = store?.seat else { store?.errorText = "Add an agent seat to talk to."; return }
        start(seat)
        pressedAt = Date()
    }

    func keyUp() {
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
        guard phase != .transcribing, phase != .listening else { return }
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
        stopSpeaking()
        stopFollowing()
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
        let audio = try? Data(contentsOf: recording)
        try? FileManager.default.removeItem(at: recording)
        guard length > 0.3, let audio, let seat = store?.seats.first(where: { $0.id == seatId }),
              let key = SpeechAPI.storedKey() else {
            phase = .idle
            return
        }
        phase = .transcribing
        Task {
            do {
                let text = try await SpeechAPI(key: key).transcribe(audio, filename: "speech.m4a")
                guard phase == .transcribing else { return } // cancelled meanwhile
                guard !text.isEmpty else { phase = .idle; return }
                follow(seat)
                if await !seat.send(text: Self.preamble + text) { stopFollowing() }
            } catch {
                store?.errorText = "Voice: \(error.localizedDescription)"
                if phase == .transcribing { phase = .idle }
            }
        }
    }

    // MARK: Reading the reply

    private func follow(_ seat: SeatSession) {
        baseline = Set(seat.messages.filter(\.isAssistant).map(\.id))
        spokenUpTo = [:]
        sawRunning = false
        followGeneration += 1
        let generation = followGeneration
        phase = .waiting
        following = seat.$messages.combineLatest(seat.$status, seat.$sending).receive(on: RunLoop.main)
            .sink { [weak self] messages, status, sending in
                MainActor.assumeIsolated { self?.heard(messages, running: status == "running" || sending) }
            }
        expiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.followFor * 1_000_000_000)
            guard let self, !Task.isCancelled, self.followGeneration == generation else { return }
            self.stopFollowing()
        }
    }

    private func heard(_ messages: [AgentMessage], running: Bool, settled: Bool = false) {
        guard following != nil else { return }
        if running { sawRunning = true }
        let replies = messages.filter { $0.isAssistant && !baseline.contains($0.id) }
        // A status can lag the reply; the turn is over once it ran and stopped, or went quiet.
        let over = !running && !replies.isEmpty && (sawRunning || settled)
        for (index, reply) in replies.enumerated() {
            let raw = reply.text
            let ready = index < replies.count - 1 || over ? raw.count : Spoken.settledLength(raw)
            let done = spokenUpTo[reply.id] ?? 0
            guard ready > done else { continue }
            spokenUpTo[reply.id] = ready
            let piece = raw[raw.index(raw.startIndex, offsetBy: done)..<raw.index(raw.startIndex, offsetBy: ready)]
            say(Spoken.plain(String(piece)))
        }
        quiet?.cancel()
        if over {
            stopFollowing()
        } else if !running, !replies.isEmpty {
            let generation = followGeneration
            quiet = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.quietFor * 1_000_000_000)
                guard let self, !Task.isCancelled, self.followGeneration == generation else { return }
                self.heard(messages, running: false, settled: true)
            }
        }
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

    /// Plays one clip. Each clip resumes once: when it ends, fails, is stopped, or a little after
    /// its length if the player never reports back (an output device change).
    private func play(_ audio: Data) async {
        guard let player = try? AVAudioPlayer(data: audio) else { return }
        let delegate = PlayerDelegate()
        player.delegate = delegate
        self.player = player
        playerDelegate = delegate
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            let resume = { if !resumed { resumed = true; continuation.resume() } }
            delegate.finished = resume
            playerDone = resume
            DispatchQueue.main.asyncAfter(deadline: .now() + player.duration + 1, execute: resume)
            if !player.play() { resume() }
        }
        if self.player === player { self.player = nil; playerDelegate = nil; playerDone = nil }
    }

    func stopSpeaking() {
        lines = []
        speaker?.cancel()
        speaker = nil
        player?.stop()
        player = nil
        playerDone?()
        playerDone = nil
        playerDelegate = nil
        if phase == .speaking { phase = following == nil ? .idle : .waiting }
    }

    private func stopFollowing() {
        following = nil
        expiry?.cancel()
        quiet?.cancel()
        followGeneration += 1
        if phase == .waiting { phase = .idle }
    }

    /// Stops everything when the seat being talked to goes away.
    func cancel(seat id: String) {
        guard seatId == id else { return }
        recorder?.stop()
        recorder = nil
        try? FileManager.default.removeItem(at: recording)
        stopSpeaking()
        stopFollowing()
        phase = .idle
        seatId = nil
    }
}

/// Calls back on the main thread; AVAudioPlayer holds its delegate weakly, so VoiceMode keeps it.
private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var finished: (() -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { done() }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { done() }
    private func done() {
        let finished = finished
        DispatchQueue.main.async { finished?() }
    }
}
