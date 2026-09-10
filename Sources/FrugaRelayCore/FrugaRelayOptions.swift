import Foundation

/// Optional `init` fields the partner sets once at `FrugaRelay.configure`.
/// Absent ones are omitted from the bridge message. Mirrors Android's
/// `FrugaRelayOptions`.
public struct FrugaRelayOptions: Equatable, Sendable {
  public var theme: InitPayload.Theme?
  public var primaryColor: String?
  public var userId: String?
  public var apiBaseUrl: String?
  public var locale: String?
  public var debug: Bool

  public init(
    theme: InitPayload.Theme? = nil,
    primaryColor: String? = nil,
    userId: String? = nil,
    apiBaseUrl: String? = nil,
    locale: String? = nil,
    debug: Bool = false
  ) {
    self.theme = theme
    self.primaryColor = primaryColor
    self.userId = userId
    self.apiBaseUrl = apiBaseUrl
    self.locale = locale
    self.debug = debug
  }
}

/// What `FrugaRelay.configure` stored. `InitPayload` stays out of the partner's
/// hands: the screen composes it from this plus the safe area it measures and
/// whatever token the provider last returned.
public struct FrugaRelayConfig: Sendable {
  public let partnerKey: String
  public let tokenProvider: FrugaTokenProvider
  public let options: FrugaRelayOptions

  public init(
    partnerKey: String,
    tokenProvider: @escaping FrugaTokenProvider,
    options: FrugaRelayOptions = FrugaRelayOptions()
  ) {
    self.partnerKey = partnerKey
    self.tokenProvider = tokenProvider
    self.options = options
  }

  public func makeInitPayload(safeArea: SafeArea, token: String?) -> InitPayload {
    InitPayload(
      partnerKey: partnerKey,
      token: token,
      theme: options.theme,
      primaryColor: options.primaryColor,
      userId: options.userId,
      apiBaseUrl: options.apiBaseUrl,
      locale: options.locale,
      safeArea: safeArea,
      debug: options.debug
    )
  }
}
