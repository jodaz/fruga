# Architecture — `packages/ios`

Contributor-facing. Partner-facing usage is [`README.md`](./README.md); the bridge
contract of record is `docs/PRD.md` §5.7 with fixtures in
`packages/loader/src/native/fixtures/*.json`; the cross-platform rules are
`.agent/rules/native-sdk.md`.

SwiftPM package `FrugaRelay`, `swift-tools-version: 6.0`, `platforms: [.iOS("16.4")]`,
one product (`FrugaRelay`) vending both library targets.

## Targets

| Target | Imports | Builds on | Why |
|---|---|---|---|
| `FrugaRelayCore` | Foundation only | Linux and macOS | The bridge, the token coordinator and the navigation rules have no UI in them. Keeping them Foundation-only means the whole trust boundary — decode, encode, allowlist, TTL — is buildable and testable on Linux, in a `swift:6.0` Docker container, with no Mac in the loop |
| `FrugaRelay` | UIKit, WebKit, SafariServices, Network | macOS/Xcode only | The `WKWebView` host, the facade and the transport. Everything platform-bound sits behind `#if canImport(UIKit) && canImport(WebKit)` (`FrugaRelayWebView.swift`: `#if canImport(WebKit)`), so the target still *compiles* on Linux. The one declaration deliberately left outside the guard is `public enum FrugaRelay {}` in `FrugaRelay.swift`, so the module has a symbol on Linux and `FrugaRelayTests` still links there |

Both library targets build in **Swift 6 language mode** (the tools version's default).
The two test targets are pinned to **v5** with `swiftSettings: [.swiftLanguageMode(.v5)]`;
the reason is in `Package.swift`: XCTest's `await fulfillment(of:)` takes a nonisolated
`self`, which a `@MainActor XCTestCase` cannot pass in Swift 6 mode.

Consequence for consumers: **Xcode 16** (Swift 6 compiler) is required to build the
package at all.

`FrugaRelayCoreTests` declares `path: "Tests"` with `sources: ["FrugaRelayCoreTests"]`
and `resources: [.copy("Fixtures")]`, because the fixture directory is shared, not
per-target.

## Files

One responsibility each.

### `Sources/FrugaRelayCore` — Foundation only

| File | Responsibility |
|---|---|
| `FrugaRelayCore.swift` | `FrugaRelayVersion.shell` (the pinned CDN shell version, a compile-time constant bumped only by a release task) and `FrugaRelayVersion.shellURL` — **the one place the shell URL is built**, and never from partner input |
| `FrugaNativeMessage.swift` | Shell → native: the seven `case`s, their payloads, the `TokenRequiredPayload.Reason` / `ErrorPayload.Code` / `LogPayload.Level` enums, and `decode(_:) throws`. The trust boundary: an unknown `type`, a missing field or an out-of-range enum throws. `log.data` is `unknown` on the TS side, so it is carried as re-serialised JSON bytes through a private `JSONValue` and never inspected |
| `FrugaHostMessage.swift` | Native → shell: `init`, `tokenUpdate`, `network`, `back`, `getBalance`, plus `InitPayload` / `SafeArea` / `TokenUpdatePayload` / `NetworkPayload` and the typed `InitPayload.Theme`. Flat envelope — the discriminator encodes into the same keyed container as the payload — and absent optionals are omitted, never sent as `null` |
| `FrugaShellSession.swift` | `@MainActor` session and the `@MainActor protocol FrugaShellTransport { func reload(); func send(_ json: Data) }`. Remembers `init` and replays it on every `shellDidLoad()`, decodes inbound JSON and drops what does not parse, raises `PROCESS_TERMINATED` then reloads, and owns the `back` / `backResult` request with its timeout |
| `FrugaTokenCoordinator.swift` | `public typealias FrugaTokenProvider = @Sendable (TokenRequiredPayload.Reason) async throws -> String`, `struct FrugaError` (`code`/`message`/`recoverable`), and the `actor` that serialises provider calls: one in flight, `cancel()`, `lastTokenAt`, `needsRefresh(ttl:now:)`, `TOKEN_PROVIDER_FAILED` on a throw |
| `FrugaRelayOptions.swift` | `FrugaRelayOptions` (the partner's optional `init` fields plus `tokenTtlSeconds` and `debug`) and `FrugaRelayConfig` — what `configure` stored — whose `makeInitPayload(safeArea:token:)` composes the `InitPayload`. Both are public with public inits (the screen and tests build them), but the partner never has to: `configure` takes `FrugaRelayOptions`, and the screen composes the `InitPayload` from it plus the safe area it measures |
| `FrugaNavigationPolicy.swift` | The origin allowlist (CDN shell origin + API origin, default `https://api.fruga.co.uk`) and the `.allow` / `.openExternally` decision. Origins are normalised to `scheme://host[:port]` with default ports elided |
| `FrugaExternalURLRule.swift` | The one gate on what may leave the SDK at all: `http`/`https`, case-insensitive. Everything else is dropped |

### `Sources/FrugaRelay` — UIKit/WebKit

| File | Responsibility |
|---|---|
| `FrugaRelay.swift` | The partner facade (`enum FrugaRelay`, no instances): `configure`, `open(from:onError:)`, `close()`, the stored `config`, a **weak** reference to the presented controller, and the process-wide `NWPathMonitor` started by `configure`. Its path updates set `isOnline` and forward a `network` message to the presented screen on the main actor |
| `FrugaRelayViewController.swift` | The screen: owns the `WKWebView`, the `fruga` script message handler (through a `ScriptMessageProxy`, so the WebView's content controller does not retain the controller), the `FrugaShellSession`, the `FrugaTokenCoordinator`, the `init`-payload composition and safe-area measurement, the foreground observer, `SFSafariViewController` presentation, and the swipe-down `UIAdaptivePresentationControllerDelegate` |
| `FrugaRelayWebView.swift` | Transport + `WKNavigationDelegate`: `reload()`, `send(_:)` via `evaluateJavaScript`, `decidePolicyFor` → the host's `shouldAllowNavigation`, `didFinish` → `session.shellDidLoad()`, `webViewWebContentProcessDidTerminate` → `session.processDidTerminate()`. Also the `nonisolated static func jsStringLiteral(_:)` escaper. Retained by the controller because `navigationDelegate` is weak |

## Message flow

```
viewDidLoad                registerInitPayload() → session.start(initMessage:message:)   // remembered, not sent
                           webView.load(FrugaRelayVersion.shellURL)
viewDidLayoutSubviews      safe area changed? → registerInitPayload() again
WKNavigationDelegate       didFinish → session.shellDidLoad()
  → transport.send         evaluateJavaScript("window.FrugaNative.receive(<init literal>)")
shell renders the widget   window.webkit.messageHandlers.fruga.postMessage({"type":"ready",…})
  → ScriptMessageProxy     String or Data body → Data → session.receive(json)
shell needs a token        …postMessage({"type":"tokenRequired","reason":"initial"})
  → session.onTokenRequired → Task { await coordinator.request(reason:) }
  → provider (may resolve off-main) → Task { @MainActor } → session.send(.tokenUpdate(…))
  → evaluateJavaScript("window.FrugaNative.receive(<tokenUpdate literal>)")
```

**Outbound escaping.** `window.FrugaNative.receive` takes the JSON as a *string*, so the
bytes cross as a JS string literal. `jsStringLiteral` decodes the `Data` as UTF-8 and
re-encodes it with `JSONSerialization … options: .fragmentsAllowed`, which produces a
quoted, fully escaped literal; a non-UTF-8 or unencodable payload returns `nil` and the
message is dropped rather than injected raw. U+2028 and U+2029 are then replaced with
` ` / ` `: they are legal raw inside a JSON string but terminate a line in JS
source, so they would truncate the statement `evaluateJavaScript` runs.

**Inbound guard.** `ScriptMessageProxy` accepts only a `String` or `Data` body and
returns on anything else. `FrugaShellSession.receive` is `guard let message = try?
FrugaNativeMessage.decode(json) else { return }` — malformed JSON, an unknown `type` and
an out-of-range enum are all dropped. Nothing on the inbound path throws or traps. A
decoded message the session does not act on (`ready`, `balance`, `error`, `log`) still
reaches `onMessage`. A malformed `openExternal.url` is dropped by `URL(string:)`.

## Lifecycle

| Event | Handling |
|---|---|
| `viewDidLoad` | Pins the WebView to the view's edges, then `registerInitPayload()` **before** `webView.load(...)` — a `didFinish` that beats the first layout pass must still find an `init` to send (parity with Android's fragment, which registers `init` before `loadUrl`). The load is skipped when `loadsShellAutomatically` is `false` |
| `viewDidLayoutSubviews` | The safe area is only real once laid out in a window, so `init` is recomposed and **re-registered** whenever `currentSafeArea()` differs from `lastInitPayload?.safeArea` (first layout, rotation, keyboard). `registerInitPayload()` only calls `session.start(initMessage:message:)`, which stores the bytes — nothing is sent until the next `shellDidLoad()`. So a later reload replays fresh insets, but a post-load rotation does not reach the shell. Insets come from `view.safeAreaInsets`, so the host's `additionalSafeAreaInsets` are included |
| `viewWillAppear` | `presentationController?.delegate = self`. Wired here, not at the call site, so *every* presenter gets the ask-the-shell-first swipe-down |
| `UIApplication.willEnterForegroundNotification` | With `options.tokenTtlSeconds` set, `await coordinator.needsRefresh(ttl:now:)` and, if stale, `request(reason: .ttl)` → `tokenUpdate`. No TTL, or no token ever delivered, means no request |
| `viewDidDisappear` | → `relayDidDisappear(isDismissing: isBeingDismissed)` → `Task { await coordinator.cancel() }`. Cancelling on a dismissal only; a covered-but-still-presented screen keeps its in-flight request |
| `deinit` | `nonisolated`: removes the **observer token** (not `removeObserver(self)`, which would touch main-actor state) and, only when `Thread.isMainThread`, removes the `fruga` script message handler under `MainActor.assumeIsolated`. Off-main, the handler dies with the WebView anyway |
| `webViewWebContentProcessDidTerminate` | → `session.processDidTerminate()`: emits `PROCESS_TERMINATED` (`recoverable: true`) **with no dedup** — a repeated termination is a repeated failure the sink must see — then `transport.reload()`. The reload's `didFinish` calls `shellDidLoad()`, which replays the remembered `init` **bytes**, so the replay is byte-exact (the typed form is kept only to restore `lastSent`) |
| `FrugaRelay.open` twice | The second call is a no-op while a screen is up, not a second sheet |
| `FrugaRelay.open` offline | `isOnline == false` → `OFFLINE` (`recoverable: true`) to `onError` and nothing is presented. `isOnline` starts optimistic (`true`), so a cold start before the monitor's first update is never refused |

## Back handling

`presentationControllerShouldDismiss` always returns `false` and asks the shell instead:
`session.requestBack { handled in … }` sends `back` and dismisses only when the answer is
`handled == false`. The 1 s budget is the `timeout: TimeInterval = 1.0` default on
`requestBack`; the call site passes no timeout.

- **Silence is unhandled.** The 1 s timeout resolves the request as `false`, so back
  closing Relay is the default outcome and a wedged shell still closes.
- **Repeats are dropped.** `guard pendingBack == nil else { return }` — a second drag
  while the shell is still deciding sends nothing and does not resolve; a second sheet
  drag must never dismiss a screen the shell asked to keep.
- **An unsolicited `backResult` is ignored** by `resolveBack` (it still reaches
  `onMessage`).
- **A late answer cannot close someone else's screen**: the completion re-checks
  `self.presentingViewController != nil` before calling `performDismiss()`, because
  `dismiss` on a controller that is no longer presented walks up to its presenter.

`modalPresentationStyle = .pageSheet` is load-bearing: `.fullScreen` never asks its
delegate whether it should dismiss, so swipe-down could not consult the shell.

## Navigation

`decidePolicyFor` → `handleNavigation(to:isMainFrame:)` → `FrugaNavigationPolicy.decide`;
the shell's `openExternal` goes through the same external gate.

| Input | Decision |
|---|---|
| `isMainFrame == false` | `.allow` — only top-level navigation is policed; the Relay widget is itself an iframe |
| `about:` (`about:blank`, `about:srcdoc`) | `.allow` — WebKit's own placeholders |
| CDN shell origin, or the API origin (`options.apiBaseUrl`, else `https://api.fruga.co.uk`) | `.allow`. Origins compare as normalised `scheme://host[:port]`, so a path or query is ignored, an explicit `:443` on https equals the default, and an `http` downgrade of the CDN host does **not** match |
| Any other main-frame URL | `.openExternally` → `decisionHandler(.cancel)`, and `SFSafariViewController` if `FrugaExternalURLRule.allows(url)` |
| Shell `openExternal` | Same gate: `session.onOpenExternal` filters by `FrugaExternalURLRule` before calling `openExternally` |
| `tel:`, `mailto:`, a custom app scheme — from either path | Dropped. The bridge is a trust boundary and must not drive-launch third-party apps |
| A URL with no scheme/host, or a malformed `openExternal.url` | Dropped before anything is presented |

The default `openExternally` also requires `self.view.window != nil`:
`SFSafariViewController` cannot be presented from a controller that is not in a window.

The `navigation.blocked` warn log required by `.agent/rules/native-sdk.md` is **not
emitted yet** — there is no logger to emit it to. Deferred to
[#79](https://github.com/FrugaInsurance/sdk/issues/79); the drop itself is implemented
and tested.

## Threading

| | Guarantee |
|---|---|
| Bridge traffic | Main actor only. `FrugaShellTransport` is `@MainActor` **at the protocol**, so isolation is not something each implementer has to justify, and `FrugaShellSession`, `FrugaRelayWebView` and `ScriptMessageProxy` are all `@MainActor` |
| `FrugaRelay` facade | Every member is `@MainActor`, including the stored `config` and `isOnline` |
| `NWPathMonitor` | Runs on its own `co.uk.fruga.relay.network` queue and hops into `Task { @MainActor }` before touching `isOnline` or the presented screen |
| Your `tokenProvider` | `@Sendable … async throws`, driven by the `FrugaTokenCoordinator` **actor**. It may resolve on any executor; the controller's `onToken` / `onError` callbacks hop back with `Task { @MainActor }` before touching the WebView or the partner's error sink |
| `deinit` | Nonisolated; touches no main-actor state except under an explicit `Thread.isMainThread` check |

## Internal test seams

All `internal`, reachable only through `@testable import`. Nothing here is public API.

| Seam | File | For |
|---|---|---|
| `dismissHandler: (() -> Void)?` | `FrugaRelayViewController` | A host-less test process never completes a real `dismiss(animated:)`; the handler observes the decision instead. `nil` in an app |
| `performDismiss()` | `FrugaRelayViewController` | The single dismissal site every path funnels through, so a test can assert *that* it happened |
| `loadsShellAutomatically` | `FrugaRelayViewController` | Mount the view without a network round trip to the CDN. Always `true` in an app |
| `relayDidDisappear(isDismissing:)` | `FrugaRelayViewController` | `isBeingDismissed` is only set under a real presentation; this is the seam `viewDidDisappear` calls so cancel-on-close is testable |
| `coordinator`, `session`, `webView`, `policy`, `lastInitPayload` | `FrugaRelayViewController` | Read-side assertions (provider wiring, sent messages, allowlist, measured safe area) |
| `handleNavigation(to:isMainFrame:)`, `networkDidChange(online:)`, `currentSafeArea()`, `openExternally` | `FrugaRelayViewController` | Drive the navigation decision, connectivity forwarding and inset measurement directly. `openExternally` is a swappable `lazy var` closure so a test can record the URL instead of presenting Safari |
| `FrugaTokenCoordinator.markTokenDelivered(at:)` | `FrugaTokenCoordinator` | Backdate a delivery for the foreground TTL re-check without a public setter on `lastTokenAt` |
| `FrugaRelay.presentedController` | `FrugaRelay` | The controller `open` presented, if still up |
| `FrugaRelay.isOnline` | `FrugaRelay` | Settable, so the offline-mount path runs without unplugging the machine |
| `FrugaRelay.reset()` | `FrugaRelay` | Clears `config` and `presented` between cases — the facade is process-wide state |
| `FrugaRelayWebView.shouldAllowNavigation` | `FrugaRelayWebView` | The host's allowlist hook. Unset means allow, so a bare `FrugaRelayWebView` still loads |
| `FrugaRelayWebView.jsStringLiteral(_:)` | `FrugaRelayWebView` | `nonisolated static`, so escaping can be tested without hopping to the main actor |
| `FrugaShellSession.lastSent` | `FrugaShellSession` | `private(set)` and **internal on purpose**: it is test and diagnostic state, and a partner must not be able to read a bearer token back out of the session |

## Tests

### Core — `Tests/FrugaRelayCoreTests` (7 files, Linux and macOS)

| File | Covers |
|---|---|
| `FrugaNativeMessageTests` | All seven shell → native types decode from `*.valid.json`; every `*.invalid.json` throws; `UNSUPPORTED_ENGINE`'s raw value and literal decode; `Equatable` |
| `FrugaHostMessageTests` | All five native → shell types encode structurally equal to their fixture (key order is not part of the contract); absent optionals omitted rather than `null`; `Theme.dark` as a lowercase string |
| `FrugaShellSessionTests` | `init` replay on every load and across a termination, `PROCESS_TERMINATED` un-deduped, malformed input dropped, the full back request/result/timeout/repeat/unsolicited matrix, `openExternal` and `tokenRequired` routing, `lastSent` |
| `FrugaTokenCoordinatorTests` | Reason passthrough, `TOKEN_PROVIDER_FAILED` without leaking the token or the provider's message, cancellation, single-flight, `CancellationError` is not an error, `lastTokenAt` / `needsRefresh` semantics |
| `FrugaNavigationPolicyTests` | `standard()` equals the explicit origin set for both default and custom `apiBaseUrl`, path-insensitivity, scheme downgrade, explicit default port, unrelated host, sub-frame, `about:blank` / `about:srcdoc` |
| `FrugaExternalURLRuleTests` | `http`/`https` (any case) allowed; `tel`, `mailto`, a custom scheme rejected |
| `FrugaRelayOptionsTests` | Defaults, `makeInitPayload` composition, token omitted when `nil`, `tokenTtlSeconds` default and setter |

**Fixtures.** `Tests/Fixtures/*.json` is **gitignored** (`packages/ios/.gitignore`) — the
loader owns those bytes and the iOS package must not carry a second copy that can drift.
Locally, copy them in before a run:

```bash
cp packages/loader/src/native/fixtures/*.json packages/ios/Tests/Fixtures/
```

That exact command is the `XCTUnwrap` failure message in `FrugaHostMessageTests` /
`FrugaNativeMessageTests`, so a missing fixture tells you how to fix it instead of
silently falling back to a hand-written copy. In CI they are injected by the push
workflow — see below.

### UIKit — `Tests/FrugaRelayTests` (5 files, macOS/simulator only)

| File | Covers |
|---|---|
| `FrugaRelayViewControllerTests` | WebView attachment, the shell URL, `.pageSheet` + delegate wiring by the controller itself, `open` before `configure` → `BOOTSTRAP_FAILED`, double-open, `close()`, the four dismiss-decision outcomes (asks, handled, unhandled, timeout), the late-`backResult` guard, `tokenRequired` → provider, safe area at load and via `additionalSafeAreaInsets`, `init` sent before the first layout pass, non-http `openExternal` dropped |
| `FrugaRelayLifecycleTests` | Foreground TTL re-check and the `tokenUpdate` it produces, cancel-on-close, `networkDidChange` through the session, offline mount, non-http navigation dropped |
| `FrugaRelayNavigationTests` | The controller's policy is `standard()` for its config; allow / open-externally / sub-frame outcomes through `handleNavigation` |
| `FrugaRelayWebViewTests` | `jsStringLiteral`: quotes, backslashes, newlines, U+2028/U+2029 never raw, non-UTF-8 → `nil`. Compiled out on Linux (`#if canImport(WebKit)`) |
| `FrugaRelayTests` | The facade type exists — the smoke test that keeps the target linkable on Linux, where everything else compiles out |

Most of these mount the view without loading the shell (`loadsShellAutomatically = false`)
and drive the session directly. The exceptions are the seven that go through
`FrugaRelay.open` — which never disables the seam — or assert on `webView.url`
(`FrugaRelayViewControllerTests` lines 124, 137, 157, 360, 377, 422 and the `open` cases in
`FrugaRelayLifecycleTests`): those start the **real** load against the CDN, so the macOS job
does make network calls. What none of them do is *wait* on the shell — no assertion depends
on the shell's JS, a rendered widget or a bridge round trip. That is the deliberate
contrast with Android, whose instrumented suite does wait on the live shell.

## CI

There is **no macOS job in this repo's `.github/workflows`**. `packages/ios/.github/workflows/ios.yml`
is carried inside the package and runs in the public mirror repository configured by the
`IOS_MIRROR_REPO` Actions variable.

| Job | Runner | Steps |
|---|---|---|
| `core` | `ubuntu-latest`, container `swift:6.0`, 15 min | `swift build`, then `swift test --filter FrugaRelayCoreTests` |
| `ios` | `macos-15`, 30 min | Picks the first available iPhone simulator from `xcrun simctl list devices available --json`, falling back to `xcodebuild -downloadPlatform iOS` and failing loudly if there still is none; then `xcodebuild -scheme FrugaRelay -destination "id=$DEST_ID" -test-timeouts-enabled YES -default-test-execution-time-allowance 120 test` with `CODE_SIGNING_ALLOWED: NO` |

The per-test allowance is what keeps a hung `XCTestExpectation` from burning the whole
30-minute budget.

**Fixtures in CI are not a gap.** This repo's `.github/workflows/mirror-ios.yml` runs on
a push to `develop` or `ios/**` that touches `packages/ios/**` or
`packages/loader/src/native/fixtures/**`. Before it pushes, it copies
`packages/loader/src/native/fixtures/*.json` into `packages/ios/Tests/Fixtures/` and
`git add -f`s them in a commit on a temporary `mirror-tmp` branch, then
`git subtree split --prefix packages/ios` and force-pushes the split branch. So the
fixtures are gitignored here, copied by hand for a local run, and injected by that
workflow for every mirrored push — the `core` job always finds them.

The rest of the CI story (a matrix, anything beyond the two jobs above) is
[#83](https://github.com/FrugaInsurance/sdk/issues/83).

## Dependencies

**Zero third-party dependencies.** `Package.swift` declares no `dependencies:` at all, at
the package or the target level. Everything used is a system framework: **Foundation**
(JSON, `URL`, `Date`), **UIKit**, **WebKit**, **SafariServices** (`SFSafariViewController`)
and **Network** (`NWPathMonitor`). Adding one needs an Open question to the user
(`.agent/rules/native-sdk.md`).

## Known gaps

- **No partner log sink and no `os.Logger`** — [#79](https://github.com/FrugaInsurance/sdk/issues/79).
  Errors reach the partner only through the `onError` closure passed to
  `open(from:onError:)`; there is no `FrugaRelay.logger`, no `co.uk.fruga.relay`
  subsystem, and therefore no `navigation.blocked` line and no lifecycle events. The same
  issue carries the explicit main-actor audit and turning Thread Sanitizer on in the test
  scheme.
- **No SwiftUI wrapper** — [#132](https://github.com/FrugaInsurance/sdk/issues/132). The
  `UIViewControllerRepresentable` was in the acceptance of #73, which closed without it.
- **No sample app** — [#80](https://github.com/FrugaInsurance/sdk/issues/80). `apps/ios`
  does not exist yet, so there is no settings screen, bridge log pane or Maestro flow on
  iOS.
- **Test coverage is not finished** — [#81](https://github.com/FrugaInsurance/sdk/issues/81)
  and [#82](https://github.com/FrugaInsurance/sdk/issues/82). Notably absent: the 20
  open/close cycles retain-no-WebView check, keyboard behaviour on iOS 16.4, and anything
  that needs a real device.
- **CI is partial** — [#83](https://github.com/FrugaInsurance/sdk/issues/83).
- **No `getBalance()`** — [#131](https://github.com/FrugaInsurance/sdk/issues/131).
  `FrugaHostMessage.getBalance` encodes and `BalancePayload` decodes, but nothing sends
  the request and `balance` is decoded and dropped, so the public API required by
  `.agent/rules/native-sdk.md` is not there yet.
- **`ready.protocolVersion` is never checked** — the session decodes `ready` and forwards
  it to `onMessage`, and no caller compares the version, so no native `VERSION_MISMATCH`
  is raised; it surfaces only if the shell sends it as an `error`. And a `tokenRequired`
  whose `reason` is missing or outside `initial | ttl | unauthorized` fails to decode, so
  `receive` **drops the whole message silently** — no token is requested and, with no
  logger, nothing is recorded. Both tracked in
  [#129](https://github.com/FrugaInsurance/sdk/issues/129) (Android + iOS).
