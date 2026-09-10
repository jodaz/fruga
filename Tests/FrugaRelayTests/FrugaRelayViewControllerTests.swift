#if canImport(UIKit) && canImport(WebKit)

import WebKit
import XCTest

import FrugaRelayCore
@testable import FrugaRelay

/// RED tests for issue #76 (M2-I04), covering the sdk-reviewer blockers on
/// the first pass: `.pageSheet` presentation (blocker 1, `.fullScreen` never
/// calls `presentationControllerShouldDismiss`), the dismiss decision
/// (blocker 2), the `FrugaRelayOptions`-based facade with `InitPayload` kept
/// out of the public surface (blocker 4), and `tokenRequired` wired to
/// `FrugaTokenCoordinator` (blocker 5). Contract (not yet implemented — this
/// file is meant to fail to compile until `ios-owner` adds it):
///
/// ```swift
/// public final class FrugaRelayViewController: UIViewController {
///   init(config: FrugaRelayConfig, onError: @escaping (FrugaError) -> Void)
///   var webView: WKWebView { get }       // internal, for tests
///   var session: FrugaShellSession { get }  // internal, for tests
/// }
///
/// public enum FrugaRelay {
///   public static func configure(
///     partnerKey: String,
///     tokenProvider: @escaping FrugaTokenProvider,
///     options: FrugaRelayOptions = FrugaRelayOptions()
///   )
///   public static func open(from presenter: UIViewController, onError: @escaping (FrugaError) -> Void)
///     // open before configure: onError(.bootstrapFailed), presents nothing
///   public static func close()
///   static func reset()   // test-only: clears configure/open state between tests
/// }
/// ```
///
/// Presented as `.pageSheet` with `presentationController?.delegate` wired
/// for the swipe-down-to-dismiss hook that asks the shell first via
/// `session.requestBack` and dismisses only when the shell reports the
/// gesture unhandled.
///
/// UIKit/WebKit are unavailable on Linux, so this whole file is compiled out
/// there — it only runs in the mirror's macos-15 CI job.
@MainActor
final class FrugaRelayViewControllerTests: XCTestCase {
  /// Retained for the lifetime of the test: an unretained `UIWindow` is torn
  /// down by UIKit during an `await`/`sleep` in the host-less xctest process
  /// (no `UIApplication`), which made dismissal assertions pass vacuously.
  private var window: UIWindow?

  override func tearDown() {
    FrugaRelay.close()
    FrugaRelay.reset()
    window?.isHidden = true
    window = nil
    super.tearDown()
  }

  private func makeConfig(tokenProvider: @escaping FrugaTokenProvider = { _ in "eyJ.test" }) -> FrugaRelayConfig {
    FrugaRelayConfig(
      partnerKey: "partner_test_123",
      tokenProvider: tokenProvider,
      options: FrugaRelayOptions()
    )
  }

  private func makeWindowRootedController() -> UIViewController {
    let controller = UIViewController()
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = controller
    window.makeKeyAndVisible()
    self.window = window
    return controller
  }

  private func waitUntilPresented(by presenter: UIViewController) async throws -> UIViewController {
    let deadline = Date().addingTimeInterval(2.0)
    while presenter.presentedViewController == nil, Date() < deadline {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    return try XCTUnwrap(presenter.presentedViewController)
  }

  private func waitUntilDismissed(from presenter: UIViewController) async throws {
    let deadline = Date().addingTimeInterval(2.0)
    while presenter.presentedViewController != nil, Date() < deadline {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
  }

  // MARK: - The WebView is mounted and loads the CDN shell.

  func testWebViewIsAddedAsSubview() async throws {
    let viewController = FrugaRelayViewController(config: makeConfig(), onError: { _ in })

    viewController.loadViewIfNeeded()

    XCTAssertTrue(viewController.webView.isDescendant(of: viewController.view))
  }

  func testWebViewLoadsTheCdnShellUrl() async throws {
    let viewController = FrugaRelayViewController(config: makeConfig(), onError: { _ in })

    viewController.loadViewIfNeeded()

    XCTAssertNotNil(viewController.webView.navigationDelegate)
    let url = try XCTUnwrap(viewController.webView.url?.absoluteString)
    XCTAssertTrue(url.hasPrefix("https://cdn.fruga.co.uk/v/\(FrugaRelayVersion.shell)/native/"))
  }

  // MARK: - FrugaRelay.open(from:) presents as a page sheet with swipe-back
  //        wired (blocker 1).

  func testOpenPresentsAsPageSheetWithSwipeBackDelegate() async throws {
    let presenter = makeWindowRootedController()
    FrugaRelay.configure(partnerKey: "partner_test_123", tokenProvider: { _ in "eyJ.test" }, options: FrugaRelayOptions())

    FrugaRelay.open(from: presenter, onError: { _ in })

    let presented = try await waitUntilPresented(by: presenter)
    XCTAssertTrue(presented is FrugaRelayViewController)
    XCTAssertEqual(presented.modalPresentationStyle, .pageSheet)
    XCTAssertNotNil(presented.presentationController?.delegate)

    FrugaRelay.close()
    try await waitUntilDismissed(from: presenter)
  }

  // MARK: - FrugaRelay.close() dismisses the presented controller.

  func testCloseDismissesThePresentedController() async throws {
    let presenter = makeWindowRootedController()
    FrugaRelay.configure(partnerKey: "partner_test_123", tokenProvider: { _ in "eyJ.test" }, options: FrugaRelayOptions())
    FrugaRelay.open(from: presenter, onError: { _ in })
    _ = try await waitUntilPresented(by: presenter)

    FrugaRelay.close()

    try await waitUntilDismissed(from: presenter)
    XCTAssertNil(presenter.presentedViewController)
  }

  // MARK: - open(from:) before configure(...) fails with BOOTSTRAP_FAILED and
  //        presents nothing (blocker 4: the facade owns configuration state,
  //        InitPayload never reaches the caller).

  func testOpenBeforeConfigureFailsWithBootstrapFailedAndPresentsNothing() async throws {
    let presenter = makeWindowRootedController()
    var errors: [FrugaError] = []

    FrugaRelay.open(from: presenter, onError: { errors.append($0) })

    XCTAssertEqual(errors.map(\.code), [.bootstrapFailed])
    XCTAssertNil(presenter.presentedViewController)
  }

  // MARK: - Swipe-down / sheet-pull never dismisses directly: it asks the
  //        shell first and returns false (blocker 2).

  func testDismissDecisionAsksTheShellAndReturnsFalse() async throws {
    let presenter = makeWindowRootedController()
    let controller = FrugaRelayViewController(config: makeConfig(), onError: { _ in })
    presenter.present(controller, animated: false)
    controller.presentationController?.delegate = controller
    _ = try await waitUntilPresented(by: presenter)

    let shouldDismiss = controller.presentationControllerShouldDismiss(try XCTUnwrap(controller.presentationController))

    XCTAssertFalse(shouldDismiss)
  }

  // MARK: - The shell reporting the back gesture handled keeps Relay open.

  func testDismissDecisionStaysPresentedWhenShellReportsHandled() async throws {
    let presenter = makeWindowRootedController()
    let controller = FrugaRelayViewController(config: makeConfig(), onError: { _ in })
    presenter.present(controller, animated: false)
    controller.presentationController?.delegate = controller
    _ = try await waitUntilPresented(by: presenter)

    _ = controller.presentationControllerShouldDismiss(try XCTUnwrap(controller.presentationController))
    controller.session.receive(try JSONEncoder().encode(FrugaNativeMessage.backResult(BackResultPayload(handled: true))))
    try await Task.sleep(nanoseconds: 500_000_000)

    XCTAssertNotNil(presenter.presentedViewController)
  }

  // MARK: - The shell reporting the back gesture unhandled dismisses Relay.

  func testDismissDecisionDismissesWhenShellReportsUnhandled() async throws {
    let presenter = makeWindowRootedController()
    let controller = FrugaRelayViewController(config: makeConfig(), onError: { _ in })
    presenter.present(controller, animated: false)
    controller.presentationController?.delegate = controller
    _ = try await waitUntilPresented(by: presenter)

    _ = controller.presentationControllerShouldDismiss(try XCTUnwrap(controller.presentationController))
    XCTAssertNotNil(presenter.presentedViewController, "still presented before the shell reports the gesture unhandled")

    controller.session.receive(try JSONEncoder().encode(FrugaNativeMessage.backResult(BackResultPayload(handled: false))))

    try await waitUntilDismissed(from: presenter)
    XCTAssertNil(presenter.presentedViewController, "dismissed within 2s of the shell reporting unhandled")
  }

  // MARK: - A wedged shell (no backResult at all) still dismisses, once
  //        `requestBack`'s default 1 s timeout resolves to unhandled.

  func testDismissDecisionDismissesAfterTimeoutWithNoBackResult() async throws {
    let presenter = makeWindowRootedController()
    let controller = FrugaRelayViewController(config: makeConfig(), onError: { _ in })
    presenter.present(controller, animated: false)
    controller.presentationController?.delegate = controller
    _ = try await waitUntilPresented(by: presenter)

    _ = controller.presentationControllerShouldDismiss(try XCTUnwrap(controller.presentationController))

    try await Task.sleep(nanoseconds: 500_000_000)
    XCTAssertNotNil(presenter.presentedViewController, "still presented at 0.5s, before the 1s requestBack timeout")

    let deadline = Date().addingTimeInterval(2.5)
    while presenter.presentedViewController != nil, Date() < deadline {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertNil(presenter.presentedViewController, "dismissed by 2.5s once requestBack's timeout resolves to unhandled")
  }

  // MARK: - tokenRequired is wired to FrugaTokenCoordinator (blocker 5): the
  //        provider is called with the shell's reason.

  func testTokenRequiredCallsProviderWithReason() async throws {
    let presenter = makeWindowRootedController()
    let recorder = RecordingTokenProvider()
    let controller = FrugaRelayViewController(
      config: makeConfig(tokenProvider: { reason in await recorder.provide(reason) }),
      onError: { _ in }
    )
    presenter.present(controller, animated: false)
    _ = try await waitUntilPresented(by: presenter)

    controller.session.receive(
      try JSONEncoder().encode(FrugaNativeMessage.tokenRequired(TokenRequiredPayload(reason: .initial)))
    )

    let deadline = Date().addingTimeInterval(2.0)
    while await recorder.reasons.isEmpty, Date() < deadline {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    let reasons = await recorder.reasons
    XCTAssertEqual(reasons, [.initial])
  }
}

// MARK: - Test double

/// Records the reasons a `FrugaTokenProvider` closure was called with.
private actor RecordingTokenProvider {
  private(set) var reasons: [TokenRequiredPayload.Reason] = []

  func provide(_ reason: TokenRequiredPayload.Reason) -> String {
    reasons.append(reason)
    return "eyJ.recorded"
  }
}

#endif
