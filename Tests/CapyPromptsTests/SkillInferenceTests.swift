import Foundation
import XCTest
@testable import CapyPrompts

/// Regression tests for the skill-aware completion request and response paths.
/// A stub `URLProtocol` answers every request with a canned chat completion, so
/// these tests assert the request body the model would see and the candidates the
/// picker would show — no network and no real model is involved.
final class SkillInferenceTests: XCTestCase {
	override class func setUp() {
		StubProtocol.reset()
	}

	override func setUp() {
		StubProtocol.reset()
	}

	private static let skills = [
		ThreadSkill(name: "diagnosing-bugs", description: "Diagnose a reported defect before fixing it."),
		ThreadSkill(name: "systematic-debugging", description: "Debug broken, throwing or slow behavior."),
	]

	func testStructuredRequestCarriesWholeCatalog() async throws {
		let catalog = (1 ... 297).map { ThreadSkill(name: "skill-\($0)", description: "Description \($0)") }
		let (request, results) = try await complete(prefix: "", context: "Analyze the workbook", skills: catalog,
			response: #"{"candidates":[{"skill_ids":["skill-297"],"text":"Analyze the workbook and report the findings."}]}"#)
		XCTAssertEqual(results, ["$skill-297 Analyze the workbook and report the findings."])
		let body = try XCTUnwrap(lastRequestJSON(request))
		XCTAssertEqual((body["response_format"] as? [String: String])?["type"], "json_object")
		let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
		let system = try XCTUnwrap(messages.first?["content"] as? String)
		let user = try XCTUnwrap(messages.last?["content"] as? String)
		XCTAssertTrue(system.contains("first select catalog skill names"))
		XCTAssertFalse(system.contains("<ins>"))
		guard let header = user.range(of: "Available thread skills (metadata only):\n") else { return XCTFail("missing catalog") }
		let payload = String(user[header.upperBound...].components(separatedBy: "\n\n").first ?? "")
		let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [[String: String]])
		XCTAssertEqual(entries.count, 297)
		XCTAssertEqual(entries.last?["name"], "skill-297")
		XCTAssertEqual(Set(entries.last?.keys.map { $0 } ?? []), ["name", "description"])
	}

	func testStructuredChineseAndPlainAlternatives() async throws {
		let (_, results) = try await complete(prefix: "", context: "排查故障", full: true, skills: Self.skills,
			response: #"{"candidates":[{"skill_ids":["diagnosing-bugs"],"text":"排查当前故障并报告原因。"},{"skill_ids":[],"text":"整理复现步骤。"}]}"#)
		XCTAssertEqual(results, ["$diagnosing-bugs 排查当前故障并报告原因。", "整理复现步骤。"])
	}

	func testEmptyAutomaticRequestsOneCandidateInUserVoice() async throws {
		let (request, results) = try await complete(prefix: "", context: "Analyze the data", full: false, skills: Self.skills,
			response: #"{"candidates":[{"skill_ids":[],"text":"分析 [文件路径] 并报告结果。"}]}"#)
		XCTAssertEqual(results, ["分析 [文件路径] 并报告结果。"])
		let body = try XCTUnwrap(lastRequestJSON(request))
		XCTAssertGreaterThanOrEqual(try XCTUnwrap(body["max_tokens"] as? Int), 1024)
		let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
		let system = try XCTUnwrap(messages.first?["content"] as? String)
		XCTAssertTrue(system.contains("message from the user to Capy"))
		XCTAssertTrue(system.contains("clearly marked placeholder"))
		XCTAssertTrue(system.contains("Return at most one candidate."))
		XCTAssertFalse(system.contains("at most three independently useful candidates"))
	}

	func testStructuredFullDraftAndExistingMention() async throws {
		let (_, inserted) = try await complete(prefix: "请", context: "排查故障", skills: Self.skills,
			response: #"{"candidates":[{"skill_ids":["diagnosing-bugs"],"text":"排查当前故障。"}]}"#)
		XCTAssertEqual(inserted, [" $diagnosing-bugs 排查当前故障。"])
		let (_, existing) = try await complete(prefix: "请用 $diagnosing-bugs ", context: "排查故障", skills: Self.skills,
			response: #"{"candidates":[{"skill_ids":["diagnosing-bugs"],"text":"排查当前故障。"}]}"#)
		XCTAssertEqual(existing, ["排查当前故障。"])
	}

	func testStructuredRejectsInvalidAndPartialResponses() async throws {
		let invalid = [
			#"{"candidates":[{"skill_ids":["unknown"],"text":"Inspect the issue."}]}"#,
			#"{"candidates":[{"skill_ids":["diagnosing"],"text":"Inspect the issue."}]}"#,
			#"{"candidates":[{"skill_ids":["diagnosing-bugs"],"text":"Inspect the issue."}, {"skill_ids":["unknown"],"text":"Inspect further."}]}"#,
			#"{"candidates":[{"skill_ids":["diagnosing-bugs","diagnosing-bugs"],"text":"Inspect the issue."}]}"#,
			#"{"candidates":[{"skill_ids":[],"text":"<ins>Inspect the issue.</ins>"}]}"#,
			#"{"candidates":[{"skill_ids":[],"text":"Inspect"}"#,
			"<ins>Inspect the issue.</ins>",
		]
		for response in invalid {
			let (_, results) = try await complete(prefix: "", context: "Inspect the issue", skills: Self.skills, response: response)
			XCTAssertEqual(results, [], response)
		}
		let skills = ["a", "b", "c", "d"].map { ThreadSkill(name: $0, description: $0) }
		let (_, tooMany) = try await complete(prefix: "", context: "Inspect", skills: skills,
			response: #"{"candidates":[{"skill_ids":["a","b","c","d"],"text":"Inspect the issue."}]}"#)
		XCTAssertEqual(tooMany, [])
	}

	func testGhostAndNoCatalogRetainTagFormat() async throws {
		let (request, ghost) = try await complete(prefix: "排查当前", context: "故障", full: false, skills: Self.skills,
			response: "<ins>故障。</ins>")
		XCTAssertEqual(ghost, ["故障。"])
		XCTAssertNil(try XCTUnwrap(lastRequestJSON(request))["response_format"])
		let (_, plain) = try await complete(prefix: "", context: "排查故障", skills: [], response: "<ins>排查当前故障。</ins>")
		XCTAssertEqual(plain, ["排查当前故障。"])
	}

	// MARK: - validSkillReferences

	func testValidSkillReferences() {
		let skills = Self.skills
		XCTAssertTrue(Generator.validSkillReferences(in: "用 $diagnosing-bugs 排查.", skills: skills))
		XCTAssertTrue(Generator.validSkillReferences(in: "plain text, no mentions", skills: skills))
		XCTAssertTrue(Generator.validSkillReferences(in: "$5 for coffee and $HOME/bin", skills: skills))
		XCTAssertTrue(Generator.validSkillReferences(in: "see https://example.com/x?$term", skills: skills))
		XCTAssertTrue(Generator.validSkillReferences(in: "release was cut on $2026-11-21", skills: skills))
		// A CJK character is not a word boundary blocker: "用$a" still counts as a mention.
		XCTAssertTrue(Generator.validSkillReferences(in: "用$diagnosing-bugs 排查.", skills: skills))
		XCTAssertFalse(Generator.validSkillReferences(in: "使用$madeup 排查.", skills: skills))
		// Three mentions pass, four do not.
		XCTAssertTrue(Generator.validSkillReferences(
			in: "$a $b $c", skills: ["a", "b", "c"].map { ThreadSkill(name: $0, description: "") }))
		XCTAssertFalse(Generator.validSkillReferences(
			in: "$a $b $c $d", skills: ["a", "b", "c", "d"].map { ThreadSkill(name: $0, description: "") }))
		// Unknown names are rejected unless they occur in recognizable shell syntax.
		XCTAssertTrue(Generator.validSkillReferences(in: "print $mymacro now", skills: skills))
		XCTAssertFalse(Generator.validSkillReferences(in: "$nosuch handle the task", skills: skills))
		XCTAssertFalse(Generator.validSkillReferences(in: "Please try $nosuch for this", skills: skills))
		XCTAssertFalse(Generator.validSkillReferences(in: "$spreadsheets analyze this", skills: []))
		XCTAssertFalse(Generator.validSkillReferences(in: "use $mymacro now", skills: skills))
		XCTAssertFalse(Generator.validSkillReferences(in: "run $unknown-skill", skills: skills))
		XCTAssertFalse(Generator.validSkillReferences(in: "read $foo.bar", skills: skills))
		// Foreign OMP invocation syntax never passes, even for a real skill.
		XCTAssertFalse(Generator.validSkillReferences(in: "/skill:diagnosing-bugs go", skills: skills))
		XCTAssertFalse(Generator.validSkillReferences(in: "先阅读 skill://diagnosing-bugs", skills: skills))
		// Without a catalog nothing can be verified as a mention.
		XCTAssertFalse(Generator.validSkillReferences(in: "use $diagnosing-bugs", skills: []))
		XCTAssertFalse(Generator.validSkillReferences(in: "run $unknown-skill", skills: []))
	}

	// MARK: - Stub transport

	private func complete(
		prefix: String,
		suffix: String = "",
		context: String,
		full: Bool = true,
		skills: [ThreadSkill],
		response: String,
		file: StaticString = #filePath,
		line: UInt = #line
	) async throws -> (URLRequest?, [String]) {
		StubProtocol.response = "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"role\":\"assistant\",\"content\":\"\(response.jsonEscaped)\"}}]}"
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [StubProtocol.self]
		let generator = Generator(
			configuration: Generator.Configuration(
				endpoint: URL(string: "https://stub.invalid/v1/chat/completions")!,
				model: "stub-model",
				apiKey: nil),
			session: URLSession(configuration: configuration))
		do {
			let results = try await generator.candidates(
				prefix: prefix, suffix: suffix, context: context, full: full, skills: skills)
			return (StubProtocol.lastRequest, results)
		} catch {
			XCTFail("candidates threw \(error)", file: file, line: line)
			return (StubProtocol.lastRequest, [])
		}
	}

	private func lastRequestJSON(_ request: URLRequest?) -> [String: Any]? {
		guard let data = request.flatMap(Self.requestBody) else { return nil }
		return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
	}

	/// The URLSession may stream a request body instead of keeping `httpBody`.
	private static func requestBody(_ request: URLRequest) -> Data? {
		if let body = request.httpBody { return body }
		guard let stream = request.httpBodyStream else { return nil }
		stream.open()
		defer { stream.close() }
		var data = Data()
		var chunk = [UInt8](repeating: 0, count: 4096)
		while stream.hasBytesAvailable {
			let read = stream.read(&chunk, maxLength: chunk.count)
			if read <= 0 { break }
			data.append(contentsOf: chunk[..<read])
		}
		return data
	}
}

/// Answers every request with one canned chat completion and records the request.
private final class StubProtocol: URLProtocol {
	static var response = "{}"
	static var lastRequest: URLRequest?

	static func reset() {
		response = "{}"
		lastRequest = nil
	}

	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		StubProtocol.lastRequest = request
		let data = Data(StubProtocol.response.utf8)
		client?.urlProtocol(self, didReceive: HTTPURLResponse(
			url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
			cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: data)
		client?.urlProtocolDidFinishLoading(self)
	}

	override func stopLoading() {}
}

private extension String {
	/// Escape a raw string for embedding inside a JSON string literal.
	var jsonEscaped: String {
		var out = ""
		for scalar in unicodeScalars {
			switch scalar {
			case "\\": out += "\\\\"
			case "\"": out += "\\\""
			case "\n": out += "\\n"
			case "\r": out += "\\r"
			case "\t": out += "\\t"
			default: out.unicodeScalars.append(scalar)
			}
		}
		return out
	}
}
