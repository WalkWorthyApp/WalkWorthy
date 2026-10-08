import AuthenticationServices
import Foundation

/// Drives the production deletion ceremony (`AccountDeletionFlow`) against the
/// production AppState and LiveAPIClient. The stub server applies the backend's
/// recent-auth rule, so stale credentials fail exactly where production would.
@MainActor
func runDeletionFlowTests() async throws {
    try await deletionSucceeds("stale password session re-authenticates first", authenticatedAgo: 10 * 60, password: true)
    try await deletionSucceeds("fresh password session deletes without a prompt", authenticatedAgo: 60, password: false)
    try await deletionSucceeds("stale Apple session re-authenticates, then revokes", apple: true, authenticatedAgo: 10 * 60, password: false)
    try await completedCloudDeletionRetriesLocalCleanup(authRemoved: false)
    try await completedCloudDeletionRetriesLocalCleanup(authRemoved: true)
    try await incompleteCloudDeletionStillAuthenticates()
    try await completedDeletionIntentStillFinishesLocally()
    try await completedDeletionDoesNotAuthorizeAnotherSession()
    try await appleSheetCanceled()
    try await appleIDMismatch()
    try await ceremonyRaces()
}

@MainActor
func waitForIdle(_ flow: AccountDeletionFlow) async throws {
    try await waitUntil("deletion ceremony did not settle") { flow.phase == .idle && !flow.isWorking }
}

@MainActor
func deletionSucceeds(_ name: String, apple: Bool = false, authenticatedAgo: TimeInterval, password: Bool) async throws {
    let f = try TransportFixture()
    await f.signIn("A", apple: apple, authenticatedAgo: authenticatedAgo)
    StubURLProtocol.reset()
    let flow = AccountDeletionFlow()
    flow.begin(using: f.state)
    try check(flow.phase == .confirmation, "\(name): confirmation not shown")
    flow.confirm(using: f.state)
    if password {
        try await waitUntil("\(name): password not requested") { flow.phase == .password }
        try check(StubURLProtocol.sent("deleteAccount").isEmpty && SnapshotStore.shared.erasedAccounts.isEmpty,
                  "\(name): erased or requested deletion before re-authentication")
        flow.submit(password: "wrong", using: f.state)
        try await waitUntil("\(name): wrong password not reported") { flow.phase == .password && flow.passwordError != nil }
        flow.submit(password: "correct horse", using: f.state)
    }
    try await waitForIdle(flow)
    let sent = StubURLProtocol.sent("deleteAccount")
    try check(flow.deletionError == nil, "\(name): \(String(describing: flow.deletionError))")
    try check(sent.count == 1 && sent[0].authorization == "Bearer token:A:1:recent",
              "\(name): expected one recent-auth request, got \(sent.map { $0.authorization ?? "nil" })")
    try check(SnapshotStore.shared.erasedAccounts == ["A"], "\(name): local erase \(SnapshotStore.shared.erasedAccounts)")
    try check(FakeFirebase.appleRevocations == (apple ? ["A"] : []), "\(name): revocations \(FakeFirebase.appleRevocations)")
    if apple {
        try check(FakeFirebase.events == ["reauthenticate:A", "revokeApple:A"], "\(name): Apple steps \(FakeFirebase.events)")
    }
    try check(!f.state.isAuthenticated && FakeFirebase.currentUser == nil, "\(name): completed deletion stayed signed in")
    print("PASS \(name)")
}

@MainActor
func appleSheetCanceled() async throws {
    let f = try TransportFixture()
    await f.signIn("A", apple: true, authenticatedAgo: 10 * 60)
    StubURLProtocol.reset()
    FakeFirebase.appleSheet = { throw ASAuthorizationError(.canceled) }
    let flow = AccountDeletionFlow()
    flow.begin(using: f.state)
    flow.confirm(using: f.state)
    try await waitForIdle(flow)
    try check(flow.deletionError == nil, "Apple cancel surfaced an error")
    try check(FakeFirebase.appleRevocations.isEmpty && SnapshotStore.shared.erasedAccounts.isEmpty
              && StubURLProtocol.sent("deleteAccount").isEmpty && !f.state.accountDeletionPending,
              "Apple cancel still deleted something")
    print("PASS Apple sheet cancel leaves the account untouched and silent")
}

@MainActor
func appleIDMismatch() async throws {
    let f = try TransportFixture()
    await f.signIn("A", apple: true, authenticatedAgo: 10 * 60)
    StubURLProtocol.reset()
    FakeFirebase.appleIDOnDevice = "C"
    let flow = AccountDeletionFlow()
    flow.begin(using: f.state)
    flow.confirm(using: f.state)
    try await waitForIdle(flow)
    try check(flow.deletionError != nil, "Apple ID mismatch was not reported")
    try check(FakeFirebase.appleRevocations.isEmpty && SnapshotStore.shared.erasedAccounts.isEmpty
              && StubURLProtocol.sent("deleteAccount").isEmpty, "Apple ID mismatch still deleted something")
    print("PASS different Apple ID is rejected before revocation or erasure")
}

/// Each point where the ceremony waits on the user or the network.
enum CeremonyHold: CaseIterable {
    case confirmationDialog, freshnessCheck, appleSheet, passwordEntry, reauthentication, deletionRequest
}

@MainActor
func ceremonyRaces() async throws {
    for hold in CeremonyHold.allCases {
        for transition in Transition.allCases {
            let f = try TransportFixture()
            let apple = hold == .appleSheet
            await f.signIn("A", apple: apple, authenticatedAgo: hold == .deletionRequest ? 0 : 10 * 60)
            StubURLProtocol.reset()
            let gate = Gate()
            switch hold {
            case .freshnessCheck: FakeFirebase.beforeAuthTime = { await gate.pass() }
            case .appleSheet: FakeFirebase.appleSheet = { await gate.pass() }
            case .reauthentication: FakeFirebase.beforeReauth = { await gate.pass() }
            case .deletionRequest: FakeFirebase.beforeToken = { _ in await gate.pass() }
            case .confirmationDialog, .passwordEntry: break
            }
            let flow = AccountDeletionFlow()
            flow.begin(using: f.state)
            let label = "deletion ceremony at \(hold) after \(transition)"

            switch hold {
            case .confirmationDialog:
                try await transition.apply(to: f)
                flow.confirm(using: f.state)
            case .passwordEntry:
                flow.confirm(using: f.state)
                try await waitUntil("\(label): password not requested") { flow.phase == .password }
                try await transition.apply(to: f)
                flow.submit(password: "correct horse", using: f.state)
            case .reauthentication:
                flow.confirm(using: f.state)
                try await waitUntil("\(label): password not requested") { flow.phase == .password }
                flow.submit(password: "correct horse", using: f.state)
                try await waitUntil("\(label): did not reach hold") { gate.isHeld }
                try await transition.apply(to: f)
                gate.open()
            case .freshnessCheck, .appleSheet, .deletionRequest:
                flow.confirm(using: f.state)
                try await waitUntil("\(label): did not reach hold") { gate.isHeld }
                try await transition.apply(to: f)
                gate.open()
            }
            try await waitForIdle(flow)

            try check(StubURLProtocol.sent("deleteAccount").isEmpty, "\(label): deletion request dispatched")
            try check(FakeFirebase.appleRevocations.isEmpty, "\(label): Apple access revoked")
            // Only a ceremony that reached the request has erased A's device data
            // (A's durable intent may repeat that idempotent erase when A returns);
            // no transition may ever erase anyone else's.
            let expectedErase: Set<String> = hold == .deletionRequest ? ["A"] : []
            try check(Set(SnapshotStore.shared.erasedAccounts) == expectedErase, "\(label): erased \(SnapshotStore.shared.erasedAccounts)")
            try check(flow.deletionError == nil, "\(label): stale ceremony surfaced an error to the new session")
            if f.state.authenticatedUserSub == "B" {
                try check(!f.state.accountDeletionPending, "\(label): B marked for deletion")
            }
        }
        print("PASS deletion ceremony at \(hold): every transition blocked before reaching another session")
    }
}

/// The retry action must honor durable server completion even when the provider
/// is unavailable, while retaining a failed local intent until cleanup succeeds.
@MainActor
func completedCloudDeletionRetriesLocalCleanup(authRemoved: Bool) async throws {
    let f = try TransportFixture()
    await f.signIn("A", apple: true, authenticatedAgo: 10 * 60)
    StubURLProtocol.reset()
    var localAttempts = 0
    SnapshotStore.shared.beforeDurableDelete = {
        localAttempts += 1
        throw CheckFailure(description: "synthetic locked storage")
    }
    defer { SnapshotStore.shared.beforeDurableDelete = nil }
    let flow = AccountDeletionFlow()
    flow.begin(using: f.state)
    flow.confirm(using: f.state)
    try await waitForIdle(flow)
    try check(flow.deletionError != nil && f.state.accountDeletionPending,
              "local failure did not retain a pending deletion")
    let initialProgress = try deletionProgress(f)
    try check(initialProgress["A"] == ["includeLegacy": true, "localComplete": false, "serverComplete": true],
              "cloud success and local failure were not persisted independently")
    try check(StubURLProtocol.sent("deleteAccount").count == 1 && SnapshotStore.shared.erasedAccounts.isEmpty,
              "initial cloud/local failure sequence was not exercised")

    var appleAttempts = 0
    FakeFirebase.appleSheet = {
        appleAttempts += 1
        throw FakeAuthError.noAppleAccount
    }
    if authRemoved { await f.auth.use(nil) }
    // Same entry point as RootView's Retry Deletion. Still-locked storage must
    // be retried without provider access or another cloud request.
    flow.begin(using: f.state, requireConfirmation: false)
    try await waitForIdle(flow)
    try check(localAttempts == 2, "Retry Deletion did not reach pending local cleanup")
    try check(flow.deletionError != nil && f.state.accountDeletionPending,
              "continued local failure lost the recovery intent")
    let retryProgress = try deletionProgress(f)
    try check(retryProgress["A"]?["serverComplete"] == true,
              "continued local failure lost confirmed server completion")

    SnapshotStore.shared.beforeDurableDelete = nil
    flow.begin(using: f.state, requireConfirmation: false)
    try await waitForIdle(flow)
    try check(flow.deletionError == nil && !f.state.accountDeletionPending && !f.state.accountDeletionBusy,
              "Retry Deletion left successful cleanup pending")
    let finalProgress = try deletionProgress(f)
    try check(SnapshotStore.shared.erasedAccounts == ["A"] && finalProgress.isEmpty,
              "Retry Deletion did not finish this account's durable cleanup")
    try check(appleAttempts == 0 && FakeFirebase.events == ["reauthenticate:A", "revokeApple:A"],
              "completed cloud deletion requested Apple authorization again")
    try check(StubURLProtocol.sent("deleteAccount").count == 1,
              "completed cloud deletion was sent again")
    try check(!f.state.isAuthenticated && FakeFirebase.currentUser == nil,
              "completed retry remained signed in")
    print("PASS completed cloud deletion retries local cleanup (Auth removed: \(authRemoved))")
}

@MainActor
func deletionProgress(_ f: TransportFixture) throws -> [String: [String: Bool]] {
    guard let data = f.defaults.data(forKey: "walkworthy.accountDeletionIntents.v2") else { return [:] }
    return try JSONDecoder().decode([String: [String: Bool]].self, from: data)
}

/// Local completion alone cannot skip the provider requirements for cloud work.
@MainActor
func incompleteCloudDeletionStillAuthenticates() async throws {
    for localComplete in [false, true] {
        for apple in [false, true] {
            let f = try TransportFixture()
            await f.signIn("A", apple: apple, authenticatedAgo: 10 * 60)
            let intent = ["A": ["includeLegacy": true, "localComplete": localComplete, "serverComplete": false]]
            f.defaults.set(try JSONEncoder().encode(intent), forKey: "walkworthy.accountDeletionIntents.v2")
            StubURLProtocol.reset()
            FakeFirebase.appleSheet = { throw FakeAuthError.noAppleAccount }
            let flow = AccountDeletionFlow()
            flow.begin(using: f.state, requireConfirmation: false)
            if apple {
                try await waitForIdle(flow)
                try check(flow.deletionError != nil, "unconfirmed cloud deletion skipped unavailable Apple authorization")
            } else {
                try await waitUntil("unconfirmed cloud deletion skipped the password prompt") { flow.phase == .password }
            }
            let progress = try deletionProgress(f)
            try check(progress == intent && SnapshotStore.shared.erasedAccounts.isEmpty
                      && StubURLProtocol.sent("deleteAccount").isEmpty,
                      "unconfirmed cloud deletion proceeded before required authentication")
            if apple {
                FakeFirebase.appleSheet = nil
                flow.begin(using: f.state, requireConfirmation: false)
            } else {
                flow.submit(password: "correct horse", using: f.state)
            }
            try await waitForIdle(flow)
            let finalProgress = try deletionProgress(f)
            let sent = StubURLProtocol.sent("deleteAccount")
            try check(flow.deletionError == nil && finalProgress.isEmpty && !f.state.isAuthenticated,
                      "authenticated incomplete-cloud retry did not finish")
            try check(sent.count == 1 && sent[0].authorization == "Bearer token:A:1:recent"
                      && SnapshotStore.shared.erasedAccounts == ["A"],
                      "authenticated incomplete-cloud retry did not finish both sides for A")
        }
    }
    print("PASS incomplete cloud deletion requires authentication for both local-completion states and providers")
}

/// A persisted, fully completed intent may still need idempotent cleanup and
/// sign-out (for example, after an earlier sign-out failure).
@MainActor
func completedDeletionIntentStillFinishesLocally() async throws {
    let f = try TransportFixture()
    await f.signIn("A", apple: true)
    f.defaults.set(try JSONEncoder().encode([
        "A": ["includeLegacy": true, "localComplete": true, "serverComplete": true]
    ]), forKey: "walkworthy.accountDeletionIntents.v2")
    await f.auth.use(nil)
    StubURLProtocol.reset()
    let flow = AccountDeletionFlow()
    flow.begin(using: f.state, requireConfirmation: false)
    try await waitForIdle(flow)
    let progress = try deletionProgress(f)
    try check(flow.deletionError == nil && progress.isEmpty && !f.state.isAuthenticated,
              "fully completed persisted intent did not finish without Auth")
    try check(SnapshotStore.shared.erasedAccounts == ["A"] && StubURLProtocol.sent("deleteAccount").isEmpty,
              "fully completed intent skipped idempotent local cleanup or repeated cloud deletion")
    print("PASS persisted local/server completion finishes without a Firebase user")
}

@MainActor
func completedDeletionDoesNotAuthorizeAnotherSession() async throws {
    for transition in [Transition.switchToB, .switchToBThenBackToA, .signOutThenSignInSameUID] {
        let f = try TransportFixture()
        await f.signIn("A", apple: true)
        let originalSession = f.state.authenticatedSession!
        try await transition.apply(to: f)
        // Seed after the transition so automatic recovery cannot consume it.
        let intent = ["A": ["includeLegacy": true, "localComplete": false, "serverComplete": true]]
        f.defaults.set(try JSONEncoder().encode(intent), forKey: "walkworthy.accountDeletionIntents.v2")
        StubURLProtocol.reset()
        do {
            _ = try await f.state.prepareAccountDeletion(session: originalSession)
            throw CheckFailure(description: "completed server intent accepted a superseded app session")
        } catch is CancellationError {}
        let progress = try deletionProgress(f)
        try check(progress == intent && SnapshotStore.shared.erasedAccounts.isEmpty
                  && StubURLProtocol.sent("deleteAccount").isEmpty,
                  "superseded preparation modified deletion progress")
    }

    let f = try TransportFixture()
    await f.signIn("B", apple: true, authenticatedAgo: 10 * 60)
    let intent = ["A": ["includeLegacy": true, "localComplete": false, "serverComplete": true]]
    f.defaults.set(try JSONEncoder().encode(intent), forKey: "walkworthy.accountDeletionIntents.v2")
    StubURLProtocol.reset()
    FakeFirebase.appleSheet = { throw FakeAuthError.noAppleAccount }
    let flow = AccountDeletionFlow()
    flow.begin(using: f.state, requireConfirmation: false)
    try await waitForIdle(flow)
    let progress = try deletionProgress(f)
    try check(flow.deletionError != nil && progress == intent && f.state.authenticatedUserSub == "B",
              "A's completed cloud deletion authorized B's deletion")
    try check(SnapshotStore.shared.erasedAccounts.isEmpty && StubURLProtocol.sent("deleteAccount").isEmpty,
              "B's unauthenticated deletion erased local or server data")
    print("PASS completed server intent does not authorize a stale app session or another account")
}
