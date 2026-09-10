import Foundation

/// Compile-time CDN shell version. Bumped only by a release task.
public enum FrugaRelayVersion {
  public static let shell = "1.3.0"

  /// The one place the shell URL is built. Never from partner input.
  public static let shellURL = URL(string: "https://cdn.fruga.co.uk/v/\(shell)/native/index.html")!
}
