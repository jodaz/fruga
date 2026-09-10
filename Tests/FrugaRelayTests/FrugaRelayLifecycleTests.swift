#if canImport(UIKit) && canImport(WebKit)

import WebKit
import XCTest

import FrugaRelayCore
@testable import FrugaRelay

/// RED tests for issue #78 (M2-I06): foreground TTL re-check, cancel on
/// close, network forwarding through the session, and an offline mount
/// short-circuit. Contract (not yet implemented — this file is meant to
/// fail to compile until `ios-owner` adds it):
///
/// ```swift
/// public final class FrugaRelayViewController: UIViewController {
///   var coordinator: FrugaTokenCoordinator? { get }   // internal (was private), for tests
///   func networkDidChange(online: Bool)                // internal, for tests;
///     // forwards FrugaHostMessage.network(online:) through `session.send(_:)`
/// }
///
/// public enum FrugaRelay {
///   static var isOnline: Bool   // internal, test-overridable; default from
///     // NWPathMonitor. open(from:) with isOnline == false calls
///     // onError(.offline) and presents nothing.
/// }
/// ```
///
/// UIKit/WebKit are unavailable on Linux, so this whole file is compiled out
/// there — it only runs in the mirror's macos-15 CI job.
@MainActor
final class FrugaRelayLifecycleTests: XCTestCase {
  private var window: UIWindow?

  override func tearDown() {
    FrugaRelay.close()
    FrugaRelay.reset()
    FrugaRelay.isOnline = true
    window?.isHidden = true
    window = nil
    super.tearDown()
  }

  private func makeConfig(tokenProvider: @escaping FrugaTokenProvider = { _ in "eyJ.test" }) -> FrugaRelayConfig {
    FrugaRelayConfig(
      partnerKey: "partner_test_123",
      tokenProvider: tokenProvider,
      options: FrugaRelayOptions()
    )
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

  // MARK: - Foreground re-entry re-requests the token with reason .ttl once
  //        the last delivered token is older than tokenTtlSeconds (parity
  //        with Android's FrugaRelayFragment / FrugaTokenCoordinator.needsRefresh).

  func testForegroundReRequestsTokenWhenPastTtl() async throws {
    let presenter = makeWindowRootedController()
    let recorder = RecordingTokenProvider()
    let controller = FrugaRelayViewController(
      config: FrugaRelayConfig(
        partnerKey: "partner_test_123",
        tokenProvider: { reason in await recorder.provide(reason) },
        options: FrugaRelayOptions(tokenTtlSeconds: 1)
      ),
      onError: { _ in }
    )
    presenter.present(controller, animated: false)
    _ = try await waitUntilPresented(by: presenter)

    controller.session.receive(
      try JSONEncoder().encode(FrugaNativeMessage.tokenRequired(TokenRequiredPayload(reason: .initial)))
    )
    let initialDeadline = Date().addingTimeInterval(2.0)
    while await recorder.reasons.isEmpty, Date() < initialDeadline {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertEqual(await recorder.reasons, [.initial])

    let coordinator = try XCTUnwrap(controller.coordinator)
    await coordinator.lastTokenAt = Date().addingTimeInterval(-2)

    NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)

    let ttlDeadline = Date().addingTimeInterval(2.0)
    while await recorder.reasons.count < 2, Date() < ttlDeadline {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertEqual(await recorder.reasons, [.initial, .ttl], "resuming past the TTL re-requests a .ttl token")
  }

  // MARK: - Closing while a token request is in flight cancels the
  //        provider's task (belt-and-braces beyond the deinit path already
  //        covered).

  func testClosingCancelsTheInFlightProviderTask() async throws {
    let presenter = makeWindowRootedController()
    let provider = CancellationRecordingProvider()
    let controller = FrugaRelayViewController(
      config: FrugaRelayConfig(
        partnerKey: "partner_test_123",
        tokenProvider: { reason in try await provider.provide(reason) },
        options: FrugaRelayOptions()
      ),
      onError: { _ in }
    )
    presenter.present(controller, animated: false)
    _ = try await waitUntilPresented(by: presenter)

    controller.session.receive(
      try JSONEncoder().encode(FrugaNativeMessage.tokenRequired(TokenRequiredPayload(reason: .initial)))
    )
    await provider.waitForCall()

    controller.performDismiss()
    // The host-less test process drives no real dismissal transition, so
    // `isBeingDismissed` is forced the same way UIKit would report it.
    controller.viewDidDisappear(false)

    let cancelled = await provider.waitForCancellation(timeout: 1.0)
    XCTAssertTrue(cancelled, "the provider's task should observe the cancellation within 1s")
  }

  // MARK: - networkDidChange(online:) forwards FrugaHostMessage.network
  //        through the session. NWPathMonitor itself isn't controllable in
  //        tests, so this is the seam it drives.

  func testNetworkDidChangeForwardsThroughSession() {
    let controller = FrugaRelayViewController(config: makeConfig(), onError: { _ in })

    controller.networkDidChange(online: false)

    XCTAssertEqual(controller.session.lastSent, .network(NetworkPayload(online: false)))
  }

  // MARK: - open(from:) while offline fails with OFFLINE and presents nothing.

  func testOpenWhileOfflineFailsWithOfflineAndPresentsNothing() {
    let presenter = makeWindowRootedController()
    FrugaRelay.configure(partnerKey: "partner_test_123", tokenProvider: { _ in "eyJ.test" }, options: FrugaRelayOptions())
    FrugaRelay.isOnline = false
    var errors: [FrugaError] = []

    FrugaRelay.open(from: presenter, onError: { errors.append($0) })

    XCTAssertEqual(errors.map(\.code), [.offline])
    XCTAssertNil(presenter.presentedViewController)
  }

  // MARK: - A non-http(s) scheme navigation is dropped, not handed to
  //        openExternally (sdk-reviewer follow-up from #76/#77).

  func testNonHttpSchemeNavigationIsDroppedNotOpenedExternally() {
    let controller = FrugaRelayViewController(config: makeConfig(), onError: { _ in })
    var opened: [URL] = []
    controller.openExternally = { opened.append($0) }
    let telURL = URL(string: "tel:123")!

    let allow = controller.handleNavigation(to: telURL, isMainFrame: true)

    XCTAssertFalse(allow)
    XCTAssertTrue(opened.isEmpty, "a non-http(s) scheme must be dropped, not handed to openExternally")
  }
}

// MARK: - Test doubles

/// Records the reasons a `FrugaTokenProvider` closure was called with.
private actor RecordingTokenProvider {
  private(set) var reasons: [TokenRequiredPayload.Reason] = []

  func provide(_ reason: TokenRequiredPayload.Reason) -> String {
    reasons.append(reason)
    return "eyJ.recorded"
  }
}

/// A provider that never resolves except via cancellation, recording whether
/// the coordinator's cancellation reached the in-flight call.
private actor CancellationRecordingProvider {
  private(set) var cancellationObserved = false
  private var called = false
  private var pendingContinuation: CheckedContinuation<String, Error>?
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var cancelWaiters: [CheckedContinuation<Void, Never>] = []

  func provide(_ reason: TokenRequiredPayload.Reason) async throws -> String {
    called = true
    resumeStartWaiters()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
        Task { await self.storePending(continuation) }
      }
    } onCancel: {
      Task { await self.handleCancel() }
    }
  }

  func waitForCall() async {
    if called { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      startWaiters.append(continuation)
    }
  }

  func waitForCancellation(timeout: TimeInterval) async -> Bool {
    if cancellationObserved { return true }
    return await withTaskGroup(of: Bool.self) { group in
      group.addTask { await self.observeCancellation() }
      group.addTask {
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        return false
      }
      let result = (await group.next()) ?? false
      group.cancelAll()
      return result
    }
  }

  private func observeCancellation() async -> Bool {
    if cancellationObserved { return true }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      cancelWaiters.append(continuation)
    }
    return true
  }

  private func storePending(_ continuation: CheckedContinuation<String, Error>) {
    if cancellationObserved {
      continuation.resume(throwing: CancellationError())
    } else {
      pendingContinuation = continuation
    }
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

#endif
