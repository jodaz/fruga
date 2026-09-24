import Foundation

/// What a shell session can do to its WebView. Implemented in the `FrugaRelay`
/// target by the `WKWebView` host; faked in tests. Main-actor isolated: every
/// bridge call touches the WebView, so isolation belongs on the protocol rather
/// than on a `Sendable` conformance each implementer has to justify.
@MainActor
public protocol FrugaShellTransport: AnyObject {
  func reload()
  func send(_ json: Data)
}

/// Owns the shell's load lifecycle and the inbound message stream: remembers
/// `init` and replays it on every load (so a reload after a content process
/// termination comes back configured), decodes what the shell sends, and
/// resolves a pending `back` request from the shell's `backResult`.
@MainActor
public final class FrugaShellSession {
  private let transport: FrugaShellTransport
  /// Not `@Sendable`: the session is main-actor isolated and only ever calls
  /// this synchronously on the main actor, so the sink may close over the
  /// caller's state.
  private let onError: (FrugaError) -> Void
  private let onMessage: (FrugaNativeMessage) -> Void
  /// The shell asked for a token. Set by the screen, which forwards the reason
  /// to its `FrugaTokenCoordinator`. Main-actor, like everything else here.
  public var onTokenRequired: ((TokenRequiredPayload.Reason) -> Void)?
  /// The shell asked for a URL to be opened outside the WebView. Set by the
  /// screen, which hands it to the same system browser component the
  /// navigation allowlist uses.
  public var onOpenExternal: ((URL) -> Void)?
  /// An inbound message was dropped. Carries the raw JSON `type` when the body
  /// had one, else `nil` — and nothing else from the body, which is untrusted
  /// (#129). Mirrors Android's `FrugaShellSession.onDropped`.
  public var onDropped: ((String?) -> Void)?
  /// The shell's header X asked to close. Never answered; may fire more than
  /// once. Set by the screen, which dismisses Relay the same way it does for
  /// an unhandled `backResult`.
  public var onClose: (() -> Void)?
  /// The last message handed to `send(_:)` (or replayed as `init`). Internal
  /// on purpose: it is test and diagnostic state, and a partner must not be
  /// able to read a bearer token back out of the session.
  private(set) var lastSent: FrugaHostMessage?
  private var initMessage: Data?
  /// The typed form of `initMessage`, when the caller had one. The bytes stay
  /// the source of truth so a replay is byte-exact.
  private var initHostMessage: FrugaHostMessage?
  private var pendingBack: ((Bool) -> Void)?
  private var backTimeout: Task<Void, Never>?
  /// Unlike `back`, a repeat `getBalance` ask is allowed: every pending caller
  /// resolves from the next `balance`.
  private var pendingBalance: [(Result<FrugaBalance, FrugaError>) -> Void] = []
  private var balanceTimeouts: [Task<Void, Never>] = []

  public init(
    transport: FrugaShellTransport,
    onMessage: @escaping (FrugaNativeMessage) -> Void = { _ in },
    onError: @escaping (FrugaError) -> Void
  ) {
    self.transport = transport
    self.onMessage = onMessage
    self.onError = onError
  }

  /// Remembers the `init` message. It is sent on the next `shellDidLoad()`.
  /// `message` is the typed form of the same bytes, when the caller has one.
  public func start(initMessage: Data, message: FrugaHostMessage? = nil) {
    self.initMessage = initMessage
    initHostMessage = message
  }

  /// Encodes and forwards a host message. An unencodable message is dropped,
  /// like any other malformed bridge traffic.
  public func send(_ message: FrugaHostMessage) {
    guard let json = try? message.encode() else { return }
    lastSent = message
    transport.send(json)
  }

  /// The shell page finished loading — first load or any reload.
  public func shellDidLoad() {
    guard let initMessage else { return }
    if let initHostMessage { lastSent = initHostMessage }
    transport.send(initMessage)
  }

  /// `webViewWebContentProcessDidTerminate`: report it, then reload. No dedup —
  /// a repeated termination is a repeated failure the partner sink must see.
  public func processDidTerminate() {
    onError(
      FrugaError(
        code: .processTerminated,
        message: "WebView content process terminated; reloading the shell",
        recoverable: true
      )
    )
    transport.reload()
  }

  /// Trust boundary for everything the shell posts: malformed or unknown
  /// messages are dropped, never thrown and never crashed on.
  public func receive(_ json: Data) {
    guard let message = try? FrugaNativeMessage.decode(json) else {
      onDropped?(droppedType(json))
      return
    }
    switch message {
    case let .backResult(payload): resolveBack(payload.handled)
    case let .balance(payload):
      resolveBalance(.success(FrugaBalance(available: payload.available, pending: payload.pending)))
    // An outdated shell is reported, not dropped: the message still reaches
    // `onMessage` and the caller decides whether to keep using it.
    case let .ready(payload) where payload.protocolVersion != FrugaRelayVersion.protocolVersion:
      onError(
        FrugaError(
          code: .versionMismatch,
          message: "Shell protocol version \(payload.protocolVersion) does not match "
            + "the SDK's \(FrugaRelayVersion.protocolVersion)",
          recoverable: false
        )
      )
    // A shell-side error also fails a pending `getBalance`: the shell will not
    // answer it after reporting one, so waiting out the timeout is dead time.
    case let .error(payload):
      resolveBalance(
        .failure(
          FrugaError(code: payload.code, message: payload.message, recoverable: payload.recoverable)
        )
      )
    case let .tokenRequired(payload): onTokenRequired?(payload.reason)
    case .close: onClose?()
    case let .openExternal(payload):
      // A malformed URL is dropped, like any other malformed inbound field.
      if let url = URL(string: payload.url) { onOpenExternal?(url) }
    default: break
    }
    onMessage(message)
  }

  /// The `type` of a dropped body, and nothing else from it.
  private func droppedType(_ json: Data) -> String? {
    (try? JSONSerialization.jsonObject(with: json)).flatMap { ($0 as? [String: Any])?["type"] as? String }
  }

  /// Asks the shell for the balance. Completes with the next `balance`, or
  /// `BRIDGE_TIMEOUT` if the shell stays silent. The default timeout matches
  /// the loader's 5s `getBalance` budget.
  public func requestBalance(
    timeout: TimeInterval = 5,
    completion: @escaping (Result<FrugaBalance, FrugaError>) -> Void
  ) {
    guard let message = try? FrugaHostMessage.getBalance.encode() else {
      completion(.failure(Self.balanceTimeoutError))
      return
    }
    transport.send(message)
    pendingBalance.append(completion)
    balanceTimeouts.append(
      Task { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
        guard !Task.isCancelled else { return }
        self?.resolveBalance(.failure(Self.balanceTimeoutError))
      }
    )
  }

  /// The marker that replaces a secret in anything handed to the partner sink.
  /// Parity with Android's `FrugaShellSession.REDACTED`.
  nonisolated static let redacted = "<redacted>"

  private static let balanceTimeoutError = FrugaError(
    code: .bridgeTimeout,
    message: "The shell did not answer getBalance in time",
    recoverable: true
  )

  /// A `balance` with nothing pending is ignored here (it still reaches
  /// `onMessage`).
  private func resolveBalance(_ result: Result<FrugaBalance, FrugaError>) {
    balanceTimeouts.forEach { $0.cancel() }
    balanceTimeouts.removeAll()
    guard !pendingBalance.isEmpty else { return }
    let completions = pendingBalance
    pendingBalance.removeAll()
    completions.forEach { $0(result) }
  }

  /// Asks the shell to handle a back gesture. Completes with the shell's
  /// `handled`, or `false` if it stays silent — the default outcome is that
  /// back closes Relay.
  public func requestBack(timeout: TimeInterval = 1.0, completion: @escaping (Bool) -> Void) {
    // A repeat ask while the shell is still deciding is dropped, not resolved
    // as unhandled: a second sheet drag must never dismiss a screen the shell
    // asked to keep, and the shell must not be spammed with `back`.
    guard pendingBack == nil else { return }
    guard let message = try? FrugaHostMessage.back.encode() else {
      completion(false)
      return
    }
    transport.send(message)
    pendingBack = completion
    backTimeout = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
      guard !Task.isCancelled else { return }
      self?.resolveBack(false)
    }
  }

  /// A `backResult` with no request pending is ignored here (it still reaches
  /// `onMessage`).
  private func resolveBack(_ handled: Bool) {
    backTimeout?.cancel()
    backTimeout = nil
    guard let pendingBack else { return }
    self.pendingBack = nil
    pendingBack(handled)
  }
}

/// What the shell reported for `getBalance`. Mirrors Android's `FrugaBalance`.
public struct FrugaBalance: Equatable, Sendable {
  public let available: Double
  public let pending: Double

  public init(available: Double, pending: Double) {
    self.available = available
    self.pending = pending
  }
}
