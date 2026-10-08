# Account state isolation regression harness

Run on macOS with Swift 6.2+ and its matching SDK:

```sh
DEVELOPER_DIR='/Applications/Coding apps/Xcode.app/Contents/Developer' \
  bash WalkWorthy/Tests/AccountStateIsolation/run.sh
```

The script compiles the production `AppState`, `AuthSessionIdentity`, reminder cleanup, configuration,
API error types, and domain/SwiftData models directly. It uses in-memory SwiftData
and preferences, fake auth/network/snapshot/notification dependencies, and no-op
Firebase analytics/crash modules. No real account, credentials, Firebase app,
network request, notification, or existing user data is used. The two independent
HTTP-cache methods are extracted verbatim from `LiveAPIClient` into a minimal
Foundation-only type. Their tests replace `URLCache.shared` with a memory-only
cache for this process. The real client's token/request path is not exercised.
Python 3 is required for extraction. Temporary compiler
products are removed on exit. Swift macro execution must be permitted by the host.

Coverage includes outgoing memory reset before snapshot hydration; absent/corrupt
and valid new-account snapshots; retained outgoing snapshot data and SwiftData
rows on direct transitions; reset mood-fetch throttling; same-UID refresh identity;
ABA and sign-out/re-login identity; failed sign-out recovery with a fresh identity;
stale profile/status/week publication; positive
same-session controls; and confirmation-bound deletion validation. Integration
checks also cover no-cache session configuration, HTTP-cache eviction on actual
UID changes and sign-out, preservation on same-UID refresh, and repeated deletion
cleanup before completion (including intents already marked locally complete).

A second executable (`TransportTests.swift`, `DeletionFlowTests.swift`) compiles
the production `LiveAPIClient`, `SessionCredentialBinding`, `AuthenticatedRequestContext`
and `AccountDeletionFlow` over a stub `URLProtocol`. It holds account-owned work
(debounced profile save, personalization toggle, 401 forced-refresh retry, post-App
Check dispatch, account deletion, and every deletion-ceremony wait) and switches
accounts: A→B and same-UID re-sign-in before AppState observes Firebase, and
observed A→B, A→B→A and sign-out→sign-in as A. Every case must dispatch nothing with
another sign-in's credential; same-session controls must still send. The stub server
applies the backend's recent-auth rule for new deletion jobs, covering stale password
and Apple sessions, Apple cancellation and Apple ID mismatch. Firebase itself is a
stand-in modelled on firebase-ios-sdk 12.7.0 (one `User` object per sign-in, reused
by token refresh, reload and reauthentication); validate Apple and Firebase behavior
on a device.

Deletion retry coverage also reproduces successful cloud deletion with failed local
cleanup, then unavailable Apple authorization and repeated local failure. Retry must
finish local recovery without another provider ceremony or cloud request, including
when Firebase no longer has the user. Persisted completion states, stale app sessions,
and another account's intent are covered; incomplete server deletion still requires
Apple authorization or a stale password session's reauthentication.

These are forced transitions through production `AppState`. They do not establish
that the shipped UI can reach a direct authenticated account switch. The snapshot
stand-in exercises nil/decoded payloads but does not validate the real store's file
format, protection, or durability. The harness does not execute SwiftUI history
rendering or Firebase callback/token behavior. Validate UI wiring with an unsigned
iOS build and, separately, simulator tests when an iOS test target is available.

The project currently has no iOS test target. This host harness deliberately stays
outside the application's synchronized source directory and changes no project
targets, release settings, or production dependency injection interfaces.
