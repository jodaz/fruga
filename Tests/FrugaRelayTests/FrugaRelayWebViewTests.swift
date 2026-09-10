#if canImport(WebKit)

import XCTest

@testable import FrugaRelay

/// RED tests for issue #75 review blocker: `FrugaRelayWebView.jsStringLiteral`
/// escapes every `init` payload crossing into `window.FrugaNative.receive(...)`
/// and had no test. Requires the sdk-reviewer follow-up: the method becomes
/// `internal` (dropping `private`) so it is reachable via `@testable import`.
///
/// WebKit is unavailable on Linux, so this whole file is compiled out there —
/// it only runs in the mirror's macos-15 CI job.
final class FrugaRelayWebViewTests: XCTestCase {
  private func literal(for string: String) throws -> String {
    try XCTUnwrap(FrugaRelayWebView.jsStringLiteral(Data(string.utf8)))
  }

  private func decode(_ literal: String) throws -> String {
    try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(literal.utf8), options: .fragmentsAllowed)
        as? String
    )
  }

  func testPlainStringRoundTripsInsideQuotes() throws {
    let original = "hello world"
    let result = try literal(for: original)

    XCTAssertTrue(result.hasPrefix("\""))
    XCTAssertTrue(result.hasSuffix("\""))
    XCTAssertEqual(try decode(result), original)
  }

  func testDoubleQuoteAndBackslashAreEscaped() throws {
    let original = "a\"b\\c"
    let result = try literal(for: original)

    XCTAssertTrue(result.contains("\\\""))
    XCTAssertTrue(result.contains("\\\\"))
    XCTAssertEqual(try decode(result), original)
  }

  func testNewlineIsEscapedNotRaw() throws {
    let original = "line1\nline2"
    let result = try literal(for: original)

    XCTAssertFalse(result.contains("\n"))
    XCTAssertTrue(result.contains("\\n"))
    XCTAssertEqual(try decode(result), original)
  }

  func testLineAndParagraphSeparatorsAreNotRaw() throws {
    let original = "a\u{2028}b\u{2029}c"
    let result = try literal(for: original)

    XCTAssertFalse(result.contains("\u{2028}"))
    XCTAssertFalse(result.contains("\u{2029}"))
  }

  func testNonUTF8BytesReturnNil() {
    let invalidUTF8 = Data([0xff, 0xfe, 0xfd])

    XCTAssertNil(FrugaRelayWebView.jsStringLiteral(invalidUTF8))
  }
}

#endif
