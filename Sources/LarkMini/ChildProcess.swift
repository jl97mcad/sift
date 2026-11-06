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

    /// Exit status, or nil when the deadline ended the run.
    static func run(_ path: String, _ arguments: [String], environment: [String: String],
                    timeout: TimeInterval, grace: TimeInterval = 1) async throws -> (Data, Int32?) {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw LaunchError(code: errno) }
        let (readEnd, writeEnd) = (fds[0], fds[1])

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Own group (pgid = pid) so every descendant can be signalled; no other fds leak in.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        close(writeEnd)
        guard spawned == 0 else { close(readEnd); throw LaunchError(code: spawned) }
        _ = fcntl(readEnd, F_SETFL, fcntl(readEnd, F_GETFL) | O_NONBLOCK)

        return await withCheckedContinuation { continuation in
            Run(pid: pid, fd: readEnd, timeout: timeout, grace: grace, continuation: continuation).start()
        }
    }

    private final class Run {
        let pid: pid_t
        let fd: Int32
        let timeout: TimeInterval
        let grace: TimeInterval
        let queue = DispatchQueue(label: "sift.child")
        var continuation: CheckedContinuation<(Data, Int32?), Never>?
        var source: DispatchSourceRead?
        var data = Data()
        var status: Int32?
        var ended = false
        var timedOut = false

        init(pid: pid_t, fd: Int32, timeout: TimeInterval, grace: TimeInterval,
             continuation: CheckedContinuation<(Data, Int32?), Never>) {
            (self.pid, self.fd, self.timeout, self.grace, self.continuation) = (pid, fd, timeout, grace, continuation)
        }

        func start() {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [self] in drain() }
            source.setCancelHandler { [fd] in close(fd) }
            self.source = source
            source.resume()
            // Observe the exit without reaping: while the zombie holds the pid, the group id
            // cannot be reused, so killing leftovers cannot hit an unrelated process.
            DispatchQueue.global().async { [self] in
                var info = siginfo_t()
                while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
                kill(-pid, SIGKILL)
                var raw: Int32 = 0
                while waitpid(pid, &raw, 0) == -1 && errno == EINTR {}
                queue.async { [self] in
                    status = (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
                    finishIfDone()
                    // A descendant that left the group can hold the pipe open; stop waiting for it.
                    queue.asyncAfter(deadline: .now() + grace) { [self] in finish() }
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { [self] in
                guard continuation != nil else { return }
                timedOut = true
                kill(-pid, SIGTERM)
                queue.asyncAfter(deadline: .now() + grace) { [self] in
                    guard continuation != nil else { return }
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
            if ended && status != nil { finish() }
        }

        private func finish() {
            guard let waiting = continuation else { return }
            continuation = nil
            if !ended { drain() }  // take what is already in the pipe
            source?.cancel()
            waiting.resume(returning: (data, timedOut ? nil : status))
        }
    }
}
