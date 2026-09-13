import Foundation

/// Compile-time CDN shell version. Bumped only by a release task.
public enum FrugaRelayVersion {
  public static let shell = "1.3.0"

  /// The bridge protocol version this SDK speaks. A `ready` whose
  /// `protocolVersion` differs is reported as `VERSION_MISMATCH`. Mirrors
  /// Android's `FrugaRelayVersion.protocolVersion`.
  public static let protocolVersion = 1

  /// The one place the shell URL is built. Never from partner input.
  public static let shellURL = URL(string: "https://cdn.fruga.co.uk/v/\(shell)/native/index.html")!
}
