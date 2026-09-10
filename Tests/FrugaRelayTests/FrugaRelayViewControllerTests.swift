#if canImport(UIKit) && canImport(WebKit)

import WebKit
import XCTest

import FrugaRelayCore
@testable import FrugaRelay

/// RED tests for issue #76 (M2-I04): presentation and swipe-back. Contract
/// (not yet implemented — this file is meant to fail to compile until
/// `ios-owner` adds `FrugaRelayViewController` and the `FrugaRelay.open`/
/// `close` facade to the `FrugaRelay` target):
///
/// ```swift
/// public final class FrugaRelayViewController: UIViewController {
///   public init(initPayload: InitPayload, onError: @escaping (FrugaError) -> Void)
///   var webView: WKWebView { get }      // internal, for tests
///   var session: FrugaShellSession { get }  // internal, for tests
/// }
///
/// public enum FrugaRelay {
///   public static func open(
///     from presenter: UIViewController,
///     initPayload: InitPayload,
///     onError: @escaping (FrugaError) -> Void
///   )
///   public static func close()
/// }
/// ```
///
/// Presented full screen (`.fullScreen` — "full screen relay" in the spec,
/// not `.pageSheet`) with a `presentationController?.delegate` set for the
/// swipe-down-to-dismiss hook.
///
/// This test target's `FrugaRelayTests` build target currently depends only
/// on `FrugaRelay`, not `FrugaRelayCore` (see Package.swift) — a seam gap
/// this file's `import FrugaRelayCore` needs closed; see the report Handoffs.
///
/// UIKit/WebKit are unavailable on Linux, so this whole file is compiled out
/// there — it only runs in the mirror's macos-15 CI job.
@MainActor
final class FrugaRelayViewControllerTests: XCTestCase {
  private func makeInitPayload() -> InitPayload {
    InitPayload(
      partnerKey: "partner_test_123",
      token: nil,
      theme: nil,
      primaryColor: nil,
      userId: nil,
      apiBaseUrl: nil,
      locale: nil,
      safeArea: SafeArea(top: 0, right: 0, bottom: 0, left: 0),
      debug: false
    )
  }

  private func makeWindowRootedController() -> UIViewController {
    let controller = UIViewController()
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = controller
    window.makeKeyAndVisible()
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
    let viewController = FrugaRelayViewController(initPayload: makeInitPayload(), onError: { _ in })

    viewController.loadViewIfNeeded()

    XCTAssertTrue(viewController.webView.isDescendant(of: viewController.view))
  }

  func testWebViewLoadsTheCdnShellUrl() async throws {
    let viewController = FrugaRelayViewController(initPayload: makeInitPayload(), onError: { _ in })

    viewController.loadViewIfNeeded()

    XCTAssertNotNil(viewController.webView.navigationDelegate)
    let url = try XCTUnwrap(viewController.webView.url?.absoluteString)
    XCTAssertTrue(url.hasPrefix("https://cdn.fruga.co.uk/v/\(FrugaRelayVersion.shell)/native/"))
  }

  // MARK: - FrugaRelay.open(from:) presents full screen with swipe-back wired.

  func testOpenPresentsFullScreenWithSwipeBackDelegate() async throws {
    let presenter = makeWindowRootedController()

    FrugaRelay.open(from: presenter, initPayload: makeInitPayload(), onError: { _ in })

    let presented = try await waitUntilPresented(by: presenter)
    XCTAssertTrue(presented is FrugaRelayViewController)
    XCTAssertEqual(presented.modalPresentationStyle, .fullScreen)
    XCTAssertNotNil(presented.presentationController?.delegate)

    FrugaRelay.close()
    try await waitUntilDismissed(from: presenter)
  }

  // MARK: - FrugaRelay.close() dismisses the presented controller.

  func testCloseDismissesThePresentedController() async throws {
    let presenter = makeWindowRootedController()
    FrugaRelay.open(from: presenter, initPayload: makeInitPayload(), onError: { _ in })
    _ = try await waitUntilPresented(by: presenter)

    FrugaRelay.close()

    try await waitUntilDismissed(from: presenter)
    XCTAssertNil(presenter.presentedViewController)
  }
}

#endif
