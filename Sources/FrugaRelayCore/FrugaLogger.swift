import Foundation

/// Partner log sink. Every `FrugaError` and lifecycle event goes here; the
/// default sink is the platform logger. Levels mirror the shell's `log`
/// message, so a partner sink sees native and shell events in one shape.
/// Mirrors Android's `FrugaLogger`.
///
/// Nothing handed to this protocol carries a token or a partner key.
public protocol FrugaLogger {
  func log(level: LogPayload.Level, event: String, data: [String: String])
}

/// Replaces a `token=` or `partnerKey=` query value wherever it appears in
/// untrusted text. Mirrors Android's `redactSecrets`.
public func redactSecrets(_ value: String) -> String {
  secretQueryValue.stringByReplacingMatches(
    in: value,
    range: NSRange(value.startIndex..., in: value),
    withTemplate: "$1=" + FrugaShellSession.redacted
  )
}

private let secretQueryValue = try! NSRegularExpression(
  pattern: "(token|partnerKey)=[^&\\s\"'#]*",
  options: .caseInsensitive
)

extension FrugaLogger {
  /// Swift has no default arguments in protocol requirements; this overload is
  /// the `data: [:]` default Android declares on the interface itself.
  public func log(level: LogPayload.Level, event: String) {
    log(level: level, event: event, data: [:])
  }

  /// Reports a `FrugaError` on the shared `log` shape — same event name and
  /// keys as Android's `FrugaLogger.error`.
  public func error(_ error: FrugaError) {
    log(
      level: .error,
      event: "error",
      data: [
        "code": error.code.rawValue,
        "message": error.message,
        "recoverable": String(error.recoverable)
      ]
    )
  }
}
