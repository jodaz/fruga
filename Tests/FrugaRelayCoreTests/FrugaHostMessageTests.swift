import XCTest

@testable import FrugaRelayCore

/// RED tests for issue #76 (M2-I04): native -> shell `FrugaHostMessage` encoding.
/// Mirrors the shell -> native `FrugaNativeMessage` in this target and the
/// Android `FrugaHostMessage` in `packages/android/relay`. Contract (not yet
/// implemented — this file is meant to fail to compile until `ios-owner` adds
/// it to `FrugaRelayCore`):
///
/// ```swift
/// public enum FrugaHostMessage: Encodable, Equatable {
///   case `init`(InitPayload), tokenUpdate(TokenUpdatePayload), network(NetworkPayload), back, getBalance
///   public func encode() throws -> Data
/// }
/// public struct InitPayload: Encodable, Equatable {
///   let partnerKey: String
///   let token, primaryColor, userId, apiBaseUrl, locale: String?
///   let theme: Theme?
///   let safeArea: SafeArea
///   let debug: Bool
///   enum Theme: String, Codable, Equatable { case light, dark }   // wire lowercase
/// }
/// public struct SafeArea: Encodable, Equatable { let top, right, bottom, left: Int }
/// public struct TokenUpdatePayload: Encodable, Equatable { let token: String }
/// public struct NetworkPayload: Encodable, Equatable { let online: Bool }
/// ```
///
/// The envelope is flat — `"type"` beside the payload fields — and absent
/// `init` optionals are omitted, never sent as `null`.
final class FrugaHostMessageTests: XCTestCase {
  private func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
      "missing fixture \(name).json — run: cp packages/loader/src/native/fixtures/*.json packages/ios/Tests/Fixtures/"
    )
    return try Data(contentsOf: url)
  }

  /// Structural comparison (keys/values), not byte-for-byte: key order isn't
  /// part of the contract.
  private func assertStructurallyEqual(
    _ encoded: Data,
    toFixture name: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let expected =
      try JSONSerialization.jsonObject(with: fixture(name), options: [.fragmentsAllowed]) as? NSDictionary
    let actual = try JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed]) as? NSDictionary
    XCTAssertEqual(actual, expected, file: file, line: line)
  }

  // MARK: - native -> shell messages encode structurally equal to the fixtures

  func testInitEncodesLikeFixture() throws {
    let message = FrugaHostMessage.`init`(
      InitPayload(
        partnerKey: "partner_test_123",
        token: "eyJhbGciOiJIUzI1NiJ9.test.token",
        theme: .light,
        primaryColor: "#4F46E5",
        userId: "user_42",
        apiBaseUrl: "https://api.fruga.co.uk",
        locale: "en-GB",
        safeArea: SafeArea(top: 47, right: 0, bottom: 34, left: 0),
        debug: false
      )
    )

    try assertStructurallyEqual(message.encode(), toFixture: "init.valid")
  }

  func testTokenUpdateEncodesLikeFixture() throws {
    let message = FrugaHostMessage.tokenUpdate(TokenUpdatePayload(token: "eyJhbGciOiJIUzI1NiJ9.new.token"))

    try assertStructurallyEqual(message.encode(), toFixture: "tokenUpdate.valid")
  }

  func testNetworkEncodesLikeFixture() throws {
    let message = FrugaHostMessage.network(NetworkPayload(online: true))

    try assertStructurallyEqual(message.encode(), toFixture: "network.valid")
  }

  func testBackEncodesLikeFixture() throws {
    try assertStructurallyEqual(FrugaHostMessage.back.encode(), toFixture: "back.valid")
  }

  func testGetBalanceEncodesLikeFixture() throws {
    try assertStructurallyEqual(FrugaHostMessage.getBalance.encode(), toFixture: "getBalance.valid")
  }

  // MARK: - init with every optional nil emits only the required keys

  func testInitWithNilOptionalsOmitsThem() throws {
    let message = FrugaHostMessage.`init`(
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
    )

    let object = try JSONSerialization.jsonObject(with: message.encode()) as? [String: Any]
    let keys = try XCTUnwrap(object).keys

    XCTAssertEqual(Set(keys), ["type", "partnerKey", "safeArea", "debug"])
  }

  // MARK: - InitPayload.Theme is a wire-lowercase enum, not a raw String
  //        (#76 sdk-reviewer blocker 3, matches Android and the shell validator).

  func testDarkThemeEncodesAsLowercaseString() throws {
    let message = FrugaHostMessage.`init`(
      InitPayload(
        partnerKey: "partner_test_123",
        token: nil,
        theme: .dark,
        primaryColor: nil,
        userId: nil,
        apiBaseUrl: nil,
        locale: nil,
        safeArea: SafeArea(top: 0, right: 0, bottom: 0, left: 0),
        debug: false
      )
    )

    let object = try JSONSerialization.jsonObject(with: message.encode()) as? [String: Any]
    XCTAssertEqual(object?["theme"] as? String, "dark")
  }
}
