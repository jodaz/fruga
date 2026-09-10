import Foundation

/// What a shell session can do to its WebView. Implemented in the `FrugaRelay`
/// target by the `WKWebView` host; faked in tests.
public protocol FrugaShellTransport: AnyObject, Sendable {
  func reload()
  func send(_ json: Data)
}

/// Owns the shell's load lifecycle: remembers `init` and replays it on every
/// load, so a reload after a content process termination comes back configured.
@MainActor
public final class FrugaShellSession {
  private let transport: FrugaShellTransport
  private let onError: @Sendable (FrugaError) -> Void
  private var initMessage: Data?

  public init(
    transport: FrugaShellTransport,
    onError: @escaping @Sendable (FrugaError) -> Void
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
