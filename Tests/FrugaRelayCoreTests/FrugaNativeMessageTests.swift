import XCTest

@testable import FrugaRelayCore

/// Round-trips the shell -> native fixtures in `packages/loader/src/native/fixtures/`
/// through `FrugaNativeMessage.decode(_:)`. Fixtures are copied (untracked) into
/// `Tests/Fixtures` before running; see `packages/ios/README.md` / CI sync.
final class FrugaNativeMessageTests: XCTestCase {
  private func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
      "missing fixture \(name).json — run: cp packages/loader/src/native/fixtures/*.json packages/ios/Tests/Fixtures/"
    )
    return try Data(contentsOf: url)
  }

  // MARK: - shell -> native valid fixtures decode to the expected case and payload

  func testReadyValidDecodes() throws {
    let message = try FrugaNativeMessage.decode(fixture("ready.valid"))
    guard case let .ready(payload) = message else { return XCTFail("expected .ready, got \(message)") }
    XCTAssertEqual(payload.protocolVersion, 1)
    XCTAssertEqual(payload.sdkVersion, "1.0.0")
  }

  func testTokenRequiredValidDecodes() throws {
    let message = try FrugaNativeMessage.decode(fixture("tokenRequired.valid"))
    guard case let .tokenRequired(payload) = message else {
      return XCTFail("expected .tokenRequired, got \(message)")
    }
    XCTAssertEqual(payload.reason, .initial)
  }

  func testBalanceValidDecodes() throws {
    let message = try FrugaNativeMessage.decode(fixture("balance.valid"))
    guard case let .balance(payload) = message else { return XCTFail("expected .balance, got \(message)") }
    XCTAssertEqual(payload.available, 12.5)
    XCTAssertEqual(payload.pending, 3.25)
  }

  func testOpenExternalValidDecodes() throws {
    let message = try FrugaNativeMessage.decode(fixture("openExternal.valid"))
    guard case let .openExternal(payload) = message else {
      return XCTFail("expected .openExternal, got \(message)")
    }
    XCTAssertEqual(payload.url, "https://example.com/terms")
  }

  func testBackResultValidDecodes() throws {
    let message = try FrugaNativeMessage.decode(fixture("backResult.valid"))
    guard case let .backResult(payload) = message else {
      return XCTFail("expected .backResult, got \(message)")
    }
    XCTAssertEqual(payload.handled, true)
  }

  func testErrorValidDecodes() throws {
    let message = try FrugaNativeMessage.decode(fixture("error.valid"))
    guard case let .error(payload) = message else { return XCTFail("expected .error, got \(message)") }
    XCTAssertEqual(payload.code, .timeout)
    XCTAssertEqual(payload.message, "Bridge did not respond in time")
    XCTAssertEqual(payload.recoverable, true)
  }

  func testLogValidDecodes() throws {
    let message = try FrugaNativeMessage.decode(fixture("log.valid"))
    guard case let .log(payload) = message else { return XCTFail("expected .log, got \(message)") }
    XCTAssertEqual(payload.level, .info)
    XCTAssertEqual(payload.event, "widget_mounted")
    let data = try XCTUnwrap(payload.data, "expected log.valid.json's data object to decode")
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object["durationMs"] as? Double, 240)
  }

  func testUnsupportedEngineCodeRawValue() {
    XCTAssertEqual(ErrorPayload.Code(rawValue: "UNSUPPORTED_ENGINE"), .unsupportedEngine)
  }

  // UNSUPPORTED_ENGINE is native-raised only (the shell/web loader never sends it), so there
  // is no fixture for it in packages/loader/src/native/fixtures/ — this is a literal, not a
  // copy. The envelope is flat (matches error.valid.json), not nested under "payload".
  func testUnsupportedEngineDecodesFromLiteral() throws {
    let json = Data(
      """
      {"type":"error","code":"UNSUPPORTED_ENGINE","message":"x","recoverable":false}
      """.utf8
    )
    let message = try FrugaNativeMessage.decode(json)
    guard case let .error(payload) = message else { return XCTFail("expected .error, got \(message)") }
    XCTAssertEqual(payload.code, .unsupportedEngine)
    XCTAssertEqual(payload.message, "x")
    XCTAssertEqual(payload.recoverable, false)
  }

  func testDecodedMessagesAreEquatable() throws {
    let first = try FrugaNativeMessage.decode(fixture("balance.valid"))
    let second = try FrugaNativeMessage.decode(fixture("balance.valid"))
    XCTAssertEqual(first, second)
  }

  // MARK: - shell -> native invalid fixtures fail to decode

  func testInvalidFixturesThrow() throws {
    let invalidFixtureNames = [
      "ready.invalid",
      "tokenRequired.invalid",
      "balance.invalid",
      "openExternal.invalid",
      "backResult.invalid",
      "error.invalid",
      "log.invalid",
    ]
    for name in invalidFixtureNames {
      let json = try fixture(name)
      XCTAssertThrowsError(try FrugaNativeMessage.decode(json), "expected \(name).json to throw")
    }
  }
}
