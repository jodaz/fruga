import FrugaRelayCore

#if canImport(UIKit) && canImport(WebKit)
import Foundation
import Network
import UIKit
#if canImport(os)
import os
#endif
#endif

/// Partner-facing facade. Names and semantics match Android's `FrugaRelay` and
/// `.agent/rules/native-sdk.md`.
public enum FrugaRelay {}

#if canImport(UIKit) && canImport(WebKit)

extension FrugaRelay {
  /// Set once by `configure`; `open` refuses to present without it.
  @MainActor private static var config: FrugaRelayConfig?
  /// Weak: the presenter owns the presented controller.
  @MainActor private static weak var presented: FrugaRelayViewController?
  /// Weak: any live Relay screen, whether presented by `open(from:)` or hosted
  /// directly by the partner. `getBalance()` answers through this slot, not
  /// `presented`, so a directly hosted screen answers too (Android parity:
  /// `FrugaRelay.onFragmentCreated`/`onFragmentDestroyed`).
  @MainActor private static weak var liveScreen: FrugaRelayViewController?

  /// Test-only: the controller `open(from:onError:)` presented, if still up.
  @MainActor static var presentedController: FrugaRelayViewController? { presented }

  /// Called from `FrugaRelayViewController.viewDidLoad()` and
  /// `viewDidAppear(_:)`.
  @MainActor static func registerHostedScreen(_ controller: FrugaRelayViewController) {
    liveScreen = controller
  }

  /// Called from `FrugaRelayViewController.viewDidDisappear(_:)` via
  /// `relayDidDisappear(isDismissing:)` when the controller is being dismissed
  /// or popped. Identity-guarded: an older screen being torn down must never
  /// clear a newer one's registration.
  @MainActor static func unregisterHostedScreen(_ controller: FrugaRelayViewController) {
    guard liveScreen === controller else { return }
    liveScreen = nil
  }

  /// Partner log sink. Every `FrugaError` and lifecycle event goes here; the
  /// default writes to `os.Logger` and drops `debug` lines unless the partner
  /// configured `debug`. Mirrors Android's `FrugaRelay.logger`.
  @MainActor public static var logger: FrugaLogger = defaultLogger
  @MainActor private static let defaultLogger = OSLogLogger()

  /// Connectivity, as last reported by the path monitor. Overridable in tests;
  /// optimistic until the monitor's first update so a mount is never refused
  /// on a cold start.
  @MainActor static var isOnline = true
  @MainActor private static var monitor: NWPathMonitor?

  /// One monitor for the process: connectivity changes update `isOnline` and
  /// reach the presented screen as a `network` message.
  @MainActor
  private static func startMonitoringNetwork() {
    guard monitor == nil else { return }
    let monitor = NWPathMonitor()
    self.monitor = monitor
    monitor.pathUpdateHandler = { path in
      let online = path.status == .satisfied
      Task { @MainActor in
        isOnline = online
        presented?.networkDidChange(online: online)
      }
    }
    monitor.start(queue: DispatchQueue(label: "uk.co.fruga.relay.network"))
  }

  /// Call once at app start, before `open(from:onError:)`.
  @MainActor
  public static func configure(
    partnerKey: String,
    tokenProvider: @escaping FrugaTokenProvider,
    options: FrugaRelayOptions = FrugaRelayOptions()
  ) {
    config = FrugaRelayConfig(partnerKey: partnerKey, tokenProvider: tokenProvider, options: options)
    (logger as? OSLogLogger)?.isDebugEnabled = options.debug
    startMonitoringNetwork()
  }

  /// Presents the Relay screen as a page sheet from `presenter`.
  @MainActor
  public static func open(
    from presenter: UIViewController,
    onError: @escaping (FrugaError) -> Void = { _ in }
  ) {
    guard let config else {
      let error = FrugaError(
        code: .bootstrapFailed,
        message: "FrugaRelay.configure() has not been called",
        recoverable: false
      )
      logger.error(error)
      onError(error)
      return
    }
    // A second open while a screen is already up is a no-op, not a second sheet.
    guard presented == nil else { return }
    guard isOnline else {
      let error = FrugaError(code: .offline, message: "The device is offline", recoverable: true)
      logger.error(error)
      onError(error)
      return
    }
    let controller = FrugaRelayViewController(config: config, onError: onError)
    presented = controller
    presenter.present(controller, animated: true)
  }

  /// Asks the open Relay screen for the balance. With no screen up there is no
  /// shell to ask, so this fails immediately rather than waiting out the bridge
  /// timeout. Mirrors Android's `FrugaRelay.getBalance`.
  @MainActor
  public static func getBalance(timeout: TimeInterval = 5) async -> Result<FrugaBalance, FrugaError> {
    guard let session = liveScreen?.session else {
      return .failure(
        FrugaError(code: .bridgeTimeout, message: "No Relay screen is open", recoverable: true)
      )
    }
    return await withCheckedContinuation { continuation in
      session.requestBalance(timeout: timeout) { continuation.resume(returning: $0) }
    }
  }

  /// Dismisses the Relay screen, if one is up.
  @MainActor
  public static func close() {
    presented?.performDismiss()
    presented = nil
  }

  /// Test-only: clears the configure/open state between cases.
  @MainActor
  static func reset() {
    config = nil
    presented = nil
    liveScreen = nil
    // `isOnline` is process-global static state and outlives a single test
    // case; a test that sets it false must not leak that into the next one.
    isOnline = true
    // `configure(debug:)` mutates the shared default sink in place, so a reset
    // that only reassigns it would leave debug logging on.
    defaultLogger.isDebugEnabled = false
    logger = defaultLogger
  }
}

/// Default sink: `os.Logger` under subsystem `uk.co.fruga.relay`. `debug` lines
/// are dropped unless the partner configured `debug`, so nothing is written on
/// a release build by default. Mirrors Android's `AndroidLogLogger`.
final class OSLogLogger: FrugaLogger {
  #if canImport(os)
  private let logger = Logger(subsystem: "uk.co.fruga.relay", category: "FrugaRelay")
  #endif
  var isDebugEnabled = false

  func log(level: LogPayload.Level, event: String, data: [String: String]) {
    guard level != .debug || isDebugEnabled else { return }
    let line = data.isEmpty
      ? event
      : ([event] + data.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }).joined(separator: " ")
    #if canImport(os)
    // `.public`: nothing that reaches this sink carries a secret, and a
    // redacted line is useless to a partner debugging an integration.
    switch level {
    case .debug: logger.debug("\(line, privacy: .public)")
    case .info: logger.info("\(line, privacy: .public)")
    case .warn: logger.warning("\(line, privacy: .public)")
    case .error: logger.error("\(line, privacy: .public)")
    }
    #else
    _ = line
    #endif
  }
}

#endif
