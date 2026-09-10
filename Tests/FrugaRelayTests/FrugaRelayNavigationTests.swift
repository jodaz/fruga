#if canImport(UIKit) && canImport(WebKit)

import WebKit
import XCTest

import FrugaRelayCore
@testable import FrugaRelay

/// RED tests for issue #77 (M2-I05, navigation allowlist). Contract (not yet
/// implemented):
///
/// ```swift
/// public final class FrugaRelayViewController: UIViewController {
///   var policy: FrugaNavigationPolicy { get }   // internal, for tests
///   var openExternally: (URL) -> Void            // internal, settable, for
///     // tests; default opens SFSafariViewController over the controller, or
///     // UIApplication.open when not presented
///   func handleNavigation(to url: URL, isMainFrame: Bool) -> Bool
///     // true = allow the WebView to load; false = the policy said
///     // `.openExternally`, `openExternally` was called with the URL, and the
///     // WebView must not load it
/// }
/// ```
///
/// The navigation delegate calls this seam from
/// `webView(_:decidePolicyFor:decisionHandler:)` — not exercised directly
/// here because a `WKNavigationAction` is not constructible in tests; the
/// seam is.
///
/// UIKit/WebKit are unavailable on Linux, so this whole file is compiled out
/// there — it only runs in the mirror's macos-15 CI job.
@MainActor
final class FrugaRelayNavigationTests: XCTestCase {
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

  // MARK: - The controller's policy is FrugaNavigationPolicy.standard, wired
  //         from the init payload's apiBaseUrl.

  func testControllerPolicyIsStandardForTheInitPayload() {
    let viewController = FrugaRelayViewController(initPayload: makeInitPayload(), onError: { _ in })

    XCTAssertEqual(viewController.policy, FrugaNavigationPolicy.standard(apiBaseUrl: nil))
  }

  // MARK: - Allowed navigation loads in the WebView; openExternally is not called.

  func testAllowedNavigationReturnsTrueAndDoesNotOpenExternally() {
    let viewController = FrugaRelayViewController(initPayload: makeInitPayload(), onError: { _ in })
    var opened: [URL] = []
    viewController.openExternally = { opened.append($0) }
    let cdnURL = URL(string: "https://cdn.fruga.co.uk/v/\(FrugaRelayVersion.shell)/native/index.html")!

    let allow = viewController.handleNavigation(to: cdnURL, isMainFrame: true)

    XCTAssertTrue(allow)
    XCTAssertTrue(opened.isEmpty)
  }

  // MARK: - Disallowed main-frame navigation opens externally and denies the load.

  func testDisallowedMainFrameNavigationOpensExternallyAndReturnsFalse() {
    let viewController = FrugaRelayViewController(initPayload: makeInitPayload(), onError: { _ in })
    var opened: [URL] = []
    viewController.openExternally = { opened.append($0) }
    let evilURL = URL(string: "https://evil.example.com")!

    let allow = viewController.handleNavigation(to: evilURL, isMainFrame: true)

    XCTAssertFalse(allow)
    XCTAssertEqual(opened, [evilURL])
  }

  // MARK: - Subframe/subresource navigation is always allowed, regardless of origin.

  func testSubframeNavigationIsAlwaysAllowedAndDoesNotOpenExternally() {
    let viewController = FrugaRelayViewController(initPayload: makeInitPayload(), onError: { _ in })
    var opened: [URL] = []
    viewController.openExternally = { opened.append($0) }
    let evilURL = URL(string: "https://evil.example.com")!

    let allow = viewController.handleNavigation(to: evilURL, isMainFrame: false)

    XCTAssertTrue(allow)
    XCTAssertTrue(opened.isEmpty)
  }
}

#endif
