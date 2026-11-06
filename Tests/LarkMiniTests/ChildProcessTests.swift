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
