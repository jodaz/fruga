#if canImport(UIKit) && canImport(WebKit)

import FrugaRelayCore
import UIKit
import WebKit

/// Hosts the CDN shell full screen. Owns the `WKWebView`, the `fruga` script
/// message handler the shell posts to, and the `FrugaShellSession` that drives
/// the bridge.
///
/// Swipe-down / sheet pull never dismisses directly: it asks the shell first
/// (`back`) and only dismisses when the shell reports the gesture unhandled.
public final class FrugaRelayViewController: UIViewController {
  /// The shell's script message handler name (`window.webkit.messageHandlers.fruga`).
  private static let handlerName = "fruga"
  private static let shellURL = URL(
    string: "https://cdn.fruga.co.uk/v/\(FrugaRelayVersion.shell)/native/index.html"
  )

  let webView: WKWebView
  let session: FrugaShellSession
  /// Retained: `WKWebView.navigationDelegate` is weak.
  private let bridge: FrugaRelayWebView
  private let messageProxy: ScriptMessageProxy
  private let initPayload: InitPayload

  public init(initPayload: InitPayload, onError: @escaping (FrugaError) -> Void) {
    let configuration = WKWebViewConfiguration()
    let proxy = ScriptMessageProxy()
    configuration.userContentController.add(proxy, name: Self.handlerName)

    self.initPayload = initPayload
    messageProxy = proxy
    webView = WKWebView(frame: .zero, configuration: configuration)
    bridge = FrugaRelayWebView(webView: webView)
    session = FrugaShellSession(transport: bridge, onError: onError)
    super.init(nibName: nil, bundle: nil)

    bridge.attach(session: session)
    // Weak, so the WebView's content controller does not retain this controller.
    proxy.session = session
    modalPresentationStyle = .fullScreen
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  deinit {
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
    // Harmless when the presentation controller does not exist yet; `open` sets
    // it again once UIKit has created one.
    presentationController?.delegate = self

    if let message = try? FrugaHostMessage.`init`(initPayload).encode() {
      session.start(initMessage: message)
    }
    guard let shellURL = Self.shellURL else { return }
    webView.load(URLRequest(url: shellURL))
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
