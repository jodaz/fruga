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

/// Owns the shell's load lifecycle: remembers `init` and replays it on every
/// load, so a reload after a content process termination comes back configured.
@MainActor
public final class FrugaShellSession {
  private let transport: FrugaShellTransport
  /// Not `@Sendable`: the session is main-actor isolated and only ever calls
  /// this synchronously on the main actor, so the sink may close over the
  /// caller's state.
  private let onError: (FrugaError) -> Void
  private var initMessage: Data?

  public init(
    transport: FrugaShellTransport,
    onError: @escaping (FrugaError) -> Void
  ) {
    self.transport = transport
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
}
