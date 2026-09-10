import Foundation

/// Which URLs may leave the WebView. The system browser component only takes
/// web URLs, and handing an arbitrary scheme (`tel:`, `mailto:`, a custom app
/// scheme) to `UIApplication.open` would let the shell deep-link into other
/// apps, so everything but `http`/`https` is dropped and logged.
/// Mirrors Android's rule in `FrugaRelayFragment`.
public enum FrugaExternalURLRule {
  public static func allows(_ url: URL) -> Bool {
    let scheme = url.scheme?.lowercased()
    return scheme == "http" || scheme == "https"
  }
}
