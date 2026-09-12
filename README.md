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

Both are `@MainActor`. `configure`, `open` and `close` are the **facade's** whole surface
today — `FrugaRelayViewController`, `FrugaRelayWebView`, `FrugaShellSession`,
`FrugaRelayConfig`, `FrugaRelayVersion` and all of `FrugaRelayCore` are public too, but
you need none of them.
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
| `VERSION_MISMATCH` | shell only — relayed when the shell sends an `error`; the SDK does not compare `ready.protocolVersion` itself ([#129](https://github.com/FrugaInsurance/sdk/issues/129)) | as sent by the shell |
| `BOOTSTRAP_FAILED` | shell; also native when `open` is called before `configure`, or `init` cannot be encoded | `false` when native-raised |
| `OFFLINE` | native — `open` with no connectivity; nothing is presented | `true` |
| `BRIDGE_TIMEOUT` | shell — what it maps the web loader's `NOT_READY` to | as sent by the shell |
| `PROCESS_TERMINATED` | native — `webViewWebContentProcessDidTerminate`; the shell is reloaded and `init` replayed | `true` |
| `TOKEN_PROVIDER_FAILED` | native — your provider threw | `true` |
| `UNSUPPORTED_ENGINE` | neither — **never raised on iOS**. The case exists so the code set matches Android, where the WebView version is checked at runtime; on iOS the 16.4 deployment target enforces the engine floor | `false` |

`BRIDGE_TIMEOUT` is never raised natively on iOS today: WebKit has no
renderer-unresponsive callback, so there is nothing to raise it from (Android raises it
from `WebViewRenderProcessClient`).

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

- **No `FrugaRelay.logger`** — issue [#79](https://github.com/FrugaInsurance/sdk/issues/79).
  There is no partner log sink and no `os.Logger` yet, so errors reach you only through
  the `onError` closure, and lifecycle and `navigation.blocked` events are not reported
  at all. Blocked navigations are still blocked.
- **No SwiftUI wrapper** — issue [#132](https://github.com/FrugaInsurance/sdk/issues/132).
  Present Relay from a `UIViewController` for now.
- **No `getBalance()`** — issue [#131](https://github.com/FrugaInsurance/sdk/issues/131).
  The message exists on the wire but is never sent, and an inbound `balance` is decoded
  and dropped.
- **`ready.protocolVersion` is not checked**, and an unknown `tokenRequired.reason` is
  dropped silently (the message fails to decode, so no token is requested and nothing is
  recorded) — [#129](https://github.com/FrugaInsurance/sdk/issues/129).
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
