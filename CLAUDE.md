# Proxy Gauge: rules for agents

Native iPhone and Mac client for CLIProxyAPI servers (Management API and client-key mode). MIT, public.

## Stack
- Swift 6 (language mode 6, strict concurrency), SwiftUI, XcodeGen project in `Apple/`, SwiftPM package for portable logic.
- iOS 26 / macOS 26 minimum.
- Scripts: TypeScript on `bun`, or bash for thin Xcode wrappers.

## Rules
- Keys (management key, client keys) live in the Keychain only; never in logs, fixtures, screenshots, tests or UserDefaults.
- Code comments: zero by default; only a non-obvious why.
- Implementation happens on git worktrees in a sibling folder `../<repository>--worktrees/<branch>`, never on the main checkout.
  Run-state in `.claude/state.md`, updated at every phase boundary.
- Commits: gitmoji subject, English, no co-author or generated-with footers.
- App name, bundle ID and team live only in `Apple/Config/Identity.xcconfig`.
- The iOS Simulator is shared with other sessions on this Mac: use only the device named `proxygauge-iphone`
  (create it if missing), never boot, shut down or erase another device.
- Dev servers and test proxies on random high ports (9000-9999).
