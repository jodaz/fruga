import XCTest

@testable import FrugaRelayCore

/// RED tests for issue #74 (M2-I02): the token provider coordinator.
/// Contract (not yet implemented — this file is meant to fail to compile
/// until `ios-owner` adds `FrugaTokenProvider` / `FrugaError` /
/// `FrugaTokenCoordinator` to `FrugaRelayCore`):
///
/// ```swift
/// public typealias FrugaTokenProvider = @Sendable (TokenRequiredPayload.Reason) async throws -> String
/// public struct FrugaError: Error, Equatable, Sendable {
///   public let code: ErrorPayload.Code
///   public let message: String
///   public let recoverable: Bool
/// }
/// public actor FrugaTokenCoordinator {
///   public init(provider: @escaping FrugaTokenProvider,
///               onToken: @escaping @Sendable (String) -> Void,
///               onError: @escaping @Sendable (FrugaError) -> Void)
///   public func request(reason: TokenRequiredPayload.Reason)
///   public func cancel()
/// }
/// ```
///
/// Reuses `TokenRequiredPayload.Reason` and `ErrorPayload.Code` from
/// `FrugaNativeMessage.swift` rather than inventing parallel enums.
final class FrugaTokenCoordinatorTests: XCTestCase {
  // MARK: - 1. request(reason:) calls the provider with that exact reason
  //           and forwards the returned token to onToken.

  func testRequestCallsProviderWithReasonAndForwardsToken() async {
    for reason: TokenRequiredPayload.Reason in [.initial, .ttl, .unauthorized] {
      let provider = FakeProvider()
      let recorder = Recorder()
      let coordinator = FrugaTokenCoordinator(
        provider: { try await provider.provide($0) },
        onToken: { token in Task { await recorder.recordToken(token) } },
        onError: { error in Task { await recorder.recordError(error) } }
      )

      await coordinator.request(reason: reason)
      await provider.waitForCall()
      let calls = await provider.calls
      XCTAssertEqual(calls, [reason], "provider should be called with \(reason) exactly")

      await provider.resolve(.success("token-\(reason.rawValue)"))
      await recorder.waitForToken()

      let tokens = await recorder.tokens
      let errors = await recorder.errors
      XCTAssertEqual(tokens, ["token-\(reason.rawValue)"])
      XCTAssertTrue(errors.isEmpty)
    }
  }

  // MARK: - 2. provider throwing surfaces TOKEN_PROVIDER_FAILED, recoverable,
  //           onToken never called.

  func testProviderFailureEmitsTokenProviderFailed() async {
    struct SomeProviderError: Error {}

    let provider = FakeProvider()
    let recorder = Recorder()
    let coordinator = FrugaTokenCoordinator(
      provider: { try await provider.provide($0) },
      onToken: { token in Task { await recorder.recordToken(token) } },
      onError: { error in Task { await recorder.recordError(error) } }
    )

    await coordinator.request(reason: .ttl)
    await provider.waitForCall()
    await provider.resolve(.failure(SomeProviderError()))
    await recorder.waitForError()

    let errors = await recorder.errors
    let tokens = await recorder.tokens
    XCTAssertEqual(errors.count, 1)
    XCTAssertEqual(errors.first?.code, .tokenProviderFailed)
    XCTAssertEqual(errors.first?.recoverable, true)
    XCTAssertTrue(tokens.isEmpty)
  }

  // MARK: - 3. cancel() while suspended: the provider's task observes the
  //           cancellation and neither callback fires afterwards.

  func testCancelWhileSuspendedPreventsCallbacks() async {
    let provider = FakeProvider()
    let recorder = Recorder()
    let coordinator = FrugaTokenCoordinator(
      provider: { try await provider.provide($0) },
      onToken: { token in Task { await recorder.recordToken(token) } },
      onError: { error in Task { await recorder.recordError(error) } }
    )

    await coordinator.request(reason: .initial)
    await provider.waitForCall()
    await coordinator.cancel()
    await provider.waitForCancellation()

    let observed = await provider.cancellationObserved
    XCTAssertTrue(observed, "the provider's in-flight call should see the cancellation")

    // Give any (incorrect) delivery a moment to happen before asserting silence.
    try? await Task.sleep(nanoseconds: 50_000_000)
    let tokens = await recorder.tokens
    let errors = await recorder.errors
    XCTAssertTrue(tokens.isEmpty, "cancel() must not deliver a token")
    XCTAssertTrue(errors.isEmpty, "cancel() must not deliver an error")
  }

  // MARK: - 4. A second request while one is in flight does not start a
  //           second provider call (dedup); the token is delivered once.

  func testSecondRequestWhileInFlightDoesNotDuplicateProviderCall() async {
    let provider = FakeProvider()
    let recorder = Recorder()
    let coordinator = FrugaTokenCoordinator(
      provider: { try await provider.provide($0) },
      onToken: { token in Task { await recorder.recordToken(token) } },
      onError: { error in Task { await recorder.recordError(error) } }
    )

    await coordinator.request(reason: .initial)
    await provider.waitForCall()
    await coordinator.request(reason: .ttl)
    await provider.resolve(.success("only-once"))
    await recorder.waitForToken()

    let calls = await provider.calls
    let tokens = await recorder.tokens
    XCTAssertEqual(calls, [.initial], "the second request must not start a second provider call")
    XCTAssertEqual(tokens, ["only-once"], "the token must be delivered exactly once")
  }

  // MARK: - 5. A provider throwing CancellationError does not surface as
  //           TOKEN_PROVIDER_FAILED.

  func testProviderThrowingCancellationErrorDoesNotEmitTokenProviderFailed() async {
    let recorder = Recorder()
    let coordinator = FrugaTokenCoordinator(
      provider: { _ in throw CancellationError() },
      onToken: { token in Task { await recorder.recordToken(token) } },
      onError: { error in Task { await recorder.recordError(error) } }
    )

    await coordinator.request(reason: .unauthorized)
    try? await Task.sleep(nanoseconds: 50_000_000)

    let tokens = await recorder.tokens
    let errors = await recorder.errors
    XCTAssertTrue(tokens.isEmpty)
    XCTAssertTrue(errors.isEmpty, "CancellationError must not become TOKEN_PROVIDER_FAILED")
  }

  // MARK: - 6. RED for issue #78 (M2-I06, foreground TTL re-check): lastTokenAt
  //           is nil until a token is delivered to onToken. Contract (not yet
  //           implemented):
  //
  //           `public var lastTokenAt: Date? { get set }` on the actor,
  //           set when `request(reason:)` delivers a token via `onToken`.

  func testLastTokenAtIsNilUntilTokenDelivered() async {
    let provider = FakeProvider()
    let recorder = Recorder()
    let coordinator = FrugaTokenCoordinator(
      provider: { try await provider.provide($0) },
      onToken: { token in Task { await recorder.recordToken(token) } },
      onError: { error in Task { await recorder.recordError(error) } }
    )

    let beforeDelivery = await coordinator.lastTokenAt
    XCTAssertNil(beforeDelivery)

    await coordinator.request(reason: .initial)
    await provider.waitForCall()
    await provider.resolve(.success("token"))
    await recorder.waitForToken()

    let afterDelivery = await coordinator.lastTokenAt
    XCTAssertNotNil(afterDelivery)
  }

  // MARK: - 7. RED for issue #78: needsRefresh(ttl:now:) is false before any
  //           token, false within the TTL, true once the TTL has elapsed.
  //           Contract: `public func needsRefresh(ttl: TimeInterval, now: Date) -> Bool`.

  func testNeedsRefreshBeforeAnyTokenIsFalse() async {
    let coordinator = FrugaTokenCoordinator(
      provider: { _ in "unused" },
      onToken: { _ in },
      onError: { _ in }
    )

    let needsRefresh = await coordinator.needsRefresh(ttl: 60, now: Date())
    XCTAssertFalse(needsRefresh, "no token has been delivered yet, so there is nothing to refresh")
  }

  func testNeedsRefreshWithinTtlIsFalseAndPastTtlIsTrue() async throws {
    let provider = FakeProvider()
    let recorder = Recorder()
    let coordinator = FrugaTokenCoordinator(
      provider: { try await provider.provide($0) },
      onToken: { token in Task { await recorder.recordToken(token) } },
      onError: { _ in }
    )

    await coordinator.request(reason: .initial)
    await provider.waitForCall()
    await provider.resolve(.success("token"))
    await recorder.waitForToken()

    let stored = await coordinator.lastTokenAt
    let deliveredAt = try XCTUnwrap(stored)

    let withinTtl = await coordinator.needsRefresh(ttl: 60, now: deliveredAt.addingTimeInterval(10))
    XCTAssertFalse(withinTtl)

    let pastTtl = await coordinator.needsRefresh(ttl: 60, now: deliveredAt.addingTimeInterval(120))
    XCTAssertTrue(pastTtl)
  }
}

// MARK: - Test doubles

/// Drives a `FrugaTokenProvider` call under deterministic control: the test
/// awaits `waitForCall()` before the provider call is known to be suspended,
/// then resolves it with `resolve(_:)`, or observes cancellation via
/// `withTaskCancellationHandler` when the coordinator cancels the owning task.
private actor FakeProvider {
  private(set) var calls: [TokenRequiredPayload.Reason] = []
  private(set) var cancellationObserved = false
  private var pendingContinuation: CheckedContinuation<String, Error>?
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var cancelWaiters: [CheckedContinuation<Void, Never>] = []

  func provide(_ reason: TokenRequiredPayload.Reason) async throws -> String {
    calls.append(reason)
    resumeStartWaiters()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
        Task { await self.storePending(continuation) }
      }
    } onCancel: {
      Task { await self.handleCancel() }
    }
  }

  func resolve(_ result: Result<String, Error>) {
    pendingContinuation?.resume(with: result)
    pendingContinuation = nil
  }

  func waitForCall() async {
    if !calls.isEmpty { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      startWaiters.append(continuation)
    }
  }

  func waitForCancellation() async {
    if cancellationObserved { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      cancelWaiters.append(continuation)
    }
  }

  private func storePending(_ continuation: CheckedContinuation<String, Error>) {
    pendingContinuation = continuation
  }

  private func handleCancel() {
    cancellationObserved = true
    pendingContinuation?.resume(throwing: CancellationError())
    pendingContinuation = nil
    let waiters = cancelWaiters
    cancelWaiters = []
    waiters.forEach { $0.resume() }
  }

  private func resumeStartWaiters() {
    let waiters = startWaiters
    startWaiters = []
    waiters.forEach { $0.resume() }
  }
}

/// Records what a `FrugaTokenCoordinator` delivered, with continuation-based
/// waiters so tests never guess at a sleep duration for the positive path.
private actor Recorder {
  private(set) var tokens: [String] = []
  private(set) var errors: [FrugaError] = []
  private var tokenWaiters: [CheckedContinuation<Void, Never>] = []
  private var errorWaiters: [CheckedContinuation<Void, Never>] = []

  func recordToken(_ token: String) {
    tokens.append(token)
    let waiters = tokenWaiters
    tokenWaiters = []
    waiters.forEach { $0.resume() }
  }

  func recordError(_ error: FrugaError) {
    errors.append(error)
    let waiters = errorWaiters
    errorWaiters = []
    waiters.forEach { $0.resume() }
  }

  func waitForToken() async {
    if !tokens.isEmpty { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      tokenWaiters.append(continuation)
    }
  }

  func waitForError() async {
    if !errors.isEmpty { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      errorWaiters.append(continuation)
    }
  }
}
