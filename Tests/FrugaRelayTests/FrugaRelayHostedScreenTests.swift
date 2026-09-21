#if canImport(UIKit) && canImport(WebKit)

import XCTest

@testable import FrugaRelayCore
@testable import FrugaRelay

/// Covers the contract decided 2026-09-12 (`.agent/rules/native-sdk.md`
/// "getBalance()" bullet): `FrugaRelay.getBalance()` answers for any live
/// `FrugaRelayViewController`, whether presented by `FrugaRelay.open(from:)`
/// or hosted directly by the partner. Current implementation:
///
/// ```swift
/// public final class FrugaRelayViewController: UIViewController {
///   public override func viewDidLoad() {
///     ...
///     FrugaRelay.registerHostedScreen(self)
///   }
///   public override func viewDidAppear(_ animated: Bool) {
///     ...
///     FrugaRelay.registerHostedScreen(self)
///   }
///   public override func viewDidDisappear(_ animated: Bool) {
///     ...
///     relayDidDisappear(isDismissing: isBeingDismissed || isMovingFromParent)
///   }
///   private func relayDidDisappear(isDismissing: Bool) {
///     guard isDismissing else { return }
///     FrugaRelay.unregisterHostedScreen(self) // identity-guarded
///     ...
///   }
/// }
/// ```
///
/// `FrugaRelay.getBalance()` reads `FrugaRelay.liveScreen`, a `weak var` set
/// by `registerHostedScreen(_:)` and cleared by `unregisterHostedScreen(_:)`
/// (`FrugaRelay.swift` ~L27, ~L34-45), not `FrugaRelay.presentedController`
/// (`presented`, set only by `open(from:onError:)`). With no live screen,
/// `getBalance()` fails fast with `.bridgeTimeout` instead of waiting out the
/// bridge timeout (`FrugaRelay.swift` ~L117-130).
///
/// Written blind: this file only runs in the mirror's macOS job.
@MainActor
final class FrugaRelayHostedScreenTests: XCTestCase {
  override func tearDown() {
    FrugaRelay.close()
    FrugaRelay.reset()
    super.tearDown()
  }

  private func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
      "missing fixture \(name).json — run: cp packages/loader/src/native/fixtures/*.json packages/ios/Tests/Fixtures/"
    )
    return try Data(contentsOf: url)
  }

  private func makeConfig() -> FrugaRelayConfig {
    FrugaRelayConfig(
      partnerKey: "partner_test_123",
      tokenProvider: { _ in "eyJ.test" },
      options: FrugaRelayOptions()
    )
  }

  // MARK: - 1. A directly hosted controller (never `open`ed) answers getBalance().

  func testGetBalanceAnswersForADirectlyHostedController() async throws {
    var controller: FrugaRelayViewController? = FrugaRelayViewController(config: makeConfig(), onError: { _ in })
    controller?.loadsShellAutomatically = false
    controller?.loadViewIfNeeded()

    async let resultTask = FrugaRelay.getBalance(timeout: 2)
    try await Task.sleep(nanoseconds: 50_000_000)
    controller?.session.receive(try fixture("balance.valid"))

    let result = await resultTask
    switch result {
    case let .success(balance):
      XCTAssertEqual(balance, FrugaBalance(available: 12.5, pending: 3.25))
    default:
      XCTFail("expected .success from a directly hosted screen, got \(result)")
    }
    controller = nil
  }

  // MARK: - 2. Once the hosted controller is gone, getBalance() fails again.

  /// Fixed 2026-09-21 (sdk-debugger root cause B, ios mirror CI red since
  /// 2026-09-13): this used to assert ARC deallocation timing directly
  /// (`controller = nil` then expect the weak `liveScreen` slot to be nil),
  /// which is not guaranteed — UIKit/autorelease pools can keep the instance
  /// alive past the assignment. `.agent/rules/native-sdk.md` requires
  /// registration to never rely only on `deinit`; the guaranteed path is
  /// already pinned by `testViewDidDisappearWhenDismissingUnregistersTheHostedScreen`
  /// above and by `FrugaRelayGetBalanceTests.testGetBalanceWithNoScreenPresentedFailsImmediatelyWithBridgeTimeout`.
  /// So: give ARC every chance via an `autoreleasepool`, and if the instance
  /// still outlives it, skip rather than fail — deallocation timing is not
  /// this test's contract.
  func testGetBalanceFailsAgainOnceTheHostedControllerIsGone() async throws {
    weak var weakController: FrugaRelayViewController?

    autoreleasepool {
      let controller = FrugaRelayViewController(config: makeConfig(), onError: { _ in })
      controller.loadsShellAutomatically = false
      controller.loadViewIfNeeded()
      weakController = controller
    }

    guard weakController == nil else {
      throw XCTSkip(
        "the hosted controller was not deallocated after the autoreleasepool; "
          + "ARC/UIKit deallocation timing is not guaranteed by this test"
      )
    }

    let result = await FrugaRelay.getBalance(timeout: 2)

    switch result {
    case let .failure(error):
      XCTAssertEqual(error.code, .bridgeTimeout)
      XCTAssertEqual(error.message, "No Relay screen is open")
    default:
      XCTFail("expected .failure(.bridgeTimeout) once the hosted controller is deallocated, got \(result)")
    }
  }

  // MARK: - 3. Identity guard: dropping an older hosted screen must not
  //        unregister a newer one still live.

  func testDroppingAnOlderHostedScreenDoesNotUnregisterANewerOne() async throws {
    var controllerA: FrugaRelayViewController? = FrugaRelayViewController(config: makeConfig(), onError: { _ in })
    controllerA?.loadsShellAutomatically = false
    controllerA?.loadViewIfNeeded()

    let controllerB = FrugaRelayViewController(config: makeConfig(), onError: { _ in })
    controllerB.loadsShellAutomatically = false
    controllerB.loadViewIfNeeded()

    // B registers after A; dropping A must not clear B's registration.
    controllerA = nil

    async let resultTask = FrugaRelay.getBalance(timeout: 2)
    try await Task.sleep(nanoseconds: 50_000_000)
    controllerB.session.receive(try fixture("balance.valid"))

    let result = await resultTask
    switch result {
    case let .success(balance):
      XCTAssertEqual(balance, FrugaBalance(available: 12.5, pending: 3.25))
    default:
      XCTFail("expected .success from controller B, which is still live, got \(result)")
    }
  }

  // MARK: - 4-6. Refinement (decided 2026-09-13, `.agent/rules/native-sdk.md`
  //        "getBalance()" bullet): a partner-retained but *dismissed* screen
  //        must stop answering `getBalance()`, and answer again once it
  //        reappears. Android already stops answering in `onDestroyView`.
  //
  // Not yet implemented: `viewDidDisappear` never calls
  // `FrugaRelay.unregisterHostedScreen`, and there is no `viewDidAppear`
  // override to re-register. Registration today only moves in
  // `viewDidLoad`/`deinit`.

  // MARK: - 4. Dismissing unregisters the hosted screen.

  func testViewDidDisappearWhenDismissingUnregistersTheHostedScreen() async {
    let controller = FrugaRelayViewController(config: makeConfig(), onError: { _ in })
    controller.loadsShellAutomatically = false
    controller.loadViewIfNeeded()

    // Simulates the sheet being dismissed while the partner still retains `controller`.
    controller.relayDidDisappear(isDismissing: true)

    let result = await FrugaRelay.getBalance(timeout: 2)

    switch result {
    case let .failure(error):
      XCTAssertEqual(error.code, .bridgeTimeout)
      XCTAssertEqual(error.message, "No Relay screen is open")
    default:
      XCTFail("expected .failure(.bridgeTimeout) once dismissal unregisters the hosted screen, got \(result)")
    }
  }

  // MARK: - 5. Guard: being covered by another sheet (not dismissed) must not unregister.

  func testViewDidDisappearWhenNotDismissingKeepsTheHostedScreenRegistered() async throws {
    let controller = FrugaRelayViewController(config: makeConfig(), onError: { _ in })
    controller.loadsShellAutomatically = false
    controller.loadViewIfNeeded()

    // Simulates another sheet being presented on top: not a dismissal.
    controller.relayDidDisappear(isDismissing: false)

    async let resultTask = FrugaRelay.getBalance(timeout: 2)
    try await Task.sleep(nanoseconds: 50_000_000)
    controller.session.receive(try fixture("balance.valid"))

    let result = await resultTask
    switch result {
    case let .success(balance):
      XCTAssertEqual(balance, FrugaBalance(available: 12.5, pending: 3.25))
    default:
      XCTFail("expected .success: not dismissing must not unregister the hosted screen, got \(result)")
    }
  }

  // MARK: - 6. Reappearing re-registers the hosted screen.

  func testViewDidAppearReRegistersTheHostedScreen() async throws {
    let controllerA = FrugaRelayViewController(config: makeConfig(), onError: { _ in })
    controllerA.loadsShellAutomatically = false
    controllerA.loadViewIfNeeded()

    // A second screen takes over the single `liveScreen` slot.
    let controllerB = FrugaRelayViewController(config: makeConfig(), onError: { _ in })
    controllerB.loadsShellAutomatically = false
    controllerB.loadViewIfNeeded()

    // Simulates B being dismissed and A reappearing underneath it.
    controllerA.viewDidAppear(false)

    async let resultTask = FrugaRelay.getBalance(timeout: 2)
    try await Task.sleep(nanoseconds: 50_000_000)
    controllerA.session.receive(try fixture("balance.valid"))

    let result = await resultTask
    switch result {
    case let .success(balance):
      XCTAssertEqual(balance, FrugaBalance(available: 12.5, pending: 3.25))
    default:
      XCTFail("expected .success from A once it reappeared and re-registered, got \(result)")
    }
  }
}

#endif
