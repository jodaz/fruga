import FrugaRelayCore

#if canImport(UIKit) && canImport(WebKit)
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

  /// Call once at app start, before `open(from:onError:)`.
  @MainActor
  public static func configure(
    partnerKey: String,
    tokenProvider: @escaping FrugaTokenProvider,
    options: FrugaRelayOptions = FrugaRelayOptions()
  ) {
    config = FrugaRelayConfig(partnerKey: partnerKey, tokenProvider: tokenProvider, options: options)
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
    let controller = FrugaRelayViewController(config: config, onError: onError)
    presented = controller
    presenter.present(controller, animated: true)
    // UIKit creates the presentation controller during `present`.
    controller.presentationController?.delegate = controller
  }

  /// Dismisses the Relay screen, if one is up.
  @MainActor
  public static func close() {
    presented?.dismiss(animated: presented?.dismissAnimated ?? true)
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
