import Foundation
import XCTest
@testable import CapyPrompts

/// Regression tests for the reported defects around long generated suggestions:
/// 1. A completed long candidate was silently cut to a character budget, so the user
///    saw it end mid-sentence or accepted an incomplete insertion.
/// 2. When the provider stopped at the token limit, the partial text could still be
///    returned (ghost mode accepted it wholesale) or the failure was indistinguishable
///    from "no suggestion", giving the user nothing to act on.
///
/// A stub `URLProtocol` answers each request with a canned chat completion — real
/// request/response through `Generator.candidates`, no network.
final class LongCandidateTests: XCTestCase {
	private static let skills = [
		ThreadSkill(name: "diagnosing-bugs", description: "Diagnose a reported defect before fixing it."),
		ThreadSkill(name: "systematic-debugging", description: "Debug broken, throwing or slow behavior."),
	]

	/// A multi-paragraph instruction that used to exceed every character cap the old
	/// budgets imposed (ghost 200/400, list 1400, empty 1800 UTF-16 units).
	private static let longMultiline = (1...36).map {
		"第\($0)段：请核对原始数据与公式引用的完整性，说明每一项差异及其影响，再根据核对结果提出修订建议。"
	}.joined(separator: "\n") + "\nReport the evidence, not a summary of intent."

	// MARK: - Completed candidates are never sliced

	/// The explicit list used to cap candidates at 1400 chars; a longer completed
	/// candidate must now come back whole, line breaks included.
	func testListKeepsCompletedLongCandidateWhole() async throws {
		let results = try await complete(
			prefix: "请帮我", context: "修复补全截断问题", full: true, skills: [],
			finishReason: "stop",
			response: "<ins>\(Self.longMultiline)</ins><ins>用现有测试确认补全仍工作。</ins>")
		XCTAssertEqual(results, [Self.longMultiline, "用现有测试确认补全仍工作。"])
		XCTAssertTrue(results[0].contains("Report the evidence, not a summary of intent."))
	}

	/// The structured path (skills catalog present) has no <ins> tags to close; the
	/// completed text field must also come back whole.
	func testStructuredKeepsCompletedLongCandidateWhole() async throws {
		let results = try await complete(
			prefix: "请", context: "修复补全截断问题", full: true, skills: Self.skills,
			finishReason: "stop",
			response: #"{"candidates":[{"skill_ids":["diagnosing-bugs"],"text":"\#(Self.longMultiline.jsonEscaped)"}]}"#)
		XCTAssertEqual(results, [" $diagnosing-bugs " + Self.longMultiline])
	}

	/// The ghost path used to cap at 400 chars; a long completed ghost continuation is
	/// returned whole — length is the token budget's job, not the post-processor's.
	func testGhostKeepsCompletedLongCandidateWhole() async throws {
		let results = try await complete(
			prefix: "先", context: "修复补全截断问题", full: false, skills: [],
			finishReason: "stop",
			response: "<ins>\(Self.longMultiline)</ins>")
		XCTAssertEqual(results, [Self.longMultiline])
	}

	// MARK: - Provider token-limit truncation is never surfaced as a candidate

	/// A tagless legacy reply cut off by the token limit must not be inserted — the
	/// whole reply is one candidate and it is provably incomplete.
	func testLegacyLengthReplyYieldsActionableError() async throws {
		let error = await completeExpectingError(
			prefix: "写一段说明，要求", context: "补全建议需要完整指令", full: true, skills: [],
			finishReason: "length",
			response: "先检查候选面板的行数和截断逻辑，然后把截断点挪到")
		guard case GeneratorError.truncated? = error else {
			return XCTFail("expected GeneratorError.truncated, got \(String(describing: error))")
		}
		XCTAssertTrue(error?.localizedDescription.contains("token") == true)
	}

	/// The ghost previously kept a token-limited reply ("the ghost shows one line and
	/// may keep it"); the clipped tail is exactly the mid-sentence text users accepted.
	func testGhostLengthReplyYieldsActionableError() async throws {
		let error = await completeExpectingError(
			prefix: "把长建议", context: "修复补全截断", full: false, skills: [],
			finishReason: "length",
			response: "<ins>完整保留并且不要在中途截断，先检查")
		guard case GeneratorError.truncated? = error else {
			return XCTFail("expected GeneratorError.truncated, got \(String(describing: error))")
		}
	}

	/// A structured reply stopped at the token limit cannot be valid JSON; it must
	/// surface as the truncation error, not a silent empty list.
	func testStructuredLengthReplyYieldsActionableError() async throws {
		let error = await completeExpectingError(
			prefix: "", context: "修复补全截断问题", full: true, skills: Self.skills,
			finishReason: "length",
			response: #"{"candidates":[{"skill_ids":["diagnosing-bugs"],"text":"先检查"#)
		guard case GeneratorError.truncated? = error else {
			return XCTFail("expected GeneratorError.truncated, got \(String(describing: error))")
		}
	}

	/// Closed <ins> blocks in a cut-off reply are still complete candidates and stay
	/// usable; only the unterminated tail is dropped.
	func testLengthReplyKeepsClosedBlocks() async throws {
		let results = try await complete(
			prefix: "请", context: "修复补全截断问题", full: true, skills: [],
			finishReason: "length",
			response: "<ins>先看生成路径而不是插入路径。</ins><ins>把截断挪到")
		XCTAssertEqual(results, ["先看生成路径而不是插入路径。"])
	}

	/// The same reply shape without a provider length signal keeps its historical
	/// behavior: an unterminated final block is still a candidate (the model just
	/// ended there).
	func testStopReplyKeepsUnterminatedTail() async throws {
		let results = try await complete(
			prefix: "请", context: "修复补全截断问题", full: true, skills: [],
			finishReason: "stop",
			response: "<ins>先看生成路径。</ins><ins>把截断挪到上游预算")
		XCTAssertEqual(results, ["先看生成路径。", "把截断挪到上游预算"])
	}

	// MARK: - Stub transport

	private func complete(
		prefix: String,
		suffix: String = "",
		context: String,
		full: Bool,
		skills: [ThreadSkill],
		finishReason: String,
		response: String
	) async throws -> [String] {
		LongStubProtocol.response = "{\"choices\":[{\"finish_reason\":\"\(finishReason)\",\"message\":{\"role\":\"assistant\",\"content\":\"\(response.jsonEscaped)\"}}]}"
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [LongStubProtocol.self]
		let generator = Generator(
			configuration: Generator.Configuration(
				endpoint: URL(string: "https://stub.invalid/v1/chat/completions")!,
				model: "stub-model",
				apiKey: nil),
			session: URLSession(configuration: configuration))
		return try await generator.candidates(
			prefix: prefix, suffix: suffix, context: context, full: full, skills: skills)
	}

	private func completeExpectingError(
		prefix: String,
		suffix: String = "",
		context: String,
		full: Bool,
		skills: [ThreadSkill],
		finishReason: String,
		response: String
	) async -> Error? {
		do {
			let results = try await complete(
				prefix: prefix, suffix: suffix, context: context, full: full,
				skills: skills, finishReason: finishReason, response: response)
			XCTFail("expected an error, got \(results)")
			return nil
		} catch {
			return error
		}
	}
}

/// Answers every request with one canned chat completion and records nothing.
private final class LongStubProtocol: URLProtocol {
	static var response = "{}"

	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		let data = Data(LongStubProtocol.response.utf8)
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
