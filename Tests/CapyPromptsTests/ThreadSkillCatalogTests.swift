import Foundation
import XCTest
@testable import CapyPrompts

final class ThreadSkillCatalogTests: XCTestCase {
    private func page(_ url: String, type: String = "page", socket: String = "ws://127.0.0.1:9333/devtools/page/1") -> [String: Any] {
        ["type": type, "url": url, "id": "1", "webSocketDebuggerUrl": socket]
    }

    // MARK: - Page target validation

    func testExactThreadTargetMatches() {
        XCTAssertTrue(ThreadSkillCatalog.matches(page("capy://app/thread/abc123"), thread: "abc123"))
    }

    func testDifferentThreadDoesNotMatch() {
        XCTAssertFalse(ThreadSkillCatalog.matches(page("capy://app/thread/other"), thread: "abc123"))
    }

    func testForeignSchemesAndHostsAreRejected() {
        XCTAssertFalse(ThreadSkillCatalog.matches(page("http://app/thread/abc123"), thread: "abc123"))
        XCTAssertFalse(ThreadSkillCatalog.matches(page("capy://evil.com/thread/abc123"), thread: "abc123"))
        XCTAssertFalse(ThreadSkillCatalog.matches(page("https://127.0.0.1/thread/abc123"), thread: "abc123"))
        XCTAssertFalse(ThreadSkillCatalog.matches(page("about:blank"), thread: "abc123"))
    }

    func testPathMustBeExactlyTwoSegments() {
        XCTAssertFalse(ThreadSkillCatalog.matches(page("capy://app/thread/"), thread: "abc123"))
        XCTAssertFalse(ThreadSkillCatalog.matches(page("capy://app/thread"), thread: "abc123"))
        XCTAssertFalse(ThreadSkillCatalog.matches(page("capy://app/x/thread/abc123"), thread: "abc123"))
        XCTAssertFalse(ThreadSkillCatalog.matches(page("capy://app/thread/abc123/extra"), thread: "abc123"))
    }

    func testNonPageTargetsAreRejected() {
        XCTAssertFalse(ThreadSkillCatalog.matches(page("capy://app/thread/abc123", type: "service_worker"), thread: "abc123"))
        XCTAssertFalse(ThreadSkillCatalog.matches(page("capy://app/thread/abc123", type: "background_page"), thread: "abc123"))
    }

    func testCredentialsAndPortOnPageURLAreRejected() {
        XCTAssertFalse(ThreadSkillCatalog.matches(page("capy://user@app/thread/abc123"), thread: "abc123"))
        XCTAssertFalse(ThreadSkillCatalog.matches(page("capy://app:8080/thread/abc123"), thread: "abc123"))
    }

    // MARK: - Debugger socket validation

    func testLoopbackSocketOn9333IsAccepted() {
        XCTAssertEqual(ThreadSkillCatalog.socketURL(page("capy://app/thread/abc123")),
                       URL(string: "ws://127.0.0.1:9333/devtools/page/1"))
    }

    func testForeignSocketsAreRejected() {
        for raw in [
            "ws://evil.com:9333/devtools/page/1",
            "ws://127.0.0.1:9222/devtools/page/1",
            "wss://127.0.0.1:9333/devtools/page/1",
            "http://127.0.0.1:9333/devtools/page/1",
            "ws://localhost:9333/devtools/page/1",
            "ws://[::1]:9333/devtools/page/1",
            "ws://user@127.0.0.1:9333/devtools/page/1",
        ] {
            let target = page("capy://app/thread/abc123", socket: raw)
            XCTAssertNil(ThreadSkillCatalog.socketURL(target), raw)
        }
    }

    func testMissingSocketFieldIsRejected() {
        let target: [String: Any] = ["type": "page", "url": "capy://app/thread/abc123", "id": "1"]
        XCTAssertNil(ThreadSkillCatalog.socketURL(target))
    }

    // MARK: - Cache bounds and lifetime

    func testCacheServesWithinLifetimeAndCachesEmpty() {
        var cache = SkillCache(lifetime: 45, capacity: 4)
        let now = Date()
        let skills = [ThreadSkill(name: "a", description: "d")]
        cache.store(skills, for: "t1", at: now)
        cache.store([], for: "t2", at: now)
        XCTAssertEqual(cache.skills(for: "t1", at: now), skills)
        XCTAssertEqual(cache.skills(for: "t1", at: now.addingTimeInterval(44)), skills)
        XCTAssertEqual(cache.skills(for: "t2", at: now.addingTimeInterval(10)), [])
        XCTAssertNil(cache.skills(for: "t1", at: now.addingTimeInterval(45)))
    }

    func testCacheEvictsOldestBeyondCapacity() {
        var cache = SkillCache(lifetime: 45, capacity: 2)
        let now = Date()
        let skill = ThreadSkill(name: "s", description: "")
        cache.store([skill], for: "t1", at: now)
        cache.store([skill], for: "t2", at: now)
        cache.store([skill], for: "t3", at: now)
        XCTAssertNil(cache.skills(for: "t1", at: now))
        XCTAssertEqual(cache.skills(for: "t2", at: now), [skill])
        XCTAssertEqual(cache.skills(for: "t3", at: now), [skill])
    }

    func testStoreSameThreadKeepsLatestAndDoesNotGrow() {
        var cache = SkillCache(lifetime: 45, capacity: 1)
        let now = Date()
        cache.store([ThreadSkill(name: "old", description: "")], for: "t1", at: now)
        cache.store([ThreadSkill(name: "new", description: "")], for: "t1", at: now)
        XCTAssertEqual(cache.skills(for: "t1", at: now), [ThreadSkill(name: "new", description: "")])
    }

    // MARK: - Actor surface

    func testEmptyThreadFailsWithoutNetwork() async {
        let catalog = ThreadSkillCatalog()
        do {
            _ = try await catalog.skills(for: "")
            XCTFail("an empty thread must not reach the endpoint")
        } catch {
            XCTAssertEqual(error as? ThreadSkillCatalog.Failure, .noSuchThread)
        }
    }
}
