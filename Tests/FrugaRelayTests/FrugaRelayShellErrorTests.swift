#if canImport(UIKit) && canImport(WebKit)

import UIKit
import XCTest

@testable import FrugaRelayCore
@testable import FrugaRelay

/// RED tests for the sdk-reviewer's finding on `FrugaRelayViewController`
/// (`FrugaRelayViewController.swift:244`): a shell-sent `error` message is
/// mapped to a `FrugaError` and handed to `FrugaRelay.logger` only, via
/// `forwardToLogger`'s `.error` case. The partner's `open(from:onError:)`
/// closure never sees it, unlike Android which routes the same message to
/// both the logger and `onError`.
///
/// Seam: `FrugaRelayViewController.session` is already internal-visible to
/// `@testable import FrugaRelay` (see `FrugaRelayLoggingTests.swift`), so this
/// drives the bug the same way that file drives `log`/dropped messages —
/// `controller.session.receive(_:)` with the `error.valid` fixture read from
/// `Bundle.module`, never hand-copied JSON.
///
/// Written blind: this file only runs in the mirror's macOS job.
@MainActor
final class FrugaRelayShellErrorTests: XCTestCase {
  override func tearDown() {
    FrugaRelay.reset()
    super.tearDown()
  }

  private func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
      "missing fixture \(name).json — run: cp packages/loader/src/native/fixtures/*.json packages/ios/Tests/Fixtures/"
    )
    return try Data(contentsOf: url)
  }

  private func makeController(onError: @escaping (FrugaError) -> Void) -> FrugaRelayViewController {
    let config = FrugaRelayConfig(
      partnerKey: "partner_test_123",
      tokenProvider: { _ in "eyJ.test" },
      options: FrugaRelayOptions()
    )
    let controller = FrugaRelayViewController(config: config, onError: onError)
    controller.loadsShellAutomatically = false
    return controller
  }

  func testShellErrorMessageReachesOnErrorWithTheFixturesCodeMessageAndRecoverable() throws {
    let logger = RecordingLogger()
    FrugaRelay.logger = logger
    var reportedErrors: [FrugaError] = []
    let controller = makeController(onError: { reportedErrors.append($0) })

    controller.session.receive(try fixture("error.valid"))

    // The fixture at packages/loader/src/native/fixtures/error.valid.json:
    // { "type": "error", "code": "TIMEOUT", "message": "Bridge did not respond in time", "recoverable": true }
    XCTAssertEqual(
      reportedErrors,
      [FrugaError(code: .timeout, message: "Bridge did not respond in time", recoverable: true)]
    )
    // Still logged, in addition to reaching onError (#79 wiring must not regress).
    XCTAssertEqual(logger.calls.map(\.event), ["error"])
  }
}

#endif
