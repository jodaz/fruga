import XCTest

@testable import FrugaRelayCore

/// RED tests for issue #76 (M2-I04) sdk-reviewer blocker 4: the public facade
/// takes `FrugaRelayOptions`, matching Android's
/// `FrugaRelayOptions(theme:primaryColor:userId:apiBaseUrl:locale:debug:)`,
/// not a raw `InitPayload`. Contract (not yet implemented — this file is
/// meant to fail to compile until `ios-owner` adds it to `FrugaRelayCore`):
///
/// ```swift
/// public struct FrugaRelayOptions: Sendable {
///   public var theme: InitPayload.Theme?
///   public var primaryColor: String?
///   public var userId: String?
///   public var apiBaseUrl: String?
///   public var locale: String?
///   public var debug: Bool
///   public init(
///     theme: InitPayload.Theme? = nil,
///     primaryColor: String? = nil,
///     userId: String? = nil,
///     apiBaseUrl: String? = nil,
///     locale: String? = nil,
///     debug: Bool = false
///   )
/// }
///
/// struct FrugaRelayConfig {
///   let partnerKey: String
///   let tokenProvider: FrugaTokenProvider
///   let options: FrugaRelayOptions
///   init(partnerKey: String, tokenProvider: @escaping FrugaTokenProvider, options: FrugaRelayOptions)
///   func makeInitPayload(safeArea: SafeArea, token: String?) -> InitPayload
/// }
/// ```
final class FrugaRelayOptionsTests: XCTestCase {
  // MARK: - Defaults: no init argument means "the shell decides" (theme nil)
  //        and telemetry off (debug false).

  func testDefaultsThemeNilAndDebugFalse() {
    let options = FrugaRelayOptions()

    XCTAssertNil(options.theme)
    XCTAssertNil(options.primaryColor)
    XCTAssertNil(options.userId)
    XCTAssertNil(options.apiBaseUrl)
    XCTAssertNil(options.locale)
    XCTAssertFalse(options.debug)
  }

  // MARK: - FrugaRelayConfig.makeInitPayload(safeArea:token:) composes the
  //        InitPayload the loader/shell contract needs from partnerKey +
  //        options + the caller-supplied safeArea and token.

  func testMakeInitPayloadBuildsFromPartnerKeyOptionsSafeAreaAndToken() {
    let options = FrugaRelayOptions(
      theme: .dark,
      primaryColor: "#4F46E5",
      userId: "user_42",
      apiBaseUrl: "https://api.fruga.co.uk",
      locale: "en-GB",
      debug: true
    )
    let config = FrugaRelayConfig(
      partnerKey: "partner_test_123",
      tokenProvider: { _ in "unused" },
      options: options
    )
    let safeArea = SafeArea(top: 47, right: 0, bottom: 34, left: 0)

    let payload = config.makeInitPayload(safeArea: safeArea, token: "eyJ.test")

    XCTAssertEqual(
      payload,
      InitPayload(
        partnerKey: "partner_test_123",
        token: "eyJ.test",
        theme: .dark,
        primaryColor: "#4F46E5",
        userId: "user_42",
        apiBaseUrl: "https://api.fruga.co.uk",
        locale: "en-GB",
        safeArea: safeArea,
        debug: true
      )
    )
  }

  // MARK: - A nil token (before the first tokenUpdate) is still omitted, same
  //        as InitPayload's existing contract.

  func testMakeInitPayloadOmitsTokenWhenNil() throws {
    let config = FrugaRelayConfig(
      partnerKey: "partner_test_123",
      tokenProvider: { _ in "unused" },
      options: FrugaRelayOptions()
    )
    let safeArea = SafeArea(top: 0, right: 0, bottom: 0, left: 0)

    let payload = config.makeInitPayload(safeArea: safeArea, token: nil)

    XCTAssertNil(payload.token)
  }

  // MARK: - RED for issue #78 (M2-I06, foreground TTL re-check), parity with
  //        Android's `FrugaRelayOptions.tokenTtlSeconds`: absent means no
  //        foreground re-check.

  func testTokenTtlSecondsDefaultsToNil() {
    let options = FrugaRelayOptions()

    XCTAssertNil(options.tokenTtlSeconds)
  }

  func testTokenTtlSecondsIsSettable() {
    let options = FrugaRelayOptions(tokenTtlSeconds: 300)

    XCTAssertEqual(options.tokenTtlSeconds, 300)
  }
}
