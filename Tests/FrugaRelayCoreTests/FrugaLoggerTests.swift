import XCTest

@testable import FrugaRelayCore

/// RED tests for issue #79 (M2 batch 1): the partner log sink, mirrored on
/// Android by `FrugaLogger` / `FrugaLogger.error` in
/// `packages/android/relay/src/main/kotlin/uk/co/fruga/relay/FrugaLogger.kt`
/// and its test `FrugaLoggerTest.kt`. Contract (not yet implemented —
/// `FrugaRelayCore` has no `FrugaLogger` today):
///
/// ```swift
/// public protocol FrugaLogger {
///   func log(level: LogPayload.Level, event: String, data: [String: String])
/// }
/// extension FrugaLogger {
///   func log(level: LogPayload.Level, event: String) // default data: [:]
/// }
/// extension FrugaLogger {
///   func error(_ error: FrugaError) // level: .error, event: "error",
///     // data: ["code": ..., "message": ..., "recoverable": ...]
/// }
/// ```
final class FrugaLoggerTests: XCTestCase {
  // MARK: - 1. error(_:) maps a FrugaError onto level .error, event "error",
  //           and its fields as string data — same shape as Android's.

  func testErrorMapsFrugaErrorOntoLevelErrorEventErrorAndItsFieldsAsData() {
    let recorder = RecordingLogger()
    let error = FrugaError(code: .bridgeTimeout, message: "renderer unresponsive", recoverable: true)

    recorder.error(error)

    XCTAssertEqual(recorder.calls.count, 1)
    let call = try? XCTUnwrap(recorder.calls.first)
    XCTAssertEqual(call?.level, .error)
    XCTAssertEqual(call?.event, "error")
    XCTAssertEqual(
      call?.data,
      [
        "code": "BRIDGE_TIMEOUT",
        "message": "renderer unresponsive",
        "recoverable": "true"
      ]
    )
  }

  // MARK: - 2. Every ErrorPayload.Code produces a logged error event carrying
  //           that code (mirrors Android's exhaustive-codes test).

  func testEveryErrorCodeProducesALoggedErrorEvent() {
    for code in [
      ErrorPayload.Code.timeout, .versionMismatch, .bootstrapFailed, .offline,
      .bridgeTimeout, .processTerminated, .tokenProviderFailed, .unsupportedEngine
    ] {
      let recorder = RecordingLogger()

      recorder.error(FrugaError(code: code, message: "\(code) detail", recoverable: true))

      XCTAssertEqual(recorder.calls.count, 1)
      XCTAssertEqual(recorder.calls.first?.level, .error)
      XCTAssertEqual(recorder.calls.first?.event, "error")
      XCTAssertEqual(recorder.calls.first?.data["code"], code.rawValue)
    }
  }

  // MARK: - 3. The default-argument extension lets a conformer call
  //           log(level:event:) with no data.

  func testLogWithNoDataArgumentDefaultsToEmptyData() {
    let recorder = RecordingLogger()

    recorder.log(level: .info, event: "shell.loaded")

    XCTAssertEqual(recorder.calls.count, 1)
    XCTAssertEqual(recorder.calls.first?.data, [:])
  }

  // MARK: - 4. RED for the sdk-reviewer's M2 batch 1 finding (F8): a
  //           `redactSecrets` free function in `FrugaLogger.swift` mirrors
  //           Android's private `redactSecrets` in
  //           `packages/android/relay/.../FrugaLogger.kt`: any `token=` or
  //           `partnerKey=` query value is replaced with the redaction
  //           marker. Android's marker is its `FrugaShellSession.REDACTED`
  //           constant, `"<redacted>"`; iOS's `FrugaShellSession` has no such
  //           marker yet (see Handoffs), so this test hardcodes the same
  //           literal for platform parity — the owner may instead expose a
  //           shared constant, provided the marker text does not change.
  //
  // ```swift
  // public func redactSecrets(_ value: String) -> String
  // ```

  func testRedactSecretsReplacesTokenAndPartnerKeyQueryValues() {
    let input = "https://x/?token=abc&partnerKey=pk&other=1"

    let result = redactSecrets(input)

    XCTAssertEqual(result, "https://x/?token=<redacted>&partnerKey=<redacted>&other=1")
  }
}

// MARK: - Test double

private final class RecordingLogger: FrugaLogger {
  private(set) var calls: [(level: LogPayload.Level, event: String, data: [String: String])] = []

  func log(level: LogPayload.Level, event: String, data: [String: String]) {
    calls.append((level, event, data))
  }
}
