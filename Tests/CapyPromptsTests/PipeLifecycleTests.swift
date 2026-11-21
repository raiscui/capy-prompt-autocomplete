import Foundation
import XCTest
@testable import CapyPrompts

final class PipeLifecycleTests: XCTestCase {
    private static let unusedURL = URL(string: "ws://127.0.0.1:9")!
    private static let longInterval: UInt64 = 3_600_000_000_000

    func testCloseBeforeWaitingUnblocks() async {
        let pipe = Pipe(url: Self.unusedURL)
        pipe.close()
        await expectFailure("already-closed pipe", pipe: pipe) {
            try await pipe.holdOpen(ping: {}, interval: Self.longInterval)
        }
    }

    func testPingFailureUnblocks() async {
        struct PingFailure: Error {}
        let pipe = Pipe(url: Self.unusedURL)
        await expectFailure("failed ping", pipe: pipe) {
            try await pipe.holdOpen(ping: { throw PingFailure() }, interval: 10_000_000)
        }
    }

    func testCancellationUnblocks() async {
        let pipe = Pipe(url: Self.unusedURL)
        await expectFailure("cancelled waiter", pipe: pipe, cancel: true) {
            try await pipe.holdOpen(ping: {}, interval: Self.longInterval)
        }
    }

    private func expectFailure(
        _ description: String,
        pipe: CapyPrompts.Pipe,
        cancel: Bool = false,
        action: @escaping @Sendable () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let finished = expectation(description: description)
        let task = Task {
            defer { finished.fulfill() }
            do {
                try await action()
                XCTFail("\(description) unexpectedly succeeded", file: file, line: line)
            } catch {}
        }
        if cancel {
            await Task.yield()
            task.cancel()
        }
        await fulfillment(of: [finished], timeout: 3)
        pipe.close()
        task.cancel()
    }
}
