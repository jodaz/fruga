import XCTest

@testable import FrugaRelayCore

/// RED tests for issue #77 (M2-I05, navigation allowlist). Native rule: "only
/// the CDN origin and the API origin load inside the WebView. Everything
/// else, and `openExternal`, opens in the system browser component."
///
/// Contract (not yet implemented):
///
/// ```swift
/// public struct FrugaNavigationPolicy: Equatable {
///   public init(allowedOrigins: [URL])   // scheme+host+port compared, path ignored
///   public static func standard(apiBaseUrl: URL?) -> FrugaNavigationPolicy
///     // CDN origin from FrugaRelayVersion shell URL plus the API origin
///     // (default https://api.fruga.co.uk when apiBaseUrl is nil)
///   public enum Decision: Equatable { case allow, openExternally }
///   public func decide(_ url: URL, isMainFrame: Bool) -> Decision
///     // subframe/subresource loads are allowed regardless (only top-level
///     // navigation is policed); about:blank and about:srcdoc are allowed
/// }
/// ```
final class FrugaNavigationPolicyTests: XCTestCase {
  private let cdnOrigin = URL(string: "https://cdn.fruga.co.uk")!
  private let defaultApiOrigin = URL(string: "https://api.fruga.co.uk")!

  private func shellURL() -> URL {
    URL(string: "https://cdn.fruga.co.uk/v/\(FrugaRelayVersion.shell)/native/index.html")!
  }

  // MARK: - standard(apiBaseUrl:) composition

  func testStandardEqualsExplicitAllowedOriginsWithCustomApiBaseUrl() {
    let custom = URL(string: "https://api.staging.fruga.co.uk")!

    XCTAssertEqual(
      FrugaNavigationPolicy.standard(apiBaseUrl: custom),
      FrugaNavigationPolicy(allowedOrigins: [cdnOrigin, custom])
    )
  }

  func testStandardEqualsExplicitAllowedOriginsWithDefaultApiBaseUrl() {
    XCTAssertEqual(
      FrugaNavigationPolicy.standard(apiBaseUrl: nil),
      FrugaNavigationPolicy(allowedOrigins: [cdnOrigin, defaultApiOrigin])
    )
  }

  // MARK: - Allowed origins

  func testCdnShellUrlIsAllowed() {
    let policy = FrugaNavigationPolicy.standard(apiBaseUrl: nil)

    XCTAssertEqual(policy.decide(shellURL(), isMainFrame: true), .allow)
  }

  func testAnotherPathOnTheCdnOriginIsAllowed() {
    let policy = FrugaNavigationPolicy.standard(apiBaseUrl: nil)

    XCTAssertEqual(
      policy.decide(URL(string: "https://cdn.fruga.co.uk/v/1.3.0/native/other.html")!, isMainFrame: true),
      .allow
    )
  }

  func testDefaultApiOriginIsAllowed() {
    let policy = FrugaNavigationPolicy.standard(apiBaseUrl: nil)

    XCTAssertEqual(
      policy.decide(URL(string: "https://api.fruga.co.uk/v1/balance")!, isMainFrame: true),
      .allow
    )
  }

  func testCustomApiBaseUrlOriginIsAllowedAndDefaultIsNot() {
    let policy = FrugaNavigationPolicy.standard(apiBaseUrl: URL(string: "https://api.staging.fruga.co.uk")!)

    XCTAssertEqual(
      policy.decide(URL(string: "https://api.staging.fruga.co.uk/v1/balance")!, isMainFrame: true),
      .allow
    )
    XCTAssertEqual(
      policy.decide(URL(string: "https://api.fruga.co.uk/v1/balance")!, isMainFrame: true),
      .openExternally
    )
  }

  // MARK: - Disallowed origins open externally

  func testHttpDowngradeOfTheCdnHostOpensExternally() {
    let policy = FrugaNavigationPolicy.standard(apiBaseUrl: nil)

    XCTAssertEqual(
      policy.decide(URL(string: "http://cdn.fruga.co.uk/v/1.3.0/native/index.html")!, isMainFrame: true),
      .openExternally
    )
  }

  func testUnrelatedHostOpensExternallyOnMainFrame() {
    let policy = FrugaNavigationPolicy.standard(apiBaseUrl: nil)

    XCTAssertEqual(
      policy.decide(URL(string: "https://evil.example.com")!, isMainFrame: true),
      .openExternally
    )
  }

  // MARK: - Only top-level navigation is policed.

  func testSameDisallowedUrlIsAllowedWhenNotMainFrame() {
    let policy = FrugaNavigationPolicy.standard(apiBaseUrl: nil)

    XCTAssertEqual(
      policy.decide(URL(string: "https://evil.example.com")!, isMainFrame: false),
      .allow
    )
  }

  // MARK: - about: URLs are always allowed.

  func testAboutBlankIsAllowed() {
    let policy = FrugaNavigationPolicy.standard(apiBaseUrl: nil)

    XCTAssertEqual(policy.decide(URL(string: "about:blank")!, isMainFrame: true), .allow)
  }

  func testAboutSrcdocIsAllowed() {
    let policy = FrugaNavigationPolicy.standard(apiBaseUrl: nil)

    XCTAssertEqual(policy.decide(URL(string: "about:srcdoc")!, isMainFrame: true), .allow)
  }

  // MARK: - Regression guard (sdk-reviewer, issue #78): an explicit :443 on
  //        the CDN host is the same origin as the default-port entry.

  func testExplicitDefaultHttpsPortEqualsDefaultPortOrigin() {
    let policy = FrugaNavigationPolicy.standard(apiBaseUrl: nil)
    let explicitPortUrl = URL(string: "https://cdn.fruga.co.uk:443/v/\(FrugaRelayVersion.shell)/native/index.html")!

    XCTAssertEqual(policy.decide(explicitPortUrl, isMainFrame: true), .allow)
  }
}
