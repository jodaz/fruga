#if canImport(UIKit) && canImport(WebKit)

import WebKit
import XCTest

@testable import FrugaRelayCore
@testable import FrugaRelay

/// RED tests for issue #79 (M2 batch 1): wiring `FrugaRelayViewController` to
/// `FrugaRelay.logger`. None of this wiring exists yet: `FrugaShellSession`
/// is constructed today with only `onError`, so `onMessage` (for `log` and
/// wiring `onDropped`) is not yet connected to anything.
///
/// Seam this test is written against (owner: name a different one under
/// Handoffs if this is wrong): `FrugaRelayViewController`'s `session` is
/// already internal-visible to `@testable import FrugaRelay` (see
/// `FrugaRelayViewControllerTests.swift`), so a test can call
/// `controller.session.receive(_:)` directly and observe `FrugaRelay.logger`
/// without a real WebView round trip. This requires the controller to wire
/// `session`'s `onMessage`/`onDropped`/`onError` to `FrugaRelay.logger` in
/// its own `init`, not only forward errors to the caller-supplied closure.
///
/// Written blind: this file only runs in the mirror's macOS job.
@MainActor
final class FrugaRelayLoggingTests: XCTestCase {
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

  private func makeController(onError: @escaping (FrugaError) -> Void = { _ in }) -> FrugaRelayViewController {
    let config = FrugaRelayConfig(
      partnerKey: "partner_test_123",
      tokenProvider: { _ in "eyJ.test" },
      options: FrugaRelayOptions()
    )
    let controller = FrugaRelayViewController(config: config, onError: onError)
    controller.loadsShellAutomatically = false
    return controller
  }

  // MARK: - 1. Every FrugaError passed to the controller's onError also
  //           reaches FrugaRelay.logger via error(_:).

  func testErrorsReachingOnErrorAlsoReachTheLogger() {
    let logger = RecordingLogger()
    FrugaRelay.logger = logger
    var reportedErrors: [FrugaError] = []
    let controller = makeController(onError: { reportedErrors.append($0) })

    controller.session.processDidTerminate() // reports PROCESS_TERMINATED via onError

    XCTAssertEqual(reportedErrors.map(\.code), [.processTerminated])
    XCTAssertEqual(logger.calls.map(\.event), ["error"])
    XCTAssertEqual(logger.calls.first?.data["code"], "PROCESS_TERMINATED")
  }

  // MARK: - 2. An inbound bridge `log` message is forwarded to the logger
  //           with its level/event/data.

  func testInboundLogMessageIsForwardedToTheLogger() throws {
    let logger = RecordingLogger()
    FrugaRelay.logger = logger
    let controller = makeController()

    controller.session.receive(try fixture("log.valid"))

    XCTAssertEqual(logger.calls.count, 1)
    XCTAssertEqual(logger.calls.first?.level, .info)
    XCTAssertEqual(logger.calls.first?.event, "widget_mounted")
  }

  // MARK: - 3. A dropped inbound message logs warn event "bridge.dropped"
  //           with data ["type": ...] only.

  func testDroppedMessageLogsBridgeDroppedWarning() throws {
    let logger = RecordingLogger()
    FrugaRelay.logger = logger
    let controller = makeController()

    controller.session.receive(try fixture("balance.invalid")) // missing "pending"

    XCTAssertEqual(logger.calls.count, 1)
    XCTAssertEqual(logger.calls.first?.level, .warn)
    XCTAssertEqual(logger.calls.first?.event, "bridge.dropped")
    XCTAssertEqual(logger.calls.first?.data, ["type": "balance"])
  }

  // MARK: - 4. RED for the sdk-reviewer's M2 batch 1 finding (F1): a
  //           navigation to a non-http(s) URL, and an `openExternal` for one,
  //           each log warn event "navigation.blocked" with data
  //           ["scheme": ...] only, and nothing is opened.

  func testHandleNavigationToNonHttpSchemeLogsNavigationBlockedAndDoesNotOpenExternally() {
    let logger = RecordingLogger()
    FrugaRelay.logger = logger
    let controller = makeController()
    var opened: [URL] = []
    controller.openExternally = { opened.append($0) }
    let telURL = URL(string: "tel:+441234")!

    let allow = controller.handleNavigation(to: telURL, isMainFrame: true)

    XCTAssertFalse(allow)
    XCTAssertTrue(opened.isEmpty)
    XCTAssertEqual(logger.calls.map(\.event), ["navigation.blocked"])
    XCTAssertEqual(logger.calls.first?.level, .warn)
    XCTAssertEqual(logger.calls.first?.data, ["scheme": "tel"])
  }

  func testOpenExternalWithNonHttpSchemeLogsNavigationBlockedAndDoesNotOpen() throws {
    let logger = RecordingLogger()
    FrugaRelay.logger = logger
    let controller = makeController()
    var opened: [URL] = []
    controller.openExternally = { opened.append($0) }
    let json = try JSONEncoder().encode(FrugaNativeMessage.openExternal(OpenExternalPayload(url: "tel:+441234")))

    controller.session.receive(json)

    XCTAssertTrue(opened.isEmpty)
    XCTAssertEqual(logger.calls.map(\.event), ["navigation.blocked"])
    XCTAssertEqual(logger.calls.first?.level, .warn)
    XCTAssertEqual(logger.calls.first?.data, ["scheme": "tel"])
  }

  // MARK: - 5. RED for the sdk-reviewer's M2 batch 1 finding (F8): an inbound
  //           `log` message whose data carries a URL with a `token`/
  //           `partnerKey` query value reaches the logger with both
  //           redacted, not just dropped by key name (built via
  //           JSONSerialization, not a hand-copied fixture: this varies the
  //           existing `log.valid` shape with a value the fixture does not
  //           carry).

  // MARK: - 6. RED for the sdk-reviewer's M2 review (iOS blocker): the two
  //           pre-presentation guards in `FrugaRelay.open(from:onError:)`
  //           (`FrugaRelay.swift:91-106`) call `onError` but never
  //           `FrugaRelay.logger.error(...)`, unlike every other error path in
  //           this file which goes through `FrugaRelayViewController`'s
  //           `report` closure (`FrugaRelayViewController.swift`, "Every error
  //           the partner is told about is also logged, once (#79)"). No
  //           `FrugaRelayViewController` is ever constructed on either guard
  //           path, so nothing calls `FrugaRelay.logger.error(...)` for them.

  private func makeWindowRootedController() -> UIViewController {
    let controller = UIViewController()
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = controller
    window.makeKeyAndVisible()
    return controller
  }

  func testOpenBeforeConfigureReportsBootstrapFailedToTheLogger() {
    // RED at FrugaRelay.swift:92 `onError(...)`: the `guard let config else`
    // branch returns without calling `FrugaRelay.logger.error(...)`, so
    // `logger.calls` stays empty and this assertion fails.
    let logger = RecordingLogger()
    FrugaRelay.logger = logger
    let presenter = makeWindowRootedController()
    var reportedErrors: [FrugaError] = []

    FrugaRelay.open(from: presenter, onError: { reportedErrors.append($0) })

    XCTAssertEqual(reportedErrors.map(\.code), [.bootstrapFailed])
    XCTAssertEqual(logger.calls.map(\.event), ["error"])
    XCTAssertEqual(logger.calls.first?.data["code"], "BOOTSTRAP_FAILED")
  }

  func testOpenWhileOfflineReportsOfflineToTheLogger() {
    // RED at FrugaRelay.swift:104 `onError(...)`: the `guard isOnline` branch
    // returns without calling `FrugaRelay.logger.error(...)`, so
    // `logger.calls` stays empty and this assertion fails.
    let logger = RecordingLogger()
    FrugaRelay.logger = logger
    let presenter = makeWindowRootedController()
    FrugaRelay.configure(partnerKey: "partner_test_123", tokenProvider: { _ in "eyJ.test" }, options: FrugaRelayOptions())
    FrugaRelay.isOnline = false
    var reportedErrors: [FrugaError] = []

    FrugaRelay.open(from: presenter, onError: { reportedErrors.append($0) })

    XCTAssertEqual(reportedErrors.map(\.code), [.offline])
    XCTAssertEqual(logger.calls.map(\.event), ["error"])
    XCTAssertEqual(logger.calls.first?.data["code"], "OFFLINE")
  }

  func testInboundLogMessageWithASecretQueryValueReachesTheLoggerRedacted() throws {
    let logger = RecordingLogger()
    FrugaRelay.logger = logger
    let controller = makeController()
    let json = try JSONSerialization.data(withJSONObject: [
      "type": "log",
      "level": "info",
      "event": "widget_mounted",
      "data": ["url": "https://x/?token=abc&partnerKey=pk"]
    ])

    controller.session.receive(json)

    XCTAssertEqual(logger.calls.count, 1)
    XCTAssertEqual(logger.calls.first?.data["url"], "https://x/?token=<redacted>&partnerKey=<redacted>")
  }
}

#endif
