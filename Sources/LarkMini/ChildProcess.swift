import Foundation
import Darwin

/// Runs a command in its own process group and collects stdout and stderr together.
/// It returns only after the whole group is gone: on exit any leftover group members are
/// killed, and on timeout the group gets SIGTERM, then SIGKILL. All reads and the finish run
/// on one serial queue, so no chunk can land after the result is taken.
/// (`Process.waitUntilExit` once hung a refresh forever after the child had gone.)
enum ChildProcess {
    struct LaunchError: LocalizedError {
        let code: Int32
        var errorDescription: String? { "Could not start Paseo (\(String(cString: strerror(code))))." }
    }

    enum Exit: Equatable {
        case code(Int32)
        /// The deadline ended the run.
        case timedOut
        /// The exit could not be observed (the child was not waitable); no status is invented.
        case unobserved
    }

    static func run(_ path: String, _ arguments: [String], environment: [String: String],
                    timeout: TimeInterval, grace: TimeInterval = 1) async throws -> (Data, Exit) {
        let (pid, readEnd, _) = try spawn(path, arguments, environment: environment, input: false)
        return await withCheckedContinuation { continuation in
            Run(pid: pid, fd: readEnd, timeout: timeout, grace: grace, continuation: continuation).start()
        }
    }

    /// Starts `path` in its own process group with stdout and stderr on one non-blocking pipe,
    /// and stdin either /dev/null or a pipe whose write end is returned (writes never raise SIGPIPE).
    static func spawn(_ path: String, _ arguments: [String], environment: [String: String],
                      input: Bool) throws -> (pid: pid_t, output: Int32, input: Int32?) {
        // With SIGCHLD ignored the system reaps children itself, so a pid (and group id) could be
        // reused before Sift sees the exit; supervising by group would then be unsafe.
        guard childrenAreWaitable() else { throw LaunchError(code: ECHILD) }
        var out: [Int32] = [-1, -1], inp: [Int32] = [-1, -1]
        guard pipe(&out) == 0 else { throw LaunchError(code: errno) }
        if input, pipe(&inp) != 0 {
            let code = errno
            out.forEach { close($0) }
            throw LaunchError(code: code)
        }
        func fail(_ code: Int32) -> LaunchError {
            (out + (input ? inp : [])).forEach { close($0) }
            return LaunchError(code: code)
        }
        // Non-blocking before the spawn, so a failure here cannot leave a child behind.
        let flags = fcntl(out[0], F_GETFL)
        guard flags >= 0, fcntl(out[0], F_SETFL, flags | O_NONBLOCK) == 0 else { throw fail(errno) }
        if input, fcntl(inp[1], F_SETNOSIGPIPE, 1) != 0 { throw fail(errno) }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var code = posix_spawn_file_actions_init(&actions)
        guard code == 0 else { throw fail(code) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        code = posix_spawnattr_init(&attributes)
        guard code == 0 else { throw fail(code) }
        defer { posix_spawnattr_destroy(&attributes) }
        // Own group (pgid = pid) so every descendant can be signalled; no other fds leak in.
        // Any setup step that fails stops the launch: a child without its group could escape cleanup.
        let stdin = input ? posix_spawn_file_actions_adddup2(&actions, inp[0], 0)
                          : posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        guard stdin == 0 else { throw fail(stdin) }
        for step in [{ posix_spawn_file_actions_adddup2(&actions, out[1], 1) },
                     { posix_spawn_file_actions_adddup2(&actions, out[1], 2) },
                     { posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) },
                     { posix_spawnattr_setpgroup(&attributes, 0) }] {
            code = step()
            guard code == 0 else { throw fail(code) }
        }

        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        close(out[1])
        if input { close(inp[0]) }
        guard spawned == 0 else {
            close(out[0])
            if input { close(inp[1]) }
            throw LaunchError(code: spawned)
        }
        return (pid, out[0], input ? inp[1] : nil)
    }

    static func childrenAreWaitable() -> Bool {
        var action = sigaction()
        guard sigaction(SIGCHLD, nil, &action) == 0 else { return false }
        let ignored = unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self) == 1  // SIG_IGN
        return !ignored && action.sa_flags & SA_NOCLDWAIT == 0
    }

    /// Blocks until the child exits, without reaping it. True only when waitid confirmed this
    /// child's exit and its zombie still holds the pid and group id; false for any error, after
    /// which nothing may signal the group or reap the pid.
    static func awaitExit(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        while true {
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == 0 { return info.si_pid == pid }
            if errno != EINTR { return false }
        }
    }

    /// Only after `awaitExit` returned true: kills what is left of the group, then reaps.
    /// Returns the status, or nil if waitpid failed. Call it on the queue that sends the
    /// group's signals; after it, no signal may follow.
    static func reap(_ pid: pid_t) -> Int32? {
        kill(-pid, SIGKILL)
        var raw: Int32 = 0
        while true {
            let result = waitpid(pid, &raw, 0)
            if result == pid { return (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f) }
            if result == -1 && errno == EINTR { continue }
            return nil
        }
    }

    private final class Run {
        let pid: pid_t
        let fd: Int32
        let timeout: TimeInterval
        let grace: TimeInterval
        let queue = DispatchQueue(label: "sift.child")
        var continuation: CheckedContinuation<(Data, Exit), Never>?
        var source: DispatchSourceRead?
        var data = Data()
        /// Set when the exit is known or cannot be known; no signal is sent after that.
        var gone = false
        var status: Int32?
        var ended = false
        var timedOut = false

        init(pid: pid_t, fd: Int32, timeout: TimeInterval, grace: TimeInterval,
             continuation: CheckedContinuation<(Data, Exit), Never>) {
            (self.pid, self.fd, self.timeout, self.grace, self.continuation) = (pid, fd, timeout, grace, continuation)
        }

        func start() {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [self] in drain() }
            source.setCancelHandler { [fd] in close(fd) }
            self.source = source
            source.resume()
            DispatchQueue.global().async { [self] in
                let waitable = ChildProcess.awaitExit(pid)
                // Reaped on the queue that sends signals, so no signal can follow the reap.
                queue.async { [self] in
                    gone = true
                    status = waitable ? ChildProcess.reap(pid) : nil
                    finishIfDone()
                    // A descendant that left the group can hold the pipe open; stop waiting for it.
                    queue.asyncAfter(deadline: .now() + grace) { [self] in finish() }
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { [self] in
                guard continuation != nil, !gone else { return }
                timedOut = true
                kill(-pid, SIGTERM)
                queue.asyncAfter(deadline: .now() + grace) { [self] in
                    guard continuation != nil, !gone else { return }
                    kill(-pid, SIGKILL)
                    queue.asyncAfter(deadline: .now() + grace) { [self] in finish() }
                }
            }
        }

        private func drain() {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 { data.append(buffer, count: count); continue }
                if count == 0 { ended = true }
                else if errno == EINTR { continue }
                else if errno != EAGAIN { ended = true }
                break
            }
            finishIfDone()
        }

        private func finishIfDone() {
            if ended && gone { finish() }
        }

        private func finish() {
            guard let waiting = continuation else { return }
            continuation = nil
            if !ended { drain() }  // take what is already in the pipe
            source?.cancel()
            waiting.resume(returning: (data, timedOut ? .timedOut : status.map(Exit.code) ?? .unobserved))
        }
    }
}

/// A long-running child in its own process group: lines in on stdin, lines out on stdout.
/// Stopping it, or its exit, ends the whole group.
final class ChildStream: @unchecked Sendable {
    private let pid: pid_t
    private let input: Int32
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "sift.stream")
    private var buffer = Data()
    private var stopped = false
    /// Set once the child is reaped; no signal goes to its group id after that.
    private var exited = false

    /// `onLine` and `onExit` run on the main queue; `onExit` gets the exit status once (nil when
    /// the exit could not be observed).
    init(_ path: String, _ arguments: [String], environment: [String: String],
         onLine: @escaping (Data) -> Void, onExit: @escaping (Int32?) -> Void) throws {
        let (pid, output, input) = try ChildProcess.spawn(path, arguments, environment: environment, input: true)
        (self.pid, self.input) = (pid, input!)
        source = DispatchSource.makeReadSource(fileDescriptor: output, queue: queue)
        source.setEventHandler { [weak self] in self?.drain(output, onLine) }
        source.setCancelHandler { close(output) }
        source.resume()
        DispatchQueue.global().async { [weak self, source, queue] in
            let waitable = ChildProcess.awaitExit(pid)
            queue.async {
                let status = waitable ? ChildProcess.reap(pid) : nil
                self?.exited = true
                source.cancel()
                DispatchQueue.main.async { onExit(status) }
            }
        }
    }

    private func drain(_ fd: Int32, _ onLine: @escaping (Data) -> Void) {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 { buffer.append(chunk, count: count); continue }
            if count < 0 && errno == EINTR { continue }
            break
        }
        while let end = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<end]
            buffer.removeSubrange(buffer.startIndex...end)
            if !line.isEmpty { let copy = Data(line); DispatchQueue.main.async { onLine(copy) } }
        }
        if buffer.count > 8_000_000 { buffer.removeAll() }  // a runaway line is dropped, not kept
    }

    /// Best effort: a child that has gone simply does not read it.
    func send(_ line: String) {
        queue.async { [self] in
            guard !stopped else { return }
            let data = Array((line + "\n").utf8)
            var offset = 0
            while offset < data.count {
                let written = data[offset...].withUnsafeBytes { write(input, $0.baseAddress, $0.count) }
                if written < 0 { if errno == EINTR { continue }; return }
                offset += written
            }
        }
    }

    /// SIGTERM to the group, SIGKILL a second later; the exit handler still runs.
    func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            close(input)
            kill(-pid, SIGTERM)
            queue.asyncAfter(deadline: .now() + 1) { [self] in if !exited { kill(-pid, SIGKILL) } }
        }
    }

    deinit { if !stopped { close(input); if !exited { kill(-pid, SIGKILL) } } }
}
