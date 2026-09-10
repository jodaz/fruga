import XCTest

@testable import FrugaRelayCore

/// Tests for `FrugaShellSession`. Contract implemented for issue #75
/// (M2-I03, content process termination recovery) in `FrugaShellSession.swift`:
///
/// ```swift
/// @MainActor
/// protocol FrugaShellTransport: AnyObject {
///   func reload()
///   func send(_ json: Data)
/// }
///
/// @MainActor
/// final class FrugaShellSession {
///   init(transport: FrugaShellTransport, onError: @escaping (FrugaError) -> Void)
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
///
/// RED below for issue #76 (M2-I04, presentation and swipe-back): the
/// additions are not yet implemented —
///
/// ```swift
/// @MainActor
/// final class FrugaShellSession {
///   init(
///     transport: FrugaShellTransport,
///     onMessage: @escaping (FrugaNativeMessage) -> Void = { _ in },
///     onError: @escaping (FrugaError) -> Void
///   )
///   func receive(_ json: Data)
///     // decodes via FrugaNativeMessage.decode and calls onMessage;
///     // malformed input is dropped — no throw, nothing called
///   func requestBack(timeout: TimeInterval = 1.0, completion: @escaping (Bool) -> Void)
///     // sends the encoded `back` message via transport.send, then completes
///     // with `handled` from the next backResult; no backResult within the
///     // timeout completes false (default: back closes Relay); a backResult
///     // with no pending request is ignored for completion but still reaches
///     // onMessage
/// }
/// ```
@MainActor
// `@MainActor` XCTest classes need `async` test methods for Linux SwiftPM discovery.
final class FrugaShellSessionTests: XCTestCase {
  private func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
      "missing fixture \(name).json — run: cp packages/loader/src/native/fixtures/*.json packages/ios/Tests/Fixtures/"
    )
    return try Data(contentsOf: url)
  }

  // MARK: - 1. start(initMessage:) + shellDidLoad() sends the remembered init.

  func testShellDidLoadSendsRememberedInit() async throws {
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

  func testShellDidLoadReplaysInitOnEveryCall() async throws {
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

  func testProcessDidTerminateEmitsErrorAndReloads() async throws {
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

  func testInitIsReplayedAfterTerminationReload() async throws {
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

  func testRepeatedTerminationsAreNotDeduped() async throws {
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

  // MARK: - 6. receive(_:) decodes a shell -> native message and forwards it.

  func testReceiveDecodesAndForwardsMessage() async throws {
    let transport = FakeTransport()
    var received: [FrugaNativeMessage] = []
    let session = FrugaShellSession(
      transport: transport,
      onMessage: { received.append($0) },
      onError: { _ in }
    )

    session.receive(try fixture("ready.valid"))

    XCTAssertEqual(received, [.ready(ReadyPayload(protocolVersion: 1, sdkVersion: "1.0.0"))])
  }

  // MARK: - 7. receive(_:) drops malformed input: no throw, nothing called.

  func testReceiveDropsMalformedInput() async throws {
    let transport = FakeTransport()
    var received: [FrugaNativeMessage] = []
    var errors: [FrugaError] = []
    let session = FrugaShellSession(
      transport: transport,
      onMessage: { received.append($0) },
      onError: { errors.append($0) }
    )

    session.receive(Data("not json".utf8))

    XCTAssertTrue(received.isEmpty)
    XCTAssertTrue(errors.isEmpty)
  }

  // MARK: - 8. requestBack(...) sends the encoded `back` message.

  func testRequestBackSendsEncodedBackMessage() async throws {
    let transport = FakeTransport()
    let session = FrugaShellSession(transport: transport, onError: { _ in })

    session.requestBack { _ in }

    let sentData = try XCTUnwrap(transport.sent.last)
    let sentObject = try JSONSerialization.jsonObject(with: sentData) as? NSDictionary
    let expectedObject = try JSONSerialization.jsonObject(with: fixture("back.valid")) as? NSDictionary
    XCTAssertEqual(sentObject, expectedObject)
  }

  // MARK: - 9. requestBack(...) completes true when backResult reports handled.

  func testRequestBackCompletesTrueWhenBackResultHandled() async throws {
    let transport = FakeTransport()
    let session = FrugaShellSession(transport: transport, onError: { _ in })
    let expectation = expectation(description: "handled true")
    var result: Bool?

    session.requestBack { handled in
      result = handled
      expectation.fulfill()
    }
    session.receive(try fixture("backResult.valid")) // handled: true

    await fulfillment(of: [expectation], timeout: 1.0)
    XCTAssertEqual(result, true)
  }

  // MARK: - 10. requestBack(...) completes false when backResult reports unhandled.

  func testRequestBackCompletesFalseWhenBackResultUnhandled() async throws {
    let transport = FakeTransport()
    let session = FrugaShellSession(transport: transport, onError: { _ in })
    let expectation = expectation(description: "handled false")
    var result: Bool?

    session.requestBack { handled in
      result = handled
      expectation.fulfill()
    }
    session.receive(try JSONEncoder().encode(FrugaNativeMessage.backResult(BackResultPayload(handled: false))))

    await fulfillment(of: [expectation], timeout: 1.0)
    XCTAssertEqual(result, false)
  }

  // MARK: - 11. requestBack(...) completes false if no backResult arrives
  //            within the timeout. Default outcome: back closes Relay.

  func testRequestBackTimesOutToFalse() async throws {
    let transport = FakeTransport()
    let session = FrugaShellSession(transport: transport, onError: { _ in })
    let expectation = expectation(description: "timeout")
    var result: Bool?

    session.requestBack(timeout: 0.05) { handled in
      result = handled
      expectation.fulfill()
    }

    await fulfillment(of: [expectation], timeout: 1.0)
    XCTAssertEqual(result, false)
  }

  // MARK: - 12. An unsolicited backResult (no pending requestBack) does not
  //            crash and is still forwarded to onMessage.

  func testUnsolicitedBackResultIsIgnoredButStillForwarded() async throws {
    let transport = FakeTransport()
    var received: [FrugaNativeMessage] = []
    let session = FrugaShellSession(
      transport: transport,
      onMessage: { received.append($0) },
      onError: { _ in }
    )

    session.receive(try fixture("backResult.valid"))

    XCTAssertEqual(received, [.backResult(BackResultPayload(handled: true))])
  }
}

// MARK: - Test double

/// Records what a `FrugaShellSession` sent/reloaded. All calls in these
/// tests happen synchronously on the main actor; `FrugaShellTransport` is
/// `@MainActor`-isolated, so no `Sendable` conformance is needed here.
@MainActor
private final class FakeTransport: FrugaShellTransport {
  private(set) var sent: [Data] = []
  private(set) var reloadCount = 0

  func reload() {
    reloadCount += 1
  }

  func send(_ json: Data) {
    sent.append(json)
  }
}
