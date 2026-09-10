import XCTest

@testable import FrugaRelayCore

/// RED tests for issue #75 (M2-I03): content process termination recovery.
/// Contract (not yet implemented — this file is meant to fail to compile
/// until `ios-owner` adds `FrugaShellTransport` / `FrugaShellSession` to
/// `FrugaRelayCore`):
///
/// ```swift
/// protocol FrugaShellTransport: AnyObject, Sendable {
///   func reload()
///   func send(_ json: Data)
/// }
///
/// @MainActor
/// final class FrugaShellSession {
///   init(transport: FrugaShellTransport, onError: @escaping @Sendable (FrugaError) -> Void)
///   func start(initMessage: Data)
///   func shellDidLoad()
///   func processDidTerminate()
/// }
/// ```
///
/// `shellDidLoad()` replays the `init` message remembered from `start(initMessage:)`
/// on every call (so a reload after termination re-sends it).
/// `processDidTerminate()` reports `PROCESS_TERMINATED` (recoverable) via `onError`
/// and reloads the transport, with no dedup between repeated terminations.
@MainActor
final class FrugaShellSessionTests: XCTestCase {
  private func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
      "missing fixture \(name).json — run: cp packages/loader/src/native/fixtures/*.json packages/ios/Tests/Fixtures/"
    )
    return try Data(contentsOf: url)
  }

  // MARK: - 1. start(initMessage:) + shellDidLoad() sends the remembered init.

  func testShellDidLoadSendsRememberedInit() throws {
    let initMessage = try fixture("init.valid")
    let transport = FakeTransport()
    var errors: [FrugaError] = []
    let session = FrugaShellSession(transport: transport, onError: { errors.append($0) })

    session.start(initMessage: initMessage)
    session.shellDidLoad()

    XCTAssertEqual(transport.sent, [initMessage])
    XCTAssertTrue(errors.isEmpty)
  }

  // MARK: - 2. shellDidLoad() replays the same init on every call (a reload
  //           must re-send it, not just the first load).

  func testShellDidLoadReplaysInitOnEveryCall() throws {
    let initMessage = try fixture("init.valid")
    let transport = FakeTransport()
    let session = FrugaShellSession(transport: transport, onError: { _ in })

    session.start(initMessage: initMessage)
    session.shellDidLoad()
    session.shellDidLoad()
    session.shellDidLoad()

    XCTAssertEqual(transport.sent, [initMessage, initMessage, initMessage])
  }

  // MARK: - 3. processDidTerminate() emits PROCESS_TERMINATED (recoverable)
  //           and reloads the transport.

  func testProcessDidTerminateEmitsErrorAndReloads() throws {
    let initMessage = try fixture("init.valid")
    let transport = FakeTransport()
    var errors: [FrugaError] = []
    let session = FrugaShellSession(transport: transport, onError: { errors.append($0) })
    session.start(initMessage: initMessage)

    session.processDidTerminate()

    XCTAssertEqual(errors.count, 1)
    XCTAssertEqual(errors.first?.code, .processTerminated)
    XCTAssertEqual(errors.first?.recoverable, true)
    XCTAssertEqual(transport.reloadCount, 1)
  }

  // MARK: - 4. Reload after termination replays the remembered init once the
  //           shell finishes loading again.

  func testInitIsReplayedAfterTerminationReload() throws {
    let initMessage = try fixture("init.valid")
    let transport = FakeTransport()
    let session = FrugaShellSession(transport: transport, onError: { _ in })
    session.start(initMessage: initMessage)
    session.shellDidLoad()

    session.processDidTerminate()
    // The transport's reload eventually finishes loading again, which the
    // host reports back to the session.
    session.shellDidLoad()

    XCTAssertEqual(transport.sent, [initMessage, initMessage])
    XCTAssertEqual(transport.reloadCount, 1)
  }

  // MARK: - 5. No dedup: repeated terminations each report an error and
  //           each reload the transport.

  func testRepeatedTerminationsAreNotDeduped() throws {
    let initMessage = try fixture("init.valid")
    let transport = FakeTransport()
    var errors: [FrugaError] = []
    let session = FrugaShellSession(transport: transport, onError: { errors.append($0) })
    session.start(initMessage: initMessage)

    session.processDidTerminate()
    session.processDidTerminate()

    XCTAssertEqual(errors.count, 2)
    XCTAssertTrue(errors.allSatisfy { $0.code == .processTerminated && $0.recoverable })
    XCTAssertEqual(transport.reloadCount, 2)
  }
}

// MARK: - Test double

/// Records what a `FrugaShellSession` sent/reloaded. All calls in these
/// tests happen synchronously on the main actor, so plain arrays are safe;
/// `@unchecked Sendable` only to satisfy `FrugaShellTransport: Sendable`.
private final class FakeTransport: FrugaShellTransport, @unchecked Sendable {
  private(set) var sent: [Data] = []
  private(set) var reloadCount = 0

  func reload() {
    reloadCount += 1
  }

  func send(_ json: Data) {
    sent.append(json)
  }
}
