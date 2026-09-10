import FrugaRelayCore

#if canImport(UIKit) && canImport(WebKit)
import Foundation
import Network
import UIKit
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

  /// Test-only: the controller `open(from:onError:)` presented, if still up.
  @MainActor static var presentedController: FrugaRelayViewController? { presented }

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
    monitor.start(queue: DispatchQueue(label: "co.uk.fruga.relay.network"))
  }

  /// Call once at app start, before `open(from:onError:)`.
  @MainActor
  public static func configure(
    partnerKey: String,
    tokenProvider: @escaping FrugaTokenProvider,
    options: FrugaRelayOptions = FrugaRelayOptions()
  ) {
    config = FrugaRelayConfig(partnerKey: partnerKey, tokenProvider: tokenProvider, options: options)
    startMonitoringNetwork()
  }

  /// Presents the Relay screen as a page sheet from `presenter`.
  @MainActor
  public static func open(from presenter: UIViewController, onError: @escaping (FrugaError) -> Void) {
    guard let config else {
      onError(
        FrugaError(
          code: .bootstrapFailed,
          message: "FrugaRelay.configure() has not been called",
          recoverable: false
        )
      )
      return
    }
    // A second open while a screen is already up is a no-op, not a second sheet.
    guard presented == nil else { return }
    guard isOnline else {
      onError(FrugaError(code: .offline, message: "The device is offline", recoverable: true))
      return
    }
    let controller = FrugaRelayViewController(config: config, onError: onError)
    presented = controller
    presenter.present(controller, animated: true)
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
  }
}

#endif
