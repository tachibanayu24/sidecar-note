# Contributing

Thanks for your interest! Issues and pull requests are welcome.

## Setup

- macOS 26 and Xcode 26 (Swift 6.2).
- `swift build` compiles; `./scripts/build-app.sh --dev` builds a separate **Sidecar Note Dev.app** (own bundle id, settings and notes) so testing never touches your real notes.

## Before opening a pull request

1. `swift build` finishes with no warnings from `Sources/`.
2. Build the dev app, launch it, and run the self-test:
   ```sh
   ./scripts/build-app.sh --dev && open -g "build/Sidecar Note Dev.app"
   swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("SidecarNoteDev.selftest"), object: nil, userInfo: nil, deliverImmediately: true)'
   grep selftest /tmp/sidecar-dev.log   # should end with "ALL PASSED"
   ```
3. Try the change by hand in the dev app for anything the self-test can't reach (animations, gestures, IME).
4. Keep the style of the surrounding code: small focused types, comments that explain *why*, English UI text.

## Changes to `Vendor/`

The two vendored packages carry small patches (marked `Sidecar Note patch`). Keep them minimal and describe them in the package's `Package.swift` header.
