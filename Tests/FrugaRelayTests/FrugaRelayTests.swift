import XCTest

@testable import FrugaRelay

final class FrugaRelayTests: XCTestCase {
  func testFacadeTypeExists() {
    XCTAssertNotNil(FrugaRelay.self)
  }
}
