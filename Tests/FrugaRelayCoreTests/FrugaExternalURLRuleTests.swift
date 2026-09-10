import XCTest

@testable import FrugaRelayCore

/// RED tests for issue #78 (M2-I06, sdk-reviewer follow-up from #76/#77):
/// `openExternal` from the shell and rejected navigation are limited to
/// `http`/`https` — every other scheme (`tel:`, `mailto:`, a custom app
/// scheme) is dropped instead of handed to the system browser component.
/// Contract (not yet implemented — this file is meant to fail to compile
/// until `ios-owner` adds it to `FrugaRelayCore`, alongside the Android
/// parity check on `FrugaRelayFragment`):
///
/// ```swift
/// public enum FrugaExternalURLRule {
///   public static func allows(_ url: URL) -> Bool   // http/https only, case-insensitive
/// }
/// ```
final class FrugaExternalURLRuleTests: XCTestCase {
  func testHttpIsAllowed() {
    XCTAssertTrue(FrugaExternalURLRule.allows(URL(string: "http://example.com")!))
  }

  func testHttpsIsAllowed() {
    XCTAssertTrue(FrugaExternalURLRule.allows(URL(string: "https://example.com")!))
  }

  func testSchemeComparisonIsCaseInsensitive() {
    XCTAssertTrue(FrugaExternalURLRule.allows(URL(string: "HTTPS://example.com")!))
  }

  func testTelSchemeIsDisallowed() {
    XCTAssertFalse(FrugaExternalURLRule.allows(URL(string: "tel:123")!))
  }

  func testMailtoSchemeIsDisallowed() {
    XCTAssertFalse(FrugaExternalURLRule.allows(URL(string: "mailto:test@example.com")!))
  }

  func testCustomAppSchemeIsDisallowed() {
    XCTAssertFalse(FrugaExternalURLRule.allows(URL(string: "someapp://open")!))
  }
}
