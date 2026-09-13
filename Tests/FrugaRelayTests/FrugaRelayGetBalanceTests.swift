#if canImport(UIKit) && canImport(WebKit)

import XCTest

@testable import FrugaRelayCore
@testable import FrugaRelay

/// RED tests for issue #131: the `FrugaRelay.getBalance()` facade. Contract
/// (not yet implemented):
///
/// ```swift
/// extension FrugaRelay {
///   @MainActor
///   public static func getBalance(timeout: TimeInterval = 5) async -> Result<FrugaBalance, FrugaError>
///     // no Relay screen presented: immediately .failure(.bridgeTimeout)
///     // a screen presented: forwards to its session's requestBalance(timeout:completion:)
/// }
/// ```
///
/// Written blind: this file only runs in the mirror's macOS job.
@MainActor
final class FrugaRelayGetBalanceTests: XCTestCase {
  private var window: UIWindow?

  override func tearDown() {
    FrugaRelay.close()
    FrugaRelay.reset()
    window?.isHidden = true
    window = nil
    super.tearDown()
  }

  private func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
      "missing fixture \(name).json — run: cp packages/loader/src/native/fixtures/*.json packages/ios/Tests/Fixtures/"
    )
    return try Data(contentsOf: url)
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

  // MARK: - 1. No Relay screen presented: getBalance() fails immediately with
  //           .bridgeTimeout, no waiting for the configured timeout.

  func testGetBalanceWithNoScreenPresentedFailsImmediatelyWithBridgeTimeout() async {
    let start = Date()

    let result = await FrugaRelay.getBalance(timeout: 5)

    let elapsed = Date().timeIntervalSince(start)
    XCTAssertLessThan(elapsed, 1.0, "must not wait for the timeout when nothing is presented")
    switch result {
    case let .failure(error):
      XCTAssertEqual(error.code, .bridgeTimeout)
    default:
      XCTFail("expected .failure(.bridgeTimeout), got \(result)")
    }
  }

  // MARK: - 2. A screen presented: getBalance() forwards to its session and
  //           resolves with the shell's balance.

  func testGetBalanceWithScreenPresentedForwardsToSessionAndSucceeds() async throws {
    let presenter = makeWindowRootedController()
    FrugaRelay.configure(partnerKey: "partner_test_123", tokenProvider: { _ in "eyJ.test" }, options: FrugaRelayOptions())
    FrugaRelay.open(from: presenter, onError: { _ in })
    _ = try await waitUntilPresented(by: presenter)
    let controller = try XCTUnwrap(FrugaRelay.presentedController)

    async let resultTask = FrugaRelay.getBalance(timeout: 2)
    // Give getBalance a moment to register with the session before replying,
    // mirroring the requestBalance tests' synchronous send-then-receive shape.
    try await Task.sleep(nanoseconds: 50_000_000)
    controller.session.receive(try fixture("balance.valid"))

    let result = await resultTask
    switch result {
    case let .success(balance):
      XCTAssertEqual(balance, FrugaBalance(available: 12.5, pending: 3.25))
    default:
      XCTFail("expected .success, got \(result)")
    }
  }
}

#endif
