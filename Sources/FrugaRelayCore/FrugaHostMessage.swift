import Foundation

/// Native -> shell bridge messages. Contract of record: `docs/PRD.md` §5.7;
/// samples are the fixtures in `packages/loader/src/native/fixtures/*.json`.
/// Mirrors the shell -> native `FrugaNativeMessage` in this module and the
/// Android `FrugaHostMessage` in `packages/android/relay`.
///
/// The envelope is flat — `{ "type": "tokenUpdate", "token": "..." }` — so the
/// payload encodes into the same keyed container as the discriminator.
public enum FrugaHostMessage: Encodable, Equatable, Sendable {
  case `init`(InitPayload)
  case tokenUpdate(TokenUpdatePayload)
  case network(NetworkPayload)
  case back
  case getBalance

  /// The bytes handed to `window.FrugaNative.receive`.
  public func encode() throws -> Data {
    try JSONEncoder().encode(self)
  }

  private enum EnvelopeKey: String, CodingKey {
    case type
  }

  private enum Kind: String, Encodable {
    case `init`, tokenUpdate, network, back, getBalance
  }

  public func encode(to encoder: Encoder) throws {
    var envelope = encoder.container(keyedBy: EnvelopeKey.self)
    switch self {
    case let .`init`(payload):
      try envelope.encode(Kind.`init`, forKey: .type)
      try payload.encode(to: encoder)
    case let .tokenUpdate(payload):
      try envelope.encode(Kind.tokenUpdate, forKey: .type)
      try payload.encode(to: encoder)
    case let .network(payload):
      try envelope.encode(Kind.network, forKey: .type)
      try payload.encode(to: encoder)
    case .back:
      try envelope.encode(Kind.back, forKey: .type)
    case .getBalance:
      try envelope.encode(Kind.getBalance, forKey: .type)
    }
  }
}

/// Absent optionals are omitted from the JSON, never sent as `null` — the
/// synthesised encoder uses `encodeIfPresent` for each optional.
public struct InitPayload: Encodable, Equatable, Sendable {
  /// Wire values are lowercase; a raw `String` would let a typo reach the
  /// shell's validator. Mirrors Android's `FrugaHostMessage.Theme`.
  public enum Theme: String, Codable, Equatable, Sendable {
    case light, dark
  }

  public let partnerKey: String
  public let token: String?
  public let theme: Theme?
  public let primaryColor: String?
  public let userId: String?
  public let apiBaseUrl: String?
  public let locale: String?
  public let safeArea: SafeArea
  public let debug: Bool

  public init(
    partnerKey: String,
    token: String? = nil,
    theme: Theme? = nil,
    primaryColor: String? = nil,
    userId: String? = nil,
    apiBaseUrl: String? = nil,
    locale: String? = nil,
    safeArea: SafeArea,
    debug: Bool
  ) {
    self.partnerKey = partnerKey
    self.token = token
    self.theme = theme
    self.primaryColor = primaryColor
    self.userId = userId
    self.apiBaseUrl = apiBaseUrl
    self.locale = locale
    self.safeArea = safeArea
    self.debug = debug
  }
}

public struct SafeArea: Encodable, Equatable, Sendable {
  public let top: Int
  public let right: Int
  public let bottom: Int
  public let left: Int

  public init(top: Int, right: Int, bottom: Int, left: Int) {
    self.top = top
    self.right = right
    self.bottom = bottom
    self.left = left
  }
}

public struct TokenUpdatePayload: Encodable, Equatable, Sendable {
  public let token: String

  public init(token: String) {
    self.token = token
  }
}

public struct NetworkPayload: Encodable, Equatable, Sendable {
  public let online: Bool

  public init(online: Bool) {
    self.online = online
  }
}
