import Foundation

/// Which top-level navigations may load inside the WebView. Only the CDN origin
/// (the shell) and the API origin are allowed; everything else — and every
/// `openExternal` from the shell — goes to the system browser component.
public struct FrugaNavigationPolicy: Equatable, Sendable {
  public enum Decision: Equatable, Sendable {
    case allow
    case openExternally
  }

  /// The default API origin when the partner did not override `apiBaseUrl`.
  private static let defaultApiOrigin = URL(string: "https://api.fruga.co.uk")!

  /// Normalised `scheme://host[:port]` strings, so a path or query on an
  /// allowed origin compares equal and a scheme downgrade does not.
  private let allowedOrigins: [String]

  public init(allowedOrigins: [URL]) {
    self.allowedOrigins = allowedOrigins.compactMap(Self.origin)
  }

  public static func standard(apiBaseUrl: URL?) -> FrugaNavigationPolicy {
    FrugaNavigationPolicy(allowedOrigins: [FrugaRelayVersion.shellURL, apiBaseUrl ?? defaultApiOrigin])
  }

  /// Only top-level navigation is policed: subframes and subresources are the
  /// widget's own business, and blocking them would break the Relay iframe.
  public func decide(_ url: URL, isMainFrame: Bool) -> Decision {
    guard isMainFrame else { return .allow }
    // `about:blank` / `about:srcdoc` are WebKit's own placeholders.
    if url.scheme?.lowercased() == "about" { return .allow }
    guard let origin = Self.origin(url), allowedOrigins.contains(origin) else { return .openExternally }
    return .allow
  }

  private static func origin(_ url: URL) -> String? {
    guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
    let defaultPort = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
    guard let port = url.port, port != defaultPort else { return "\(scheme)://\(host)" }
    return "\(scheme)://\(host):\(port)"
  }
}
