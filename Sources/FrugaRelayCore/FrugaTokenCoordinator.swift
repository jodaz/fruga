import Foundation

/// Partner-supplied token source. Called with the reason the shell asked
/// (`initial`, `ttl`, `unauthorized`) and cancelled when Relay closes.
public typealias FrugaTokenProvider = @Sendable (TokenRequiredPayload.Reason) async throws -> String

/// The error surfaced to the partner sink. Codes are shared with the bridge's
/// `error` message so both sides speak `.agent/rules/native-sdk.md` exactly.
public struct FrugaError: Error, Equatable, Sendable {
  public let code: ErrorPayload.Code
  public let message: String
  public let recoverable: Bool

  public init(code: ErrorPayload.Code, message: String, recoverable: Bool) {
    self.code = code
    self.message = message
    self.recoverable = recoverable
  }
}

/// Serialises token requests: one provider call in flight at a time, cancelled
/// on close, and never a callback after `cancel()`.
public actor FrugaTokenCoordinator {
  private let provider: FrugaTokenProvider
  private let onToken: @Sendable (String) -> Void
  private let onError: @Sendable (FrugaError) -> Void
  private var inFlight: Task<Void, Never>?
  /// When a token was last delivered to `onToken`, for the foreground TTL
  /// re-check. `nonisolated(unsafe)`: a `Date?` write is atomic enough for a
  /// staleness check, and the screen reads it from the main actor.
  // ponytail: plain stored Date?, revisit if it ever needs to be transactional
  nonisolated(unsafe) public var lastTokenAt: Date?

  public init(
    provider: @escaping FrugaTokenProvider,
    onToken: @escaping @Sendable (String) -> Void,
    onError: @escaping @Sendable (FrugaError) -> Void
  ) {
    self.provider = provider
    self.onToken = onToken
    self.onError = onError
  }

  public func request(reason: TokenRequiredPayload.Reason) {
    guard inFlight == nil else { return }
    inFlight = Task { [provider, onToken, onError] in
      do {
        let token = try await provider(reason)
        guard !Task.isCancelled else { return }
        self.lastTokenAt = Date()
        onToken(token)
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        // Never the token, and never the provider's own payload: only its type.
        onError(
          FrugaError(
            code: .tokenProviderFailed,
            message: "Token provider failed: \(type(of: error))",
            recoverable: true
          )
        )
      }
      self.finish()
    }
  }

  /// `true` once the last delivered token is older than `ttl`. No token yet
  /// means nothing to refresh.
  public func needsRefresh(ttl: TimeInterval, now: Date) -> Bool {
    guard let lastTokenAt else { return false }
    return now.timeIntervalSince(lastTokenAt) >= ttl
  }

  /// Seam for tests and the foreground TTL re-check: record a delivery time
  /// without exposing a public setter.
  internal func markTokenDelivered(at date: Date) {
    lastTokenAt = date
  }

  public func cancel() {
    inFlight?.cancel()
    inFlight = nil
  }

  private func finish() {
    inFlight = nil
  }
}
