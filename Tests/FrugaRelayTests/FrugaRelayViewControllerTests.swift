#if canImport(UIKit) && canImport(WebKit)

import WebKit
import XCTest

@testable import FrugaRelayCore
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

  private func makeViewController(
    config: FrugaRelayConfig,
    onError: @escaping (FrugaError) -> Void
  ) -> FrugaRelayViewController {
    FrugaRelayViewController(config: config, onError: onError)
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

  /// Embeds `controller` as a child of a retained window's root controller,
  /// rather than presenting it, so UIKit propagates safe-area layout to a
  /// controller whose view was never attached to a window otherwise.
  private func mountInWindow(_ controller: UIViewController) {
    let root = UIViewController()
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = root
    window.makeKeyAndVisible()
    self.window = window

    root.addChild(controller)
    root.view.addSubview(controller.view)
    controller.didMove(toParent: root)
  }

  // MARK: - The WebView is mounted and loads the CDN shell.

  func testWebViewIsAddedAsSubview() async throws {
    let viewController = makeViewController(config: makeConfig(), onError: { _ in })
    viewController.loadsShellAutomatically = false

    viewController.loadViewIfNeeded()

    XCTAssertTrue(viewController.webView.isDescendant(of: viewController.view))
  }

  func testWebViewLoadsTheCdnShellUrl() async throws {
    let viewController = makeViewController(config: makeConfig(), onError: { _ in })

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
    // The delegate wiring itself is asserted deterministically by
    // `testSwipeBackDelegateIsWiredByTheControllerItself`, which drives
    // `viewWillAppear` directly; it is wired in `viewWillAppear`, which a
    // host-less xctest process does not reliably call on its own timeline.

    FrugaRelay.close()
    try await waitUntilDismissed(from: presenter)
  }

  // MARK: - FrugaRelay.close() dismisses the presented controller.

  func testCloseDismissesThePresentedController() async throws {
    let presenter = makeWindowRootedController()
    FrugaRelay.configure(partnerKey: "partner_test_123", tokenProvider: { _ in "eyJ.test" }, options: FrugaRelayOptions())
    FrugaRelay.open(from: presenter, onError: { _ in })
    _ = try await waitUntilPresented(by: presenter)
    var dismissed = 0
    FrugaRelay.presentedController?.dismissHandler = { dismissed += 1 }

    FrugaRelay.close()

    XCTAssertEqual(dismissed, 1)
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
    let controller = makeViewController(config: makeConfig(), onError: { _ in })
    controller.loadsShellAutomatically = false
    presenter.present(controller, animated: false)
    controller.presentationController?.delegate = controller
    _ = try await waitUntilPresented(by: presenter)

    let shouldDismiss = controller.presentationControllerShouldDismiss(try XCTUnwrap(controller.presentationController))

    XCTAssertFalse(shouldDismiss)
  }

  // MARK: - The shell reporting the back gesture handled keeps Relay open.

  func testDismissDecisionStaysPresentedWhenShellReportsHandled() async throws {
    let presenter = makeWindowRootedController()
    let controller = makeViewController(config: makeConfig(), onError: { _ in })
    controller.loadsShellAutomatically = false
    presenter.present(controller, animated: false)
    controller.presentationController?.delegate = controller
    _ = try await waitUntilPresented(by: presenter)
    var dismissed = 0
    controller.dismissHandler = { dismissed += 1 }

    _ = controller.presentationControllerShouldDismiss(try XCTUnwrap(controller.presentationController))
    controller.session.receive(try JSONEncoder().encode(FrugaNativeMessage.backResult(BackResultPayload(handled: true))))
    try await Task.sleep(nanoseconds: 500_000_000)

    XCTAssertNotNil(presenter.presentedViewController)
    XCTAssertEqual(dismissed, 0)
  }

  // MARK: - The shell reporting the back gesture unhandled dismisses Relay.

  func testDismissDecisionDismissesWhenShellReportsUnhandled() async throws {
    let presenter = makeWindowRootedController()
    let controller = makeViewController(config: makeConfig(), onError: { _ in })
    controller.loadsShellAutomatically = false
    presenter.present(controller, animated: false)
    controller.presentationController?.delegate = controller
    _ = try await waitUntilPresented(by: presenter)
    var dismissed = 0
    controller.dismissHandler = { dismissed += 1 }

    _ = controller.presentationControllerShouldDismiss(try XCTUnwrap(controller.presentationController))
    XCTAssertEqual(dismissed, 0, "not dismissed before the shell reports the gesture unhandled")

    controller.session.receive(try JSONEncoder().encode(FrugaNativeMessage.backResult(BackResultPayload(handled: false))))

    let deadline = Date().addingTimeInterval(2.0)
    while dismissed == 0, Date() < deadline {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertEqual(dismissed, 1, "dismissed within 2s of the shell reporting unhandled")
  }

  // MARK: - A wedged shell (no backResult at all) still dismisses, once
  //        `requestBack`'s default 1 s timeout resolves to unhandled.

  func testDismissDecisionDismissesAfterTimeoutWithNoBackResult() async throws {
    let presenter = makeWindowRootedController()
    let controller = makeViewController(config: makeConfig(), onError: { _ in })
    controller.loadsShellAutomatically = false
    presenter.present(controller, animated: false)
    controller.presentationController?.delegate = controller
    _ = try await waitUntilPresented(by: presenter)
    var dismissed = 0
    controller.dismissHandler = { dismissed += 1 }

    _ = controller.presentationControllerShouldDismiss(try XCTUnwrap(controller.presentationController))

    try await Task.sleep(nanoseconds: 500_000_000)
    XCTAssertEqual(dismissed, 0, "not dismissed at 0.5s, before the 1s requestBack timeout")

    let deadline = Date().addingTimeInterval(2.5)
    while dismissed == 0, Date() < deadline {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertEqual(dismissed, 1, "dismissed by 2.5s once requestBack's timeout resolves to unhandled")
  }

  // MARK: - tokenRequired is wired to FrugaTokenCoordinator (blocker 5): the
  //        provider is called with the shell's reason.

  func testTokenRequiredCallsProviderWithReason() async throws {
    let presenter = makeWindowRootedController()
    let recorder = RecordingTokenProvider()
    let controller = makeViewController(
      config: makeConfig(tokenProvider: { reason in await recorder.provide(reason) }),
      onError: { _ in }
    )
    controller.loadsShellAutomatically = false
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

  // MARK: - RED for issue #78 (M2-I06). Additional contract on top of the
  // block above (not yet implemented):
  //
  // ```swift
  // public final class FrugaRelayViewController: UIViewController {
  //   var lastInitPayload: InitPayload? { get }   // internal, for tests
  //   func currentSafeArea() -> SafeArea            // internal (was private), for tests
  // }
  //
  // public enum FrugaRelay {
  //   public static func open(from presenter: UIViewController, onError: @escaping (FrugaError) -> Void)
  //     // a second open() while one is already presented is a no-op: the
  //     // existing controller stays presented, no second present(), no error
  // }
  // ```
  //
  // Swipe-back delegate wiring moves from `FrugaRelay.open` into the
  // controller itself (`viewWillAppear` or `init`), per the #76 review.

  // MARK: - The InitPayload the session started with carries the safe area
  //        measured at load, not a hardcoded value.

  func testInitPayloadCarriesSafeAreaMeasuredAtLoad() async throws {
    // `lastInitPayload` is composed in `viewDidLayoutSubviews`, which a
    // presented-but-detached controller never runs in a host-less xctest
    // process; `loadsShellAutomatically = false` skips the CDN fetch so the
    // layout pass below is what drives the payload, not a network mount.
    let viewController = makeViewController(config: makeConfig(), onError: { _ in })
    viewController.loadsShellAutomatically = false
    mountInWindow(viewController)
    viewController.additionalSafeAreaInsets = UIEdgeInsets(top: 10, left: 0, bottom: 20, right: 0)
    window?.layoutIfNeeded()

    let payload = try XCTUnwrap(viewController.lastInitPayload)

    XCTAssertEqual(payload.safeArea, viewController.currentSafeArea())
    XCTAssertNotEqual(payload.safeArea, SafeArea(top: 0, right: 0, bottom: 0, left: 0))
  }

  // MARK: - additionalSafeAreaInsets set before layout are reflected by
  //        currentSafeArea() (not zeros).

  func testCurrentSafeAreaReflectsAdditionalSafeAreaInsets() async throws {
    // A detached view never receives safe-area propagation from UIKit, so
    // the controller is mounted in the retained test window as a child of
    // its root controller; `loadsShellAutomatically = false` skips the CDN
    // fetch this test does not care about.
    let viewController = makeViewController(config: makeConfig(), onError: { _ in })
    viewController.loadsShellAutomatically = false
    mountInWindow(viewController)
    window?.layoutIfNeeded()
    let baseline = viewController.currentSafeArea()

    viewController.additionalSafeAreaInsets = UIEdgeInsets(top: 10, left: 0, bottom: 20, right: 0)
    window?.layoutIfNeeded()

    let safeArea = viewController.currentSafeArea()

    XCTAssertEqual(safeArea.top, baseline.top + 10)
    XCTAssertEqual(safeArea.bottom, baseline.bottom + 20)
  }

  // MARK: - The swipe-back delegate is wired by the controller itself, not
  //        only by FrugaRelay.open (sdk-reviewer follow-up from #76/#77).

  func testSwipeBackDelegateIsWiredByTheControllerItself() async throws {
    let presenter = makeWindowRootedController()
    let controller = makeViewController(config: makeConfig(), onError: { _ in })

    presenter.present(controller, animated: false)
    _ = try await waitUntilPresented(by: presenter)
    // The delegate is wired in `viewWillAppear`, which UIKit drives during a
    // real presentation transition in an app; a host-less xctest process
    // never runs that transition, so it is called directly here.
    controller.viewWillAppear(false)

    XCTAssertTrue(controller.presentationController?.delegate === controller)
  }

  // MARK: - Calling FrugaRelay.open(from:) twice presents once: the second
  //        call is a no-op while a screen is already up.

  func testDoubleOpenPresentsOnce() async throws {
    let presenter = makeWindowRootedController()
    FrugaRelay.configure(partnerKey: "partner_test_123", tokenProvider: { _ in "eyJ.test" }, options: FrugaRelayOptions())
    var errors: [FrugaError] = []

    FrugaRelay.open(from: presenter, onError: { errors.append($0) })
    let first = try await waitUntilPresented(by: presenter)
    FrugaRelay.open(from: presenter, onError: { errors.append($0) })
    try await Task.sleep(nanoseconds: 200_000_000)

    XCTAssertTrue(FrugaRelay.presentedController === first, "the first controller stays presented")
    XCTAssertTrue(errors.isEmpty)

    FrugaRelay.close()
    try await waitUntilDismissed(from: presenter)
  }

  // MARK: - RED (sdk-reviewer should-fix 2, #78): the shell can finish
  //        loading before the first layout pass registers the `init`
  //        message with the session (`viewDidLoad` starts the load;
  //        `viewDidLayoutSubviews` is the only place `session.start` is
  //        called). A `didFinish` that beats layout must not leave the
  //        screen blank.

  func testShellDidLoadSendsInitEvenBeforeTheFirstLayoutPass() async throws {
    let viewController = makeViewController(config: makeConfig(), onError: { _ in })
    viewController.loadsShellAutomatically = false

    // No layout pass and no window: only `viewDidLoad` runs.
    viewController.loadViewIfNeeded()
    viewController.session.shellDidLoad()

    XCTAssertNotNil(
      viewController.session.lastSent,
      "an init message must already be registered with the session by the time the shell can report shellDidLoad(), not only after the first layout pass"
    )
  }

  // MARK: - RED (sdk-reviewer should-fix 6 coverage, #78): a shell-initiated
  //        `openExternal` with a non-http(s) scheme must be dropped, not
  //        handed to openExternally. `handleNavigation`'s own gate is already
  //        covered by `testNonHttpSchemeNavigationIsDroppedNotOpenedExternally`
  //        in FrugaRelayLifecycleTests; this covers the `session.onOpenExternal`
  //        path the shell drives directly.

  func testOpenExternalWithNonHttpSchemeIsDroppedNotOpenedExternally() async throws {
    let controller = makeViewController(config: makeConfig(), onError: { _ in })
    var opened: [URL] = []
    controller.openExternally = { opened.append($0) }

    controller.session.receive(
      Data(#"{"type":"openExternal","url":"tel:+441234567890"}"#.utf8)
    )

    XCTAssertTrue(opened.isEmpty, "a non-http(s) scheme reaching openExternal must be dropped, not handed to openExternally")
  }

  // MARK: - RED/coverage (sdk-reviewer should-fix 7, #78): a `backResult`
  //        arriving after the controller has already been dismissed must not
  //        call the dismiss handler again (the `presentingViewController`
  //        guard at the end of `presentationControllerShouldDismiss`).

  func testLateBackResultAfterDismissalDoesNotDismissAgain() async throws {
    let presenter = makeWindowRootedController()
    let controller = makeViewController(config: makeConfig(), onError: { _ in })
    controller.loadsShellAutomatically = false
    presenter.present(controller, animated: false)
    controller.presentationController?.delegate = controller
    _ = try await waitUntilPresented(by: presenter)

    // Arm a pending back request, then let the controller be dismissed by
    // another path before the shell answers.
    _ = controller.presentationControllerShouldDismiss(try XCTUnwrap(controller.presentationController))
    presenter.dismiss(animated: false)
    try await waitUntilDismissed(from: presenter)

    var dismissed = 0
    controller.dismissHandler = { dismissed += 1 }

    controller.session.receive(
      try JSONEncoder().encode(FrugaNativeMessage.backResult(BackResultPayload(handled: false)))
    )
    try await Task.sleep(nanoseconds: 500_000_000)

    XCTAssertEqual(
      dismissed,
      0,
      "a backResult arriving after the controller was already dismissed must not call the dismiss handler again"
    )
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
