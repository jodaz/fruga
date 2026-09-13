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

  // MARK: - 13. receive(_:) of an openExternal message invokes onOpenExternal
  //            with the fixture URL and still forwards to onMessage (#77,
  //            M2-I05, navigation allowlist). RED: `onOpenExternal` does not
  //            exist yet on `FrugaShellSession`.

  func testReceiveOpenExternalInvokesOnOpenExternalAndForwards() async throws {
    let transport = FakeTransport()
    var received: [FrugaNativeMessage] = []
    var openedURLs: [URL] = []
    let session = FrugaShellSession(
      transport: transport,
      onMessage: { received.append($0) },
      onError: { _ in }
    )
    session.onOpenExternal = { openedURLs.append($0) }

    session.receive(try fixture("openExternal.valid"))

    XCTAssertEqual(openedURLs, [URL(string: "https://example.com/terms")!])
    XCTAssertEqual(received, [.openExternal(OpenExternalPayload(url: "https://example.com/terms"))])
  }

  // MARK: - 14. receive(_:) of a tokenRequired message invokes onTokenRequired
  //            with the reason and still forwards to onMessage (#76,
  //            sdk-reviewer blocker 5: tokenRequired wired to
  //            FrugaTokenCoordinator). RED: `onTokenRequired` does not exist
  //            yet on `FrugaShellSession`.

  func testReceiveTokenRequiredInvokesOnTokenRequiredAndForwards() async throws {
    let transport = FakeTransport()
    var received: [FrugaNativeMessage] = []
    var reasons: [TokenRequiredPayload.Reason] = []
    let session = FrugaShellSession(
      transport: transport,
      onMessage: { received.append($0) },
      onError: { _ in }
    )
    session.onTokenRequired = { reasons.append($0) }

    session.receive(try fixture("tokenRequired.valid"))

    XCTAssertEqual(reasons, [.initial])
    XCTAssertEqual(received, [.tokenRequired(TokenRequiredPayload(reason: .initial))])
  }

  // MARK: - 15. Regression guard (sdk-reviewer, commit b8f155d): a repeat
  //            requestBack while one is pending sends nothing and does not
  //            complete twice.

  func testRepeatRequestBackWhilePendingSendsNothingAndDoesNotCompleteTwice() async throws {
    let transport = FakeTransport()
    let session = FrugaShellSession(transport: transport, onError: { _ in })
    var completions: [Bool] = []

    session.requestBack { completions.append($0) }
    let sentAfterFirst = transport.sent.count
    session.requestBack { completions.append($0) }

    XCTAssertEqual(transport.sent.count, sentAfterFirst, "a repeat ask while pending must send nothing")

    session.receive(try fixture("backResult.valid")) // handled: true

    XCTAssertEqual(completions, [true], "only the first requestBack's completion may fire")
  }

  // MARK: - 16. RED for issue #78 (M2-I06, network forwarding): send(_:)
  //            forwards an arbitrary host message to the transport and
  //            records it as lastSent, so the controller's `network`
  //            forwarding can be asserted without a spy transport on the
  //            real WKWebView-backed controller. Contract (not yet
  //            implemented):
  //
  //            `public func send(_ message: FrugaHostMessage)` and
  //            `public private(set) var lastSent: FrugaHostMessage?` on
  //            `FrugaShellSession`.

  func testSendForwardsToTransportAndRecordsLastSent() async throws {
    let transport = FakeTransport()
    let session = FrugaShellSession(transport: transport, onError: { _ in })

    session.send(.network(NetworkPayload(online: false)))

    XCTAssertEqual(session.lastSent, .network(NetworkPayload(online: false)))
    let sentData = try XCTUnwrap(transport.sent.last)
    let sentObject = try JSONSerialization.jsonObject(with: sentData) as? NSDictionary
    XCTAssertEqual(sentObject, ["type": "network", "online": false])
  }

  // MARK: - 17. RED for issue #129: receive(_:) of a `ready` message whose
  //            protocolVersion differs from FrugaRelayVersion.protocolVersion
  //            reports VERSION_MISMATCH (not recoverable) and still forwards
  //            to onMessage. Matching version reports no error.

  func testReceiveReadyWithMismatchedProtocolVersionReportsVersionMismatch() async throws {
    let transport = FakeTransport()
    var errors: [FrugaError] = []
    var received: [FrugaNativeMessage] = []
    let session = FrugaShellSession(
      transport: transport,
      onMessage: { received.append($0) },
      onError: { errors.append($0) }
    )
    let mismatched = try JSONEncoder().encode(
      FrugaNativeMessage.ready(ReadyPayload(protocolVersion: 999, sdkVersion: "1.0.0"))
    )

    session.receive(mismatched)

    XCTAssertEqual(errors.count, 1)
    XCTAssertEqual(errors.first?.code, .versionMismatch)
    XCTAssertEqual(errors.first?.recoverable, false)
    XCTAssertEqual(received, [.ready(ReadyPayload(protocolVersion: 999, sdkVersion: "1.0.0"))])
  }

  func testReceiveReadyWithMatchingProtocolVersionReportsNoError() async throws {
    let transport = FakeTransport()
    var errors: [FrugaError] = []
    var received: [FrugaNativeMessage] = []
    let session = FrugaShellSession(
      transport: transport,
      onMessage: { received.append($0) },
      onError: { errors.append($0) }
    )

    session.receive(try fixture("ready.valid")) // protocolVersion: 1

    XCTAssertTrue(errors.isEmpty)
    XCTAssertEqual(received, [.ready(ReadyPayload(protocolVersion: 1, sdkVersion: "1.0.0"))])
  }

  // MARK: - 18. RED for issue #131/#129: FrugaRelayVersion.protocolVersion
  //            is the value receive(_:) compares ready.protocolVersion
  //            against.

  func testProtocolVersionConstantIsOne() async {
    XCTAssertEqual(FrugaRelayVersion.protocolVersion, 1)
  }

  // MARK: - 19. RED for issue #129: every dropped inbound message — each
  //            *.invalid.json fixture, plus a non-object body — invokes the
  //            new onDropped callback exactly once with the JSON `type`
  //            string when present, else nil; onMessage is never called for
  //            a dropped message.

  func testReceiveDroppedMessagesInvokeOnDroppedWithRawType() async throws {
    let cases: [(fixture: String, expectedType: String)] = [
      ("back.invalid", "Back"),
      ("backResult.invalid", "backResult"),
      ("balance.invalid", "balance"),
      ("error.invalid", "error"),
      ("getBalance.invalid", "GetBalance"),
      ("init.invalid", "init"),
      ("log.invalid", "log"),
      ("network.invalid", "network"),
      ("openExternal.invalid", "openExternal"),
      ("ready.invalid", "ready"),
      ("tokenRequired.invalid", "tokenRequired"),
      ("tokenUpdate.invalid", "tokenUpdate")
    ]

    for testCase in cases {
      let transport = FakeTransport()
      var received: [FrugaNativeMessage] = []
      var dropped: [String?] = []
      let session = FrugaShellSession(
        transport: transport,
        onMessage: { received.append($0) },
        onError: { _ in }
      )
      session.onDropped = { dropped.append($0) }

      session.receive(try fixture(testCase.fixture))

      XCTAssertTrue(received.isEmpty, "\(testCase.fixture) must not reach onMessage")
      XCTAssertEqual(dropped, [testCase.expectedType], "\(testCase.fixture) should report its raw type")
    }
  }

  func testReceiveNonObjectBodyInvokesOnDroppedWithNilType() async throws {
    let transport = FakeTransport()
    var received: [FrugaNativeMessage] = []
    var dropped: [String?] = []
    let session = FrugaShellSession(
      transport: transport,
      onMessage: { received.append($0) },
      onError: { _ in }
    )
    session.onDropped = { dropped.append($0) }

    session.receive(Data("not json".utf8))

    XCTAssertTrue(received.isEmpty)
    XCTAssertEqual(dropped.count, 1)
    XCTAssertNil(dropped.first ?? "sentinel")
  }

  func testReceiveValidMessageDoesNotInvokeOnDropped() async throws {
    let transport = FakeTransport()
    var dropped: [String?] = []
    let session = FrugaShellSession(transport: transport, onError: { _ in })
    session.onDropped = { dropped.append($0) }

    session.receive(try fixture("ready.valid"))

    XCTAssertTrue(dropped.isEmpty)
  }

  // MARK: - 20. RED for issue #131: requestBalance(timeout:completion:)
  //            sends the getBalance host message and completes with the
  //            decoded FrugaBalance on the next `balance`; silence past the
  //            timeout completes .failure(.bridgeTimeout, recoverable: true);
  //            two in-flight requests both complete on one `balance`.

  func testRequestBalanceSendsEncodedGetBalanceMessage() async throws {
    let transport = FakeTransport()
    let session = FrugaShellSession(transport: transport, onError: { _ in })

    session.requestBalance { _ in }

    let sentData = try XCTUnwrap(transport.sent.last)
    let sentObject = try JSONSerialization.jsonObject(with: sentData) as? NSDictionary
    let expectedObject = try JSONSerialization.jsonObject(with: fixture("getBalance.valid")) as? NSDictionary
    XCTAssertEqual(sentObject, expectedObject)
  }

  func testRequestBalanceCompletesWithDecodedBalanceOnReceive() async throws {
    let transport = FakeTransport()
    let session = FrugaShellSession(transport: transport, onError: { _ in })
    let expectation = expectation(description: "balance")
    var result: Result<FrugaBalance, FrugaError>?

    session.requestBalance { received in
      result = received
      expectation.fulfill()
    }
    session.receive(try fixture("balance.valid")) // available: 12.5, pending: 3.25

    await fulfillment(of: [expectation], timeout: 1.0)
    switch result {
    case let .success(balance):
      XCTAssertEqual(balance, FrugaBalance(available: 12.5, pending: 3.25))
    default:
      XCTFail("expected .success, got \(String(describing: result))")
    }
  }

  func testRequestBalanceTimesOutToBridgeTimeoutFailure() async throws {
    let transport = FakeTransport()
    let session = FrugaShellSession(transport: transport, onError: { _ in })
    let expectation = expectation(description: "timeout")
    var result: Result<FrugaBalance, FrugaError>?

    session.requestBalance(timeout: 0.05) { received in
      result = received
      expectation.fulfill()
    }

    await fulfillment(of: [expectation], timeout: 1.0)
    switch result {
    case let .failure(error):
      XCTAssertEqual(error.code, .bridgeTimeout)
      XCTAssertEqual(error.recoverable, true)
    default:
      XCTFail("expected .failure(.bridgeTimeout), got \(String(describing: result))")
    }
  }

  func testTwoInFlightRequestBalanceCallsBothCompleteOnOneBalance() async throws {
    let transport = FakeTransport()
    let session = FrugaShellSession(transport: transport, onError: { _ in })
    let firstExpectation = expectation(description: "first balance")
    let secondExpectation = expectation(description: "second balance")
    var firstResult: Result<FrugaBalance, FrugaError>?
    var secondResult: Result<FrugaBalance, FrugaError>?

    session.requestBalance { received in
      firstResult = received
      firstExpectation.fulfill()
    }
    session.requestBalance { received in
      secondResult = received
      secondExpectation.fulfill()
    }
    session.receive(try fixture("balance.valid"))

    await fulfillment(of: [firstExpectation, secondExpectation], timeout: 1.0)
    let expected = FrugaBalance(available: 12.5, pending: 3.25)
    switch (firstResult, secondResult) {
    case let (.success(first), .success(second)):
      XCTAssertEqual(first, expected)
      XCTAssertEqual(second, expected)
    default:
      XCTFail("expected both to succeed, got \(String(describing: firstResult)), \(String(describing: secondResult))")
    }
  }

  // MARK: - 21. RED for the sdk-reviewer's M2 batch 1 finding (F3): a pending
  //            requestBalance is also resolved by the next inbound `error`
  //            message — `.failure(FrugaError)` carrying that message's own
  //            fields — not just left to time out. The timeout is cancelled,
  //            and the `error` still reaches `onMessage`. An `error` with
  //            nothing pending does nothing extra.

  func testRequestBalanceIsResolvedByNextErrorMessage() async throws {
    let transport = FakeTransport()
    let session = FrugaShellSession(transport: transport, onError: { _ in })
    let expectation = expectation(description: "error")
    var result: Result<FrugaBalance, FrugaError>?

    session.requestBalance { received in
      result = received
      expectation.fulfill()
    }
    session.receive(try fixture("error.valid")) // TIMEOUT, "Bridge did not respond in time", recoverable: true

    await fulfillment(of: [expectation], timeout: 1.0)
    switch result {
    case let .failure(error):
      XCTAssertEqual(error.code, .timeout)
      XCTAssertEqual(error.message, "Bridge did not respond in time")
      XCTAssertEqual(error.recoverable, true)
    default:
      XCTFail("expected .failure(.timeout), got \(String(describing: result))")
    }
  }

  func testErrorMessageResolvingPendingBalanceIsStillForwardedToOnMessage() async throws {
    let transport = FakeTransport()
    var receivedMessages: [FrugaNativeMessage] = []
    let session = FrugaShellSession(
      transport: transport,
      onMessage: { receivedMessages.append($0) },
      onError: { _ in }
    )

    session.requestBalance { _ in }
    session.receive(try fixture("error.valid"))

    XCTAssertEqual(receivedMessages.count, 1)
    guard case .error = receivedMessages.first else {
      return XCTFail("expected .error, got \(String(describing: receivedMessages.first))")
    }
  }

  func testErrorResolvingPendingBalanceCancelsTheTimeout() async throws {
    let transport = FakeTransport()
    let session = FrugaShellSession(transport: transport, onError: { _ in })
    var results: [Result<FrugaBalance, FrugaError>] = []

    session.requestBalance(timeout: 0.05) { results.append($0) }
    session.receive(try fixture("error.valid"))

    try await Task.sleep(nanoseconds: 200_000_000) // well past the 0.05s timeout
    XCTAssertEqual(results.count, 1, "the cancelled timeout must not deliver a second completion")
    if case let .failure(error) = results.first {
      XCTAssertEqual(error.code, .timeout)
    } else {
      XCTFail("expected .failure(.timeout), got \(String(describing: results.first))")
    }
  }

  func testErrorWithNothingPendingDoesNothingExtra() async throws {
    let transport = FakeTransport()
    var onErrorCalls = 0
    var receivedMessages: [FrugaNativeMessage] = []
    let session = FrugaShellSession(
      transport: transport,
      onMessage: { receivedMessages.append($0) },
      onError: { _ in onErrorCalls += 1 }
    )

    session.receive(try fixture("error.valid"))

    XCTAssertEqual(onErrorCalls, 0)
    XCTAssertEqual(receivedMessages.count, 1)
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
