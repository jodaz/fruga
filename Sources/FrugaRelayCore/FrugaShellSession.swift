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
  private var initMessage: Data?
  private var pendingBack: ((Bool) -> Void)?
  private var backTimeout: Task<Void, Never>?

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
  public func start(initMessage: Data) {
    self.initMessage = initMessage
  }

  /// The shell page finished loading — first load or any reload.
  public func shellDidLoad() {
    guard let initMessage else { return }
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
    guard let message = try? FrugaNativeMessage.decode(json) else { return }
    switch message {
    case let .backResult(payload): resolveBack(payload.handled)
    case let .tokenRequired(payload): onTokenRequired?(payload.reason)
    case let .openExternal(payload):
      // A malformed URL is dropped, like any other malformed inbound field.
      if let url = URL(string: payload.url) { onOpenExternal?(url) }
    default: break
    }
    onMessage(message)
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
