#if canImport(UIKit) && canImport(WebKit)

import FrugaRelayCore
import SafariServices
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
  /// Only the CDN and API origins load in the WebView.
  let policy: FrugaNavigationPolicy
  /// Everything the policy rejects, plus the shell's `openExternal`. `lazy` so
  /// tests can swap it before the first navigation.
  lazy var openExternally: (URL) -> Void = { [weak self] url in
    // `SFSafariViewController` only takes http(s) and only works once we are
    // in a window. Anything else is dropped rather than handed to the system:
    // the bridge must not drive-launch third-party apps.
    guard let self, self.view.window != nil, FrugaExternalURLRule.allows(url) else { return }
    self.present(SFSafariViewController(url: url), animated: true)
  }
  var coordinator: FrugaTokenCoordinator?
  /// A token, not `removeObserver(self)`: `deinit` is nonisolated and may not
  /// touch main-actor state, and passing `self` to the notification centre
  /// counts as touching it.
  nonisolated(unsafe) private var foregroundObserver: NSObjectProtocol?
  /// The `init` payload the session started with. Composed in `viewDidLoad`,
  /// before the shell load can report back, and re-composed whenever the
  /// measured safe area turns out different.
  private(set) var lastInitPayload: InitPayload?
  /// Seam for host-less test processes, where the real dismissal never
  /// completes because no app drives the transition. `nil` in an app, where
  /// `performDismiss` runs the real `dismiss(animated:)`.
  var dismissHandler: (() -> Void)?
  /// Seam for tests that mount the view without a network round trip to the
  /// CDN shell. Set before the view loads; always `true` in an app.
  var loadsShellAutomatically = true

  /// Every dismissal site goes through here so tests can observe it.
  func performDismiss() {
    if let dismissHandler {
      dismissHandler()
    } else {
      dismiss(animated: true)
    }
  }

  public init(config: FrugaRelayConfig, onError: @escaping (FrugaError) -> Void) {
    let configuration = WKWebViewConfiguration()
    let proxy = ScriptMessageProxy()
    configuration.userContentController.add(proxy, name: Self.handlerName)

    self.config = config
    self.onError = onError
    policy = .standard(apiBaseUrl: config.options.apiBaseUrl.flatMap(URL.init(string:)))
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
    // Read through the property, so a replacement set after init is honoured.
    // Only web URLs leave the WebView; any other scheme is dropped.
    session.onOpenExternal = { [weak self] url in
      guard FrugaExternalURLRule.allows(url) else { return }
      self?.openExternally(url)
    }
    bridge.shouldAllowNavigation = { [weak self] url, isMainFrame in
      self?.handleNavigation(to: url, isMainFrame: isMainFrame) ?? false
    }
    foregroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.applicationWillEnterForeground() }
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  deinit {
    if let foregroundObserver {
      NotificationCenter.default.removeObserver(foregroundObserver)
    }
    // The provider is cancelled in `viewDidDisappear`; `deinit` cannot touch
    // the coordinator, which is main-actor state.
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

    // Registered before the load starts: a `didFinish` that beats the first
    // layout pass must still find an `init` to send (parity with Android's
    // `FrugaRelayFragment`, which registers `init` before `loadUrl`).
    registerInitPayload()

    guard loadsShellAutomatically else { return }
    webView.load(URLRequest(url: FrugaRelayVersion.shellURL))
  }

  public override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    // Wired here rather than at the presenting call site, so every presenter
    // gets the ask-the-shell-first swipe-down behaviour.
    presentationController?.delegate = self
  }

  /// The safe area is only real once the view has been laid out in its window,
  /// so the payload registered in `viewDidLoad` is refreshed here as soon as
  /// the measured insets differ (first layout, rotation, keyboard).
  public override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    guard lastInitPayload?.safeArea != currentSafeArea() else { return }
    registerInitPayload()
  }

  /// Composes `init` from the safe area measured right now and hands it to the
  /// session, which replays it on every load.
  private func registerInitPayload() {
    let payload = config.makeInitPayload(safeArea: currentSafeArea(), token: nil)
    let message = FrugaHostMessage.`init`(payload)
    do {
      session.start(initMessage: try message.encode(), message: message)
      lastInitPayload = payload
    } catch {
      // Nothing can be mounted without an `init`, so this is terminal, not silent.
      onError(
        FrugaError(
          code: .bootstrapFailed,
          message: "Could not encode the init message: \(type(of: error))",
          recoverable: false
        )
      )
    }
  }

  public override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    relayDidDisappear(isDismissing: isBeingDismissed)
  }

  /// Seam over `isBeingDismissed`, which UIKit only sets under a real
  /// presentation; a host-less test process can never make it true.
  func relayDidDisappear(isDismissing: Bool) {
    guard isDismissing, let coordinator else { return }
    Task { await coordinator.cancel() }
  }

  // MARK: - Internal

  /// `true` lets the WebView load the navigation; `false` means the policy sent
  /// it to the system browser instead.
  func handleNavigation(to url: URL, isMainFrame: Bool) -> Bool {
    switch policy.decide(url, isMainFrame: isMainFrame) {
    case .allow:
      return true
    case .openExternally:
      // Non-web schemes are dropped rather than handed to the system.
      if FrugaExternalURLRule.allows(url) { openExternally(url) }
      return false
    }
  }

  /// Connectivity changed: tell the shell.
  func networkDidChange(online: Bool) {
    session.send(.network(NetworkPayload(online: online)))
  }

  private func applicationWillEnterForeground() {
    guard let ttl = config.options.tokenTtlSeconds, let coordinator else { return }
    Task {
      guard await coordinator.needsRefresh(ttl: ttl, now: Date()) else { return }
      await coordinator.request(reason: .ttl)
    }
  }

  private func sendTokenUpdate(_ token: String) {
    // Through the session, so it stays the single path to the shell.
    session.send(.tokenUpdate(TokenUpdatePayload(token: token)))
  }

  func currentSafeArea() -> SafeArea {
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
      // `dismiss` on a controller that is no longer presented walks up to its
      // presenter, so a late answer must not close someone else's screen.
      guard !handled, let self, self.presentingViewController != nil else { return }
      self.performDismiss()
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
