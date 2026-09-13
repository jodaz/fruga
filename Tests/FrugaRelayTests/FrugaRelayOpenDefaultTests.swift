#if canImport(UIKit) && canImport(WebKit)

import UIKit
import XCTest

@testable import FrugaRelay

/// RED test for the sdk-reviewer's should-fix finding on
/// `FrugaRelay.swift:70`: `.agent/rules/native-sdk.md` requires `onError`
/// "cancellable; ... optional/defaulted where the language allows", but
/// `open(from:onError:)` has no default, so `FrugaRelay.open(from: vc)` does
/// not compile today.
///
/// This is a compile-time contract: until `onError` has a default (e.g.
/// `{ _ in }`), this file fails to build, which fails the whole
/// `FrugaRelayTests` target — the same way a missing symbol does in the
/// other RED files in this directory.
///
/// Written blind: this file only runs in the mirror's macOS job.
@MainActor
final class FrugaRelayOpenDefaultTests: XCTestCase {
  override func tearDown() {
    FrugaRelay.reset()
    super.tearDown()
  }

  private func makeWindowRootedController() -> UIViewController {
    let controller = UIViewController()
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = controller
    window.makeKeyAndVisible()
    return controller
  }

  func testOpenCompilesAndPresentsWithoutAnOnErrorArgument() {
    let presenter = makeWindowRootedController()
    FrugaRelay.configure(partnerKey: "partner_test_123", tokenProvider: { _ in "eyJ.test" }, options: FrugaRelayOptions())

    FrugaRelay.open(from: presenter) // no onError: relies on the default `{ _ in }`

    XCTAssertNotNil(presenter.presentedViewController)
  }
}

#endif
