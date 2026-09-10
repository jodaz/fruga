import FrugaRelayCore

#if canImport(UIKit) && canImport(WebKit)
import UIKit
#endif

/// Partner-facing facade. Semantics match `.agent/rules/native-sdk.md`.
public enum FrugaRelay {}

#if canImport(UIKit) && canImport(WebKit)

extension FrugaRelay {
  /// Weak: the presenter owns the presented controller.
  @MainActor private static weak var presented: FrugaRelayViewController?

  /// Presents the Relay screen full screen from `presenter`.
  @MainActor
  public static func open(
    from presenter: UIViewController,
    initPayload: InitPayload,
    onError: @escaping (FrugaError) -> Void
  ) {
    let controller = FrugaRelayViewController(initPayload: initPayload, onError: onError)
    presented = controller
    presenter.present(controller, animated: true)
    // UIKit creates the presentation controller during `present`.
    controller.presentationController?.delegate = controller
  }

  /// Dismisses the Relay screen, if one is up.
  @MainActor
  public static func close() {
    presented?.dismiss(animated: true)
    presented = nil
  }
}

#endif
