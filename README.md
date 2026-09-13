# Fruga Relay for iOS

The Relay cashback screen as a Swift package. It is a `WKWebView` hosting the Fruga CDN
shell page plus a JSON bridge — your app never talks to the Fruga API and never handles
the widget document.

SwiftPM package `FrugaRelay`, one product of the same name vending two modules:
`FrugaRelayCore` (the bridge, Foundation only) and `FrugaRelay` (the screen and the
facade, UIKit/WebKit).

CI for this package runs in the public mirror repo (`IOS_MIRROR_REPO` in Actions variables).

## Install

The published SwiftPM form arrives with milestone M4; until then, use the local package
dependency shown here.

```swift
// Package.swift
dependencies: [
  .package(path: "../../packages/ios")
],
targets: [
  // A path dependency's identity is the directory name, hence `package: "ios"`.
  .target(name: "YourApp", dependencies: [.product(name: "FrugaRelay", package: "ios")])
]
```

In an Xcode project: **File → Add Package Dependencies… → Add Local…** and pick
`packages/ios`.

## Floors

| | Value |
|---|---|
| Deployment target | iOS **16.4** |
| Xcode | **16** or newer |
| Swift tools version | 6.0 |
| Runtime dependencies | none |

The Relay CSS is Tailwind v4 output (cascade layers, `oklch`, `@property`), so WebKit as
shipped in Safari 16.4 is a hard engine floor. On iOS the deployment target **is** the
enforcement: WebKit tracks the OS, so a device that can install your app can render the
widget and no runtime version check exists. Xcode 16 is required because both library
targets build in Swift 6 language mode.

## Configure

Call once, at app start:

```swift
import FrugaRelay

FrugaRelay.configure(
  partnerKey: "pk_live_…",
  tokenProvider: { reason in try await api.frugaToken(reason) },
  options: FrugaRelayOptions(
    theme: .light,
    primaryColor: "#1D4ED8",
    userId: "user-42",
    apiBaseUrl: nil,          // nil = production
    locale: "en-GB",
    tokenTtlSeconds: 900,
    debug: false
  )
)
```

| Option | Effect |
|---|---|
| `theme` | `.light` / `.dark`, forwarded in `init` |
| `primaryColor` | Widget accent colour |
| `userId` | Partner-side user identifier |
| `apiBaseUrl` | Non-production API origin; also becomes an allowlisted origin for in-WebView navigation |
| `locale` | BCP-47 tag |
| `tokenTtlSeconds` | Token lifetime; drives the foreground re-check below. `nil` disables it |
| `debug` | Forwarded to the shell as `init.debug`. Off by default |

Absent options are omitted from the bridge message, never sent as `null`.

## Presenting Relay

```swift
FrugaRelay.open(from: self) { error in
  print(error.code, error.message, error.recoverable)
}

FrugaRelay.close()
```

Both are `@MainActor`. `configure`, `open`, `close`, `getBalance` and `logger` are the
**facade's** whole surface — `FrugaRelayViewController`, `FrugaRelayWebView`, `FrugaShellSession`,
`FrugaRelayConfig`, `FrugaRelayVersion` and all of `FrugaRelayCore` are public too, but
you need none of them.
`onError` is optional (it defaults to a no-op) and receives both native errors and the
shell's own `error` messages.
`open(from:onError:)` reports `BOOTSTRAP_FAILED` if `configure` was never called and
`OFFLINE` if the device has no connectivity; a second `open` while a screen is up is a
no-op. The screen:

- loads `https://cdn.fruga.co.uk/v/<FrugaRelayVersion.shell>/native/index.html` — the
  version is a compile-time constant, never built from partner input;
- measures `view.safeAreaInsets` (so your `additionalSafeAreaInsets` are included) and
  sends them as `init.safeArea`. When the measurement changes, `init` is re-registered so
  a later reload replays the fresh insets; a rotation after the shell has loaded does not
  reach the shell;
- recovers from a WebView content-process termination: `PROCESS_TERMINATED` is reported,
  the shell is reloaded and `init` replayed byte-exactly.

## Balance

```swift
switch await FrugaRelay.getBalance() {          // @MainActor, default timeout 5s
case let .success(balance): print(balance.available, balance.pending)
case let .failure(error): print(error.code)
}
```

Asks any live Relay screen over the bridge — one presented by `open(from:)` or one you
host directly with `FrugaRelayViewController`. "Live" means registered: `viewDidLoad`
registers the screen, `viewDidDisappear` unregisters it when the screen is being
dismissed or popped (`isBeingDismissed || isMovingFromParent`), and `viewDidAppear`
re-registers it. A controller you dismissed or popped no longer answers `getBalance()`
even if you still hold a reference to it. With no screen up there is no shell to ask,
so it fails immediately with `BRIDGE_TIMEOUT` rather than waiting out the timeout; a shell
that stays silent produces the same code after the timeout. A shell `error` while a
request is pending resolves it as that error instead of waiting out the timeout.
Concurrent calls are allowed: every pending caller resolves from the same `balance` or
`error` the shell sends.

## Logging

```swift
FrugaRelay.logger = MyLogger()   // @MainActor; default: os.Logger
```

```swift
public protocol FrugaLogger {
  func log(level: LogPayload.Level, event: String, data: [String: String])
}
```

`data` defaults to `[:]` through an extension overload. Everything that reaches your
`onError` also reaches the sink as `error` with `code` / `message` / `recoverable`, and
the shell's own `log` and `error` messages are forwarded in the same shape — so one sink
sees native and shell events together.

| Event | Level | When |
|---|---|---|
| `error` | `error` | Any `FrugaError`, native or relayed from the shell |
| `bridge.dropped` | `warn` | An inbound message failed to decode; `data` carries only its `type` (`"unknown"` when the body had none), never the body |
| `navigation.blocked` | `warn` | A navigation or an `openExternal` for a non-http(s) scheme was dropped; `data` carries only the `scheme`, never the URL |
| shell events | as sent | Whatever the shell logs, e.g. `widget_mounted` |

The default sink is `os.Logger` with subsystem **`uk.co.fruga.relay`** and category
`FrugaRelay`. It drops `debug` lines unless you configured `debug: true`, so a release
build writes nothing by default. Nothing reaching the sink carries a token or a partner
key: `log` data is flattened to `parent.child` string pairs with `partnerKey` and any
token-shaped key removed at every depth, arrays dropped rather than stringified, and any
`token=` / `partnerKey=` query value in a remaining string replaced with `<redacted>`.

## Presentation and back

Relay is presented as a `.pageSheet`. Swipe-down never dismisses directly: the gesture is
sent to the shell as `back` and the sheet closes only when the shell answers
`backResult { handled: false }` — or stays silent for 1 second, so a wedged shell still
closes and the default outcome is that back closes Relay. A repeat drag while the shell
is still deciding is ignored rather than treated as unhandled.

## Tokens

```swift
public typealias FrugaTokenProvider = @Sendable (TokenRequiredPayload.Reason) async throws -> String
```

| Reason | When |
|---|---|
| `.initial` | First mount |
| `.ttl` | The shell says the token is about to expire, or the foreground re-check below fires |
| `.unauthorized` | The API rejected the token with a 401 |

Guarantees: one provider call in flight at a time (a second request while one is pending
is dropped); the in-flight call is **cancelled when Relay is dismissed**, and no callback
runs after that; a provider that throws produces `TOKEN_PROVIDER_FAILED` whose message
names only the error's type — never its message, never the token. A `CancellationError`
is not reported as a failure.

**Foreground TTL re-check.** With `tokenTtlSeconds` set,
`UIApplication.willEnterForegroundNotification` asks the provider with reason `.ttl` if
more than that long has passed since the last delivered token, and sends the result as
`tokenUpdate`. It never fires before a token has ever been delivered: the shell asks
`initial` itself, so an extra request would be redundant.

## Errors

`FrugaError` is `code` / `message` / `recoverable`, delivered to the `onError` closure you
pass to `open(from:onError:)`.

| Code | Raised by | `recoverable` |
|---|---|---|
| `TIMEOUT` | shell | as sent by the shell |
| `VERSION_MISMATCH` | native — the shell's `ready.protocolVersion` differs from `FrugaRelayVersion.protocolVersion` (the message is still delivered, not dropped); also relayed when the shell sends an `error` | `false` when native-raised |
| `BOOTSTRAP_FAILED` | shell; also native when `open` is called before `configure`, or `init` cannot be encoded | `false` when native-raised |
| `OFFLINE` | native — `open` with no connectivity; nothing is presented | `true` |
| `BRIDGE_TIMEOUT` | shell — what it maps the web loader's `NOT_READY` to; also native when `getBalance` is called with no Relay screen open, or the shell does not answer `getBalance` within its timeout | as sent by the shell, `true` when native-raised |
| `PROCESS_TERMINATED` | native — `webViewWebContentProcessDidTerminate`; the shell is reloaded and `init` replayed | `true` |
| `TOKEN_PROVIDER_FAILED` | native — your provider threw | `true` |
| `UNSUPPORTED_ENGINE` | neither — **never raised on iOS**. The case exists so the code set matches Android, where the WebView version is checked at runtime; on iOS the 16.4 deployment target enforces the engine floor | `false` |

`BRIDGE_TIMEOUT` is raised natively on iOS in two cases: `getBalance()` with no Relay
screen open (`FrugaRelay.swift`), and a `getBalance` request the shell never answers within
its timeout (`FrugaShellSession.requestBalance`). It is not raised for a stalled renderer:
WebKit has no renderer-unresponsive callback, so there is nothing to raise it from there
(Android raises it from `WebViewRenderProcessClient`).

## Navigation and external links

Only the CDN shell origin and the API origin (`apiBaseUrl`, else
`https://api.fruga.co.uk`) load inside the WebView. Any other top-level navigation, and
every `openExternal` from the shell, opens in an `SFSafariViewController` presented over
Relay. Only `http` and `https` leave the SDK: `tel:`, `mailto:` and custom app schemes are
dropped, so an untrusted page can never make your app deep-link into another one.
Subframes are not policed — the Relay widget is itself an iframe — and `about:blank` /
`about:srcdoc` are allowed because they are WebKit's own placeholders.

## Threading

| | Guarantee |
|---|---|
| Bridge traffic | Main actor only. The transport protocol itself is `@MainActor`, and the script message handler, the session and the facade are too |
| `FrugaRelay.configure` / `open` / `close` | `@MainActor`; call them from the main actor |
| Your `tokenProvider` | `@Sendable` and `async`; it may resolve on any executor. The SDK hops back to the main actor before touching the WebView or calling your `onError` |
| Your `onError` | Called on the main actor. Do not block in it |

## Runtime dependencies

**None.** System frameworks only: Foundation, UIKit, WebKit, SafariServices and Network.

## Known gaps

- **No SwiftUI wrapper** — issue [#132](https://github.com/FrugaInsurance/sdk/issues/132).
  Present Relay from a `UIViewController` for now.
- **An unknown `tokenRequired.reason` requests no token** — the message fails to decode,
  so it is reported as `bridge.dropped` rather than retried
  ([#129](https://github.com/FrugaInsurance/sdk/issues/129)).
- No sample app yet ([#80](https://github.com/FrugaInsurance/sdk/issues/80)); a
  published SwiftPM package is an M4 release task.

## Build and test

```bash
cd packages/ios
cp ../loader/src/native/fixtures/*.json Tests/Fixtures/   # gitignored here; copy before a core test run
swift build
swift test --filter FrugaRelayCoreTests                   # Foundation-only, runs on Linux too
xcodebuild -scheme FrugaRelay -destination "id=<simulator udid>" test   # macOS + Xcode 16
```

Contributor-facing file map, message flow, test seams and CI layout:
[`ARCHITECTURE.md`](./ARCHITECTURE.md).
