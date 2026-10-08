# Account state isolation regression harness

Run on macOS with Swift 6.2+ and its matching SDK:

```sh
DEVELOPER_DIR='/Applications/Coding apps/Xcode.app/Contents/Developer' \
  bash WalkWorthy/Tests/AccountStateIsolation/run.sh
```

The script compiles the production `AppState`, `AuthSessionIdentity`, configuration,
API error types, and domain/SwiftData models directly. It uses in-memory SwiftData
and preferences, fake auth/network/snapshot/notification dependencies, and no-op
Firebase analytics/crash modules. No real account, credentials, Firebase app,
network request, notification, or existing user data is used. Temporary compiler
products are removed on exit. Swift macro execution must be permitted by the host.

Coverage includes outgoing memory reset before snapshot hydration; absent/corrupt
and valid new-account snapshots; retained outgoing snapshot data and SwiftData
rows on direct transitions; reset mood-fetch throttling; same-UID refresh identity;
ABA and sign-out/re-login identity; failed sign-out recovery with a fresh identity;
stale profile/status/week publication; positive
same-session controls; and confirmation-bound deletion validation.

These are forced transitions through production `AppState`. They do not establish
that the shipped UI can reach a direct authenticated account switch. The snapshot
stand-in exercises nil/decoded payloads but does not validate the real store's file
format, protection, or durability. The harness does not execute SwiftUI history
rendering or Firebase callback/token behavior. Validate UI wiring with an unsigned
iOS build and, separately, simulator tests when an iOS test target is available.

The project currently has no iOS test target. This host harness deliberately stays
outside the application's synchronized source directory and changes no project
targets, release settings, or production dependency injection interfaces.
