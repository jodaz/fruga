#if canImport(UIKit) && canImport(WebKit)

import XCTest

@testable import FrugaRelayCore
@testable import FrugaRelay

/// RED tests for issue #79 (M2 batch 1): `FrugaRelay.logger` on the UIKit
/// facade, mirroring Android's `FrugaLoggerTest` (`FrugaRelay logger default
/// is non-null` / `is replaceable` / `reset restores the default logger`).
/// Contract (not yet implemented):
///
/// ```swift
/// extension FrugaRelay {
///   @MainActor public static var logger: FrugaLogger { get set }  // default: OSLogLogger,
///     // subsystem "uk.co.fruga.relay", category "FrugaRelay", behind
///     // #if canImport(os) so FrugaRelayCore stays Linux-buildable
///   @MainActor static func reset()  // also restores the default logger
/// }
/// ```
///
/// Written blind: this file only runs in the mirror's macOS job.
@MainActor
final class FrugaRelayLoggerTests: XCTestCase {
  override func tearDown() {
    FrugaRelay.reset()
    super.tearDown()
  }

  func testLoggerDefaultIsNonNil() {
    XCTAssertNotNil(FrugaRelay.logger)
  }

  func testLoggerIsReplaceable() {
    let custom = RecordingLogger()

    FrugaRelay.logger = custom

    XCTAssertTrue(FrugaRelay.logger as? RecordingLogger === custom)
  }

  func testResetRestoresTheDefaultLogger() {
    let custom = RecordingLogger()
    FrugaRelay.logger = custom
    XCTAssertTrue(FrugaRelay.logger as? RecordingLogger === custom)

    FrugaRelay.reset()

    XCTAssertFalse(FrugaRelay.logger as? RecordingLogger === custom)
  }

  // MARK: - RED for the sdk-reviewer's M2 batch 1 finding (F7): `reset()`
  //         must also turn debug logging back off. `defaultLogger` is a
  //         single `OSLogLogger` instance reused across configure/reset
  //         cycles, so `configure(options: .init(debug: true))` mutates its
  //         `isDebugEnabled` in place and `reset()` (which just reassigns
  //         `logger = defaultLogger`, the same instance) never clears it.
  //         Seam: the existing internal `OSLogLogger.isDebugEnabled`,
  //         already visible to this `@testable import FrugaRelay` file — no
  //         new API needed.

  func testResetDisablesDebugLoggingLeftOnByConfigure() {
    FrugaRelay.configure(
      partnerKey: "partner_test_123",
      tokenProvider: { _ in "eyJ.test" },
      options: FrugaRelayOptions(debug: true)
    )
    XCTAssertEqual((FrugaRelay.logger as? OSLogLogger)?.isDebugEnabled, true)

    FrugaRelay.reset()

    XCTAssertEqual((FrugaRelay.logger as? OSLogLogger)?.isDebugEnabled, false)
  }

  // MARK: - RED for the ios mirror CI leak (root cause A, sdk-debugger
  //         2026-09-21): `FrugaRelay.isOnline` is process-global static state
  //         that `reset()` does not restore, so a test that sets it `false`
  //         (`FrugaRelayLoggingTests.testOpenWhileOfflineReportsOfflineToTheLogger`)
  //         leaks it to every later `open(from:)` test, alphabetically after
  //         this class. `reset()` must restore `isOnline = true`.

  func testResetRestoresOnlineState() {
    FrugaRelay.isOnline = false
    // Guarantee the leak cannot cascade even if this assertion fails.
    addTeardownBlock { FrugaRelay.isOnline = true }

    FrugaRelay.reset()

    XCTAssertTrue(FrugaRelay.isOnline)
  }
}

// MARK: - Test double

final class RecordingLogger: FrugaLogger {
  private(set) var calls: [(level: LogPayload.Level, event: String, data: [String: String])] = []

  func log(level: LogPayload.Level, event: String, data: [String: String]) {
    calls.append((level, event, data))
  }
}

#endif
