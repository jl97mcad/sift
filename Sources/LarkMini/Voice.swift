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

/// The live loudness, 0...1, of whoever is talking: you while listening, the agent while speaking.
/// Its own object so twenty updates a second redraw only the views that draw it.
@MainActor
final class VoiceMeter: ObservableObject {
    @Published var level: CGFloat = 0
}

/// Talk to a seat. Hold the hotkey to talk (push-to-talk), or tap it, talk and tap again.
/// Double-tap it, or use the mic button, for a conversation: Sift notices when you stop talking,
/// sends, reads the reply aloud and listens again. Tapping while it speaks cuts it off.
@MainActor
final class VoiceMode: ObservableObject {
    enum Phase: Equatable { case idle, listening, transcribing, waiting, speaking, paused }

    @Published private(set) var phase = Phase.idle {
        didSet { phase == .listening || phase == .speaking ? startMeter() : stopMeter() }
    }
    @Published private(set) var seatId: String?
    @Published private(set) var conversation = false
    let meter = VoiceMeter()

    /// Tells the agent its reply will be heard, not read.
    nonisolated static let preamble = "(Spoken through Sift voice. Reply in a few short plain sentences that read well aloud; no tables or code unless asked.)\n\n"
    private static let holdThreshold: TimeInterval = 0.4
    private static let doubleTap: TimeInterval = 0.35
    private static let longestTurn: TimeInterval = 120
    private static let followFor: UInt64 = 15 * 60
    /// A reply that stopped changing while the seat shows no turn is treated as finished.
    private static let quietFor: UInt64 = 4
    // ponytail: fixed loudness thresholds in dBFS; tune here if a noisy room cuts turns short or a
    // quiet voice is dropped. Adaptive echo cancellation would be the upgrade.
    /// A recording whose loudest moment stays below this held no speech and is not sent.
    nonisolated static let silentPeak: Float = -35
    /// In a conversation, speech is this much above the room's noise floor, and never below the floor limit.
    private static let speechAboveFloor: Float = 12
    private static let speechFloorLimit: Float = -42
    /// In a conversation, this long a quiet after speech sends the turn.
    private static let endOfTurn: TimeInterval = 1.2
    /// In a conversation, this long with nothing said ends it.
    private static let giveUpAfter: TimeInterval = 30
    /// Whisper's usual inventions for near-silence.
    nonisolated private static let phantom: Set<String> = ["you", "thank you", "thanks for watching"]
    /// In a conversation, a turn that never goes quiet this long is noise, not speech: it is
    /// dropped and the conversation ends, so a loud room cannot run up paid turns.
    private static let longestConversationTurn: TimeInterval = 30

    weak var store: Store?
    private var recorder: AVAudioRecorder?
    private var recording: URL { FileManager.default.temporaryDirectory.appendingPathComponent("sift-voice.m4a") }
    private var pressedAt: Date?
    private var lastPress: Date?

    private var meterTimer: Timer?
    private var listenStarted = Date()
    private var noiseFloor: Float = 0
    private var loudestPeak: Float = -160
    private var spokeAt: Date?
    /// Which recording a transcription belongs to, so a late one from an earlier turn is ignored.
    private var turn = 0

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

    private var seat: SeatSession? { store?.seats.first { $0.id == seatId } }

    // MARK: Hotkey
    // Carbon hot keys do not auto-repeat, so a press while listening is always a new tap.

    func keyDown() {
        let now = Date()
        if let lastPress, now.timeIntervalSince(lastPress) < Self.doubleTap {
            self.lastPress = nil
            pressedAt = nil
            if conversation { endConversation() }
            else if let seat = store?.seat { discardRecording(); startConversation(seat) }
            return
        }
        lastPress = nil
        switch phase {
        case .listening: finish()
        case .speaking, .paused:
            stopSpeaking()
            if let seat = seat ?? store?.seat { start(seat); pressedAt = now }
        case .transcribing: break
        case .idle, .waiting:
            guard let seat = store?.seat else { store?.errorText = "Add an agent seat to talk to."; return }
            start(seat)
            pressedAt = now
            // Only a press that opened the microphone can be the first half of a double-tap.
            if phase == .listening, !conversation { lastPress = now }
        }
    }

    func keyUp() {
        if phase == .listening, let pressedAt, Date().timeIntervalSince(pressedAt) > Self.holdThreshold { finish() }
        pressedAt = nil
    }

    // MARK: Buttons

    func toggleConversation(_ seat: SeatSession) {
        conversation && seatId == seat.id ? endConversation() : startConversation(seat)
    }

    func startConversation(_ seat: SeatSession) {
        endConversation()
        conversation = true
        seatId = seat.id
        start(seat)
    }

    func endConversation() {
        conversation = false
        discardRecording()
        stopSpeaking()
        stopFollowing()
        turn += 1 // a transcription in flight is dropped
        phase = .idle
    }

    func togglePause() {
        switch phase {
        case .speaking:
            guard let player, player.isPlaying else { return } // between clips there is nothing to pause
            player.pause()
            phase = .paused
        case .paused: player?.play(); phase = .speaking
        default: break
        }
    }

    // MARK: Listening

    func start(_ seat: SeatSession) {
        guard phase != .transcribing, phase != .listening else { return }
        guard SpeechAPI.storedKey() != nil else {
            store?.errorText = "Voice needs an OpenRouter key: sift voice key - (key on stdin)."
            conversation = false
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            // Never open the microphone on its own once the prompt is answered: press again.
            conversation = false
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.store?.errorText = granted ? "Microphone allowed. Press again to talk."
                            : "Sift can't use the microphone. Allow it in System Settings → Privacy & Security → Microphone."
                    }
                }
            }
            return
        default:
            store?.errorText = "Sift can't use the microphone. Allow it in System Settings → Privacy & Security → Microphone."
            conversation = false
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
            recorder.isMeteringEnabled = true
            guard recorder.record() else { throw SpeechError("The microphone did not start.") }
            self.recorder = recorder
            seatId = seat.id
            listenStarted = Date()
            noiseFloor = 0
            loudestPeak = -160
            spokeAt = nil
            phase = .listening
            NSSound(named: "Tink")?.play()
            // A release the system swallowed must not leave the microphone on.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.longestTurn) { [weak self, weak recorder] in
                guard let self, let recorder, self.recorder === recorder else { return }
                self.finish()
            }
        } catch {
            store?.errorText = error.localizedDescription
            conversation = false
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
        turn += 1
        let thisTurn = turn
        // Too short or never loud enough: nothing was said, so nothing is sent or paid for.
        guard length > 0.3, loudestPeak >= Self.silentPeak, let audio, let seat,
              let key = SpeechAPI.storedKey() else {
            phase = .idle
            listenAgain()
            return
        }
        phase = .transcribing
        Task {
            do {
                let text = try await SpeechAPI(key: key).transcribe(audio, filename: "speech.m4a")
                guard turn == thisTurn, phase == .transcribing else { return } // cancelled meanwhile
                guard !Self.isPhantom(text) else { phase = .idle; listenAgain(); return }
                follow(seat)
                // A typed message still going out goes first.
                for _ in 0..<50 where seat.sending { try? await Task.sleep(nanoseconds: 200_000_000) }
                guard turn == thisTurn else { return }
                if await !seat.send(text: Self.preamble + text) { stopFollowing(); conversation = false }
            } catch {
                guard turn == thisTurn else { return }
                store?.errorText = "Voice: \(error.localizedDescription)"
                conversation = false
                if phase == .transcribing { phase = .idle }
            }
        }
    }

    nonisolated static func isPhantom(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.joined(separator: " ")
        return words.isEmpty || phantom.contains(words)
    }

    private func discardRecording() {
        guard let recorder else { return }
        recorder.stop()
        self.recorder = nil
        try? FileManager.default.removeItem(at: recording)
        if phase == .listening { phase = .idle }
    }

    /// In a conversation, the next turn starts on its own.
    private func listenAgain() {
        guard conversation else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.conversation, self.phase == .idle, let seat = self.seat else { return }
            self.start(seat)
        }
    }

    // MARK: Meter: drives the visual, and in a conversation decides when a turn ends.

    private func startMeter() {
        guard meterTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMeter() {
        meterTimer?.invalidate()
        meterTimer = nil
        meter.level = 0
    }

    private func tick() {
        if let recorder, phase == .listening {
            recorder.updateMeters()
            let power = recorder.averagePower(forChannel: 0)
            loudestPeak = max(loudestPeak, recorder.peakPower(forChannel: 0))
            meter.level = Self.level(power)
            if conversation { detectTurn(power) }
        } else if let player, phase == .speaking {
            player.updateMeters()
            meter.level = Self.level(player.averagePower(forChannel: 0))
        } else if meter.level > 0.01 {
            meter.level *= 0.8
        } else if meter.level != 0 {
            meter.level = 0
        }
    }

    nonisolated static func level(_ power: Float) -> CGFloat {
        CGFloat(sqrt(min(max((power + 50) / 50, 0), 1)))
    }

    private func detectTurn(_ power: Float) {
        let now = Date()
        // The quietest the room has been, ignoring the microphone's first silent frames.
        if power > -100 { noiseFloor = noiseFloor == 0 ? power : min(noiseFloor, power) }
        let threshold = max(noiseFloor + Self.speechAboveFloor, Self.speechFloorLimit)
        if power > threshold { spokeAt = now }
        if let spokeAt, now.timeIntervalSince(spokeAt) > Self.endOfTurn {
            finish()
        } else if spokeAt == nil, now.timeIntervalSince(listenStarted) > Self.giveUpAfter {
            endConversation()
        } else if now.timeIntervalSince(listenStarted) > Self.longestConversationTurn {
            endConversation()
            store?.errorText = "Too noisy to hear where you stopped, so the conversation ended. Hold ⌥⇧Space to talk instead."
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
            self.conversation = false
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
            if speaker == nil { replyDone() }
        } else if !running, !replies.isEmpty {
            let generation = followGeneration
            quiet = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.quietFor * 1_000_000_000)
                guard let self, !Task.isCancelled, self.followGeneration == generation else { return }
                self.heard(messages, running: false, settled: true)
            }
        }
    }

    /// The reply has been heard in full.
    private func replyDone() {
        if phase == .waiting || phase == .speaking { phase = .idle }
        listenAgain()
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
                    if !Task.isCancelled { self.store?.errorText = "Voice: \(error.localizedDescription)" }
                }
            }
            next?.cancel()
            guard let self = self, !Task.isCancelled else { return }
            self.speaker = nil
            if self.following == nil { self.replyDone() }
            else if self.phase == .speaking { self.phase = .waiting }
        }
    }

    /// Plays one clip. Each clip resumes once: when it ends, fails, is stopped, or a little after
    /// its remaining length if the player never reports back (an output device change). A paused
    /// clip waits.
    private func play(_ audio: Data) async {
        guard let player = try? AVAudioPlayer(data: audio) else { return }
        let delegate = PlayerDelegate()
        player.delegate = delegate
        player.isMeteringEnabled = true
        self.player = player
        playerDelegate = delegate
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            let resume = { if !resumed { resumed = true; continuation.resume() } }
            delegate.finished = resume
            playerDone = resume
            watchdog(player, resume)
            if !player.play() { resume() }
        }
        if self.player === player { self.player = nil; playerDelegate = nil; playerDone = nil }
    }

    private func watchdog(_ player: AVAudioPlayer, _ resume: @escaping () -> Void) {
        let left = max(player.duration - player.currentTime, 0) + 1
        DispatchQueue.main.asyncAfter(deadline: .now() + left) { [weak self, weak player] in
            MainActor.assumeIsolated {
                if let self, let player, self.player === player, self.phase == .paused { self.watchdog(player, resume) }
                else { resume() }
            }
        }
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
        if phase == .speaking || phase == .paused { phase = following == nil ? .idle : .waiting }
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
        conversation = false
        discardRecording()
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
