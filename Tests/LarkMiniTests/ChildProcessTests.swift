import XCTest
@testable import LarkMini

final class ChildProcessTests: XCTestCase {
    private func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    func testTimeoutKillsAProcessThatIgnoresTerminationAndItsChildren() async throws {
        let started = Date()
        // The shell ignores SIGTERM and prints its own pid and a child's pid before hanging.
        let (data, status) = try await ChildProcess.run("/bin/sh",
            ["-c", "trap '' TERM; sleep 30 & echo $$ $!; wait"], environment: [:], timeout: 0.5, grace: 0.3)
        XCTAssertEqual(status, .timedOut, "a deadline is reported as no answer")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        let pids = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
        XCTAssertEqual(pids.count, 2)
        try await Task.sleep(nanoseconds: 200_000_000)
        for pid in pids { XCTAssertFalse(alive(pid), "pid \(pid) outlived the read") }
    }

    func testAFinishedRunEndsAChildThatKeepsThePipeOpen() async throws {
        let started = Date()
        let (data, status) = try await ChildProcess.run("/bin/sh", ["-c", "sleep 30 & echo $!"],
                                                        environment: [:], timeout: 10, grace: 0.3)
        XCTAssertEqual(status, .code(0))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        let child = try XCTUnwrap(pid_t(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(alive(child))
    }

    func testLargeOutputArrivesWholeWithTheExitStatus() async throws {
        let (data, status) = try await ChildProcess.run("/bin/sh", ["-c", "head -c 300000 /dev/zero | tr '\\0' a; echo oops >&2; exit 3"],
                                                        environment: [:], timeout: 10)
        XCTAssertEqual(status, .code(3))
        XCTAssertEqual(data.count, 300_005)
    }

    func testALaunchFailureThrowsAndLeaksNoDescriptors() async throws {
        let before = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        for _ in 0..<5 {
            do {
                _ = try await ChildProcess.run("/nonexistent/paseo", [], environment: [:], timeout: 1)
                XCTFail("launch should fail")
            } catch is ChildProcess.LaunchError {}
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count, before)
    }

    func testAStreamTradesLinesAndStopEndsTheWholeGroup() async throws {
        final class Box: @unchecked Sendable { var lines: [String] = []; var status: Int32? }
        let box = Box()
        let replied = expectation(description: "reply"), ended = expectation(description: "exit")
        // A child that answers each line and keeps a grandchild that ignores SIGTERM.
        let stream = try ChildStream("/bin/sh", ["-c", "(trap '' TERM; sleep 30) & echo child $!; while read l; do echo \"got $l\"; done"],
            environment: [:], onLine: { line in
                box.lines.append(String(decoding: line, as: UTF8.self))
                if box.lines.contains("got ping") { replied.fulfill() }
            }, onExit: { status in box.status = status; ended.fulfill() })
        stream.send("ping")
        await fulfillment(of: [replied], timeout: 5)
        let grandchild = try XCTUnwrap(box.lines.first.flatMap { pid_t($0.dropFirst(6)) })
        stream.stop()
        await fulfillment(of: [ended], timeout: 5)
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertNotEqual(kill(grandchild, 0), 0, "the grandchild outlived the stream")
        stream.send("after stop")  // must not crash or raise SIGPIPE
        // Stopping an exited stream signals nothing and still reports that the group is gone.
        let gone = expectation(description: "stopped after exit")
        stream.stop { gone.fulfill() }
        await fulfillment(of: [gone], timeout: 2)
    }

    func testStopRunsItsCallbackOnlyAfterTheGroupHasExited() async throws {
        final class Box: @unchecked Sendable { var exited = false }
        let box = Box()
        let done = expectation(description: "stopped")
        let stream = try ChildStream("/bin/sh", ["-c", "trap '' TERM; while read l; do :; done; sleep 30"], environment: [:],
                                     onLine: { _ in }, onExit: { _ in box.exited = true })
        let started = Date()
        stream.stop { XCTAssertTrue(box.exited, "the callback follows the exit"); done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.9, "a TERM-ignoring child needed the SIGKILL")
    }

    func testAnUnwaitableChildIsNeverSignalledOrGivenAStatus() async throws {
        XCTAssertTrue(ChildProcess.childrenAreWaitable())
        // A pid that is not our child: no confirmed exit, so no group signal and no reap may follow.
        XCTAssertFalse(ChildProcess.awaitExit(1))
        let old = signal(SIGCHLD, SIG_IGN)
        defer { signal(SIGCHLD, old) }
        XCTAssertFalse(ChildProcess.childrenAreWaitable())
        do {
            _ = try await ChildProcess.run("/bin/echo", ["x"], environment: [:], timeout: 1)
            XCTFail("supervision is refused while children are reaped automatically")
        } catch let error as ChildProcess.LaunchError { XCTAssertEqual(error.code, ECHILD) }
    }
}
