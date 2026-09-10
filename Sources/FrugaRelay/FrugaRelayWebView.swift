#if canImport(WebKit)

import Foundation
import FrugaRelayCore
import WebKit

/// Glue between a `WKWebView` and `FrugaShellSession`: the transport the session
/// drives, and the navigation delegate that tells it when the shell finished
/// loading or when its content process died. Presentation is issue #76.
///
/// `WKWebView.navigationDelegate` is weak, so the host must retain this object
/// for as long as the WebView is on screen.
@MainActor
public final class FrugaRelayWebView: NSObject, @preconcurrency FrugaShellTransport,
  WKNavigationDelegate
{
  public let webView: WKWebView
  /// Weak: `FrugaShellSession` holds its transport strongly.
  private weak var session: FrugaShellSession?

  public init(webView: WKWebView) {
    self.webView = webView
    super.init()
    webView.navigationDelegate = self
  }

  /// Two-step wiring — the session needs the transport at init, the delegate
  /// needs the session afterwards.
  public func attach(session: FrugaShellSession) {
    self.session = session
  }

  // MARK: - FrugaShellTransport

  public func reload() {
    webView.reload()
  }

  public func send(_ json: Data) {
    guard let literal = Self.jsStringLiteral(json) else { return }
    webView.evaluateJavaScript("window.FrugaNative.receive(\(literal))", completionHandler: nil)
  }

  // MARK: - WKNavigationDelegate

  public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    session?.shellDidLoad()
  }

  public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    session?.processDidTerminate()
  }

  // MARK: - Private

  /// `window.FrugaNative.receive` takes the JSON as a *string*, so the bytes
  /// cross as a JS string literal. `JSONSerialization` does the escaping; a
  /// non-UTF-8 or unencodable payload is dropped rather than injected raw.
  private static func jsStringLiteral(_ json: Data) -> String? {
    guard let text = String(data: json, encoding: .utf8),
      let escaped = try? JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed)
    else { return nil }
    return String(data: escaped, encoding: .utf8)
  }
}

#endif
