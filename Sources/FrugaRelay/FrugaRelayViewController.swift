#if canImport(UIKit) && canImport(WebKit)

import FrugaRelayCore
import UIKit
import WebKit

/// Hosts the CDN shell in a page sheet. Owns the `WKWebView`, the `fruga`
/// script message handler the shell posts to, the `FrugaShellSession` that
/// drives the bridge, and the `FrugaTokenCoordinator` that answers the shell's
/// `tokenRequired`.
///
/// Swipe-down / sheet pull never dismisses directly: it asks the shell first
/// (`back`) and only dismisses when the shell reports the gesture unhandled.
public final class FrugaRelayViewController: UIViewController {
  /// The shell's script message handler name (`window.webkit.messageHandlers.fruga`).
  private static let handlerName = "fruga"

  let webView: WKWebView
  let session: FrugaShellSession
  /// Retained: `WKWebView.navigationDelegate` is weak.
  private let bridge: FrugaRelayWebView
  private let messageProxy: ScriptMessageProxy
  private let config: FrugaRelayConfig
  private let onError: (FrugaError) -> Void
  /// Not `lazy`: `deinit` must be able to cancel it without creating one.
  private var coordinator: FrugaTokenCoordinator?

  public init(config: FrugaRelayConfig, onError: @escaping (FrugaError) -> Void) {
    let configuration = WKWebViewConfiguration()
    let proxy = ScriptMessageProxy()
    configuration.userContentController.add(proxy, name: Self.handlerName)

    self.config = config
    self.onError = onError
    messageProxy = proxy
    webView = WKWebView(frame: .zero, configuration: configuration)
    bridge = FrugaRelayWebView(webView: webView)
    session = FrugaShellSession(transport: bridge, onError: onError)
    super.init(nibName: nil, bundle: nil)

    bridge.attach(session: session)
    // Weak, so the WebView's content controller does not retain this controller.
    proxy.session = session
    // A page sheet, not `.fullScreen`: `.fullScreen` never asks its delegate
    // whether it should dismiss, so swipe-down could not consult the shell.
    modalPresentationStyle = .pageSheet

    // The coordinator's callbacks may resolve off-main; they hop back before
    // touching the WebView or the partner sink.
    let coordinator = FrugaTokenCoordinator(
      provider: config.tokenProvider,
      onToken: { [weak self] token in
        Task { @MainActor in self?.sendTokenUpdate(token) }
      },
      onError: { [weak self] error in
        Task { @MainActor in self?.onError(error) }
      }
    )
    self.coordinator = coordinator
    session.onTokenRequired = { reason in
      Task { await coordinator.request(reason: reason) }
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  deinit {
    // The provider is cancelled on close; this is the belt-and-braces path for
    // a controller that is released without ever being dismissed.
    if let coordinator {
      Task { await coordinator.cancel() }
    }
    // The content controller retains its handlers for as long as the WebView
    // lives. `deinit` is nonisolated and the WebView is main-actor state, so
    // only touch it when UIKit deallocates us on the main thread (it does);
    // otherwise the handler dies with the WebView anyway.
    guard Thread.isMainThread else { return }
    MainActor.assumeIsolated {
      webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
    }
  }

  public override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    webView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(webView)
    NSLayoutConstraint.activate([
      webView.topAnchor.constraint(equalTo: view.topAnchor),
      webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
    ])

    let payload = config.makeInitPayload(safeArea: currentSafeArea(), token: nil)
    do {
      session.start(initMessage: try FrugaHostMessage.`init`(payload).encode())
    } catch {
      // Nothing can be mounted without an `init`, so this is terminal, not silent.
      onError(
        FrugaError(
          code: .bootstrapFailed,
          message: "Could not encode the init message: \(type(of: error))",
          recoverable: false
        )
      )
      return
    }
    webView.load(URLRequest(url: FrugaRelayVersion.shellURL))
  }

  public override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    guard isBeingDismissed, let coordinator else { return }
    Task { await coordinator.cancel() }
  }

  // MARK: - Internal

  private func sendTokenUpdate(_ token: String) {
    guard let message = try? FrugaHostMessage.tokenUpdate(TokenUpdatePayload(token: token)).encode() else { return }
    bridge.send(message)
  }

  private func currentSafeArea() -> SafeArea {
    let insets = view.safeAreaInsets
    return SafeArea(
      top: Int(insets.top),
      right: Int(insets.right),
      bottom: Int(insets.bottom),
      left: Int(insets.left)
    )
  }
}

// MARK: - Swipe-down / sheet pull

extension FrugaRelayViewController: UIAdaptivePresentationControllerDelegate {
  /// Never dismiss on the gesture itself: ask the shell, and dismiss only when
  /// it reports the back unhandled (`requestBack` defaults to unhandled if the
  /// shell stays silent, so a wedged shell still closes).
  public func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
    session.requestBack { [weak self] handled in
      guard !handled else { return }
      self?.dismiss(animated: true)
    }
    return false
  }
}

// MARK: - Script message handler

/// Stands between the WebView's content controller and the session so the
/// controller is not retained by its own WebView.
@MainActor
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
  weak var session: FrugaShellSession?

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    let json: Data
    switch message.body {
    case let text as String: json = Data(text.utf8)
    case let data as Data: json = data
    default: return
    }
    session?.receive(json)
  }
}

#endif
