import Foundation

/// Shell -> native bridge messages. Contract of record: `docs/PRD.md` §5.7 and
/// `packages/loader/src/native/FrugaNativeMessage.ts`; samples are the fixtures
/// in `packages/loader/src/native/fixtures/*.json`.
///
/// The envelope is flat — `{ "type": "balance", "available": 12.5, ... }` — so
/// each payload decodes from the same keyed container as the discriminator.
public enum FrugaNativeMessage: Codable, Equatable {
  case ready(ReadyPayload)
  case tokenRequired(TokenRequiredPayload)
  case balance(BalancePayload)
  case openExternal(OpenExternalPayload)
  case backResult(BackResultPayload)
  case error(ErrorPayload)
  case log(LogPayload)

  /// Trust boundary: unknown `type` values and out-of-range enum values throw.
  public static func decode(_ json: Data) throws -> FrugaNativeMessage {
    try JSONDecoder().decode(FrugaNativeMessage.self, from: json)
  }

  private enum EnvelopeKey: String, CodingKey {
    case type
  }

  private enum Kind: String, Codable {
    case ready, tokenRequired, balance, openExternal, backResult, error, log
  }

  public init(from decoder: Decoder) throws {
    let kind = try decoder.container(keyedBy: EnvelopeKey.self).decode(Kind.self, forKey: .type)
    switch kind {
    case .ready: self = .ready(try ReadyPayload(from: decoder))
    case .tokenRequired: self = .tokenRequired(try TokenRequiredPayload(from: decoder))
    case .balance: self = .balance(try BalancePayload(from: decoder))
    case .openExternal: self = .openExternal(try OpenExternalPayload(from: decoder))
    case .backResult: self = .backResult(try BackResultPayload(from: decoder))
    case .error: self = .error(try ErrorPayload(from: decoder))
    case .log: self = .log(try LogPayload(from: decoder))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var envelope = encoder.container(keyedBy: EnvelopeKey.self)
    switch self {
    case let .ready(payload):
      try envelope.encode(Kind.ready, forKey: .type)
      try payload.encode(to: encoder)
    case let .tokenRequired(payload):
      try envelope.encode(Kind.tokenRequired, forKey: .type)
      try payload.encode(to: encoder)
    case let .balance(payload):
      try envelope.encode(Kind.balance, forKey: .type)
      try payload.encode(to: encoder)
    case let .openExternal(payload):
      try envelope.encode(Kind.openExternal, forKey: .type)
      try payload.encode(to: encoder)
    case let .backResult(payload):
      try envelope.encode(Kind.backResult, forKey: .type)
      try payload.encode(to: encoder)
    case let .error(payload):
      try envelope.encode(Kind.error, forKey: .type)
      try payload.encode(to: encoder)
    case let .log(payload):
      try envelope.encode(Kind.log, forKey: .type)
      try payload.encode(to: encoder)
    }
  }
}

/// A mismatched `protocolVersion` still decodes: the caller answers with
/// `VERSION_MISMATCH` rather than dropping the message.
public struct ReadyPayload: Codable, Equatable {
  public let protocolVersion: Int
  public let sdkVersion: String
}

public struct TokenRequiredPayload: Codable, Equatable {
  public enum Reason: String, Codable, Sendable {
    case initial, ttl, unauthorized
  }

  public let reason: Reason

  public init(reason: Reason) {
    self.reason = reason
  }
}

public struct BalancePayload: Codable, Equatable {
  public let available: Double
  public let pending: Double
}

public struct OpenExternalPayload: Codable, Equatable {
  public let url: String
}

public struct BackResultPayload: Codable, Equatable {
  public let handled: Bool

  public init(handled: Bool) {
    self.handled = handled
  }
}

public struct ErrorPayload: Codable, Equatable {
  public enum Code: String, Codable, Sendable {
    case timeout = "TIMEOUT"
    case versionMismatch = "VERSION_MISMATCH"
    case bootstrapFailed = "BOOTSTRAP_FAILED"
    case offline = "OFFLINE"
    case bridgeTimeout = "BRIDGE_TIMEOUT"
    case processTerminated = "PROCESS_TERMINATED"
    case tokenProviderFailed = "TOKEN_PROVIDER_FAILED"
    /// Native-raised only; the shell never sends it. iOS enforces the engine
    /// floor (WebKit as shipped in Safari 16.4) through the deployment target,
    /// so this SDK never raises it itself. The case exists so the `FrugaError`
    /// code set matches the other platforms, where Android checks the WebView
    /// version at runtime.
    case unsupportedEngine = "UNSUPPORTED_ENGINE"
  }

  public let code: Code
  public let message: String
  public let recoverable: Bool
}

public struct LogPayload: Codable, Equatable {
  public enum Level: String, Codable {
    case debug, info, warn, error
  }

  public let level: Level
  public let event: String
  /// The TS side types this as `unknown`, so it is carried as the raw
  /// re-serialisable JSON bytes of whatever the shell sent.
  public let data: Data?

  private enum CodingKeys: String, CodingKey {
    case level, event, data
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    level = try container.decode(Level.self, forKey: .level)
    event = try container.decode(String.self, forKey: .event)
    data = try container.decodeIfPresent(JSONValue.self, forKey: .data)?.serialized()
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(level, forKey: .level)
    try container.encode(event, forKey: .event)
    try container.encodeIfPresent(data.map(JSONValue.init(serialized:)), forKey: .data)
  }
}

/// Minimal `unknown`-shaped JSON value, used only to carry `log.data` across
/// the bridge without inspecting it.
private enum JSONValue: Codable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case let .bool(value): try container.encode(value)
    case let .number(value): try container.encode(value)
    case let .string(value): try container.encode(value)
    case let .array(value): try container.encode(value)
    case let .object(value): try container.encode(value)
    }
  }

  init(serialized: Data) {
    self = (try? JSONDecoder().decode(JSONValue.self, from: serialized)) ?? .null
  }

  func serialized() throws -> Data {
    try JSONEncoder().encode(self)
  }
}
