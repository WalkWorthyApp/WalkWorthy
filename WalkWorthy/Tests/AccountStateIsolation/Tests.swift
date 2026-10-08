import Foundation
import SwiftData

@MainActor
struct Fixture {
    let api = TestAPI()
    let auth = FirebaseAuthSession()
    let defaults = MemoryDefaults()
    let container: ModelContainer
    let state: AppState

    init() throws {
        FakeFirebase.reset()
        SnapshotStore.shared.data = [:]
        SnapshotStore.shared.deletedUsers = []
        SnapshotStore.shared.beforeBegin = nil
        SnapshotStore.shared.beginError = nil
        SnapshotStore.shared.beforeDurableDelete = nil
        container = try ModelContainer(for: JournalEntry.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        state = AppState(apiClient: api, authSession: auth, defaults: defaults, modelContainer: container)
    }

    func use(_ sub: String) async {
        await auth.use(sub)
        state.isAuthenticated = true
        await state.refreshAuthenticatedUser()
    }

    func populateA() async throws {
        await use("A")
        api.profile = profile("Alice")
        await state.refreshProfileFromBackend()
        await state.loadMoodStatus()
        state.latestMoodResponse = .init(checkInId: "A-check-in", aiResponse: encouragement, createdAt: "today", expiresAt: "later", isExisting: false)
        state.dailyReflection = .init(reflection: "A private reflection", generatedAt: "today", date: "today")
        state.weekSummary = [summary("A-day")]
        state.moodLogFirstPage = [.init(id: "A-check-in", checkInType: "morning", timestamp: "today", date: "today", moodSpectrumData: nil, aiResponse: encouragement, createdAt: "today", expiresAt: "later")]
        try state.createJournalEntry(text: "A private journal")
        state.journalError = "A private error"
    }
}

@MainActor
func profile(_ name: String) -> RemoteUserProfileResponse {
    .init(ageRange: nil, firstName: name, occupation: nil, major: nil, hobbies: nil, optInTailored: false, timezone: nil, checkInTimes: nil)
}

@MainActor
func summary(_ date: String) -> DailyMoodSummary {
    .init(date: date, morning: nil, midday: nil, evening: nil, overallSentiment: nil, updatedAt: nil)
}

@MainActor
var encouragement: AIEncouragementResponse {
    .init(message: "A private encouragement", verseRef: "test", verseText: "test", translation: "test", supportResource: nil, isGenerated: false)
}

@MainActor
func checkCleared(_ state: AppState) throws {
    try check(state.currentProfile == nil, "outgoing profile survived")
    try check(state.currentMoodStatus == nil, "outgoing mood status survived")
    try check(state.latestMoodResponse == nil, "outgoing response survived")
    try check(state.dailyReflection == nil, "outgoing reflection survived")
    try check(state.weekSummary.isEmpty, "outgoing week summary survived")
    try check(state.moodLogFirstPage.isEmpty, "outgoing log survived")
    try check(state.journalEntries.isEmpty, "outgoing journal survived in memory")
    try check(state.journalError == nil, "outgoing journal error survived")
}

@MainActor
func seedHTTPResponse() throws -> URLRequest {
    let url = URL(string: "https://example.invalid/synthetic-private-response")!
    let request = URLRequest(url: url)
    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Cache-Control": "max-age=3600"])!
    URLCache.shared.storeCachedResponse(CachedURLResponse(response: response, data: Data("synthetic".utf8),
                                                         storagePolicy: .allowedInMemoryOnly), for: request)
    try check(URLCache.shared.cachedResponse(for: request) != nil, "HTTP cache fixture was not stored")
    return request
}

@main
struct AccountStateIsolationTests {
    @MainActor
    static func main() async throws {
        // Replace the shared cache only in this test process; no app cache or
        // disk-backed HTTP data is read or changed.
        let originalCache = URLCache.shared
        URLCache.shared = URLCache(memoryCapacity: 1_048_576, diskCapacity: 0, diskPath: nil)
        defer { URLCache.shared = originalCache }

        do {
            let request = try seedHTTPResponse()
            let session = LiveAPIClient.makeDefaultSession()
            defer { session.invalidateAndCancel() }
            try check(URLCache.shared.cachedResponse(for: request) == nil, "session startup retained legacy HTTP cache")
            try check(session.configuration.urlCache == nil, "default session retained a URL cache")
            try check(session.configuration.requestCachePolicy == .reloadIgnoringLocalCacheData, "default session may reuse cached responses")
            try check(session.configuration.timeoutIntervalForRequest == 30 && session.configuration.timeoutIntervalForResource == 45, "session deadlines changed")
            print("PASS production HTTP session bypasses cache and evicts legacy responses")
        }

        do {
            let f = try Fixture()
            await f.use("A")
            let request = try seedHTTPResponse()
            await f.use("A")
            try check(URLCache.shared.cachedResponse(for: request) != nil, "same-UID refresh purged HTTP cache")
            await f.use("B")
            try check(URLCache.shared.cachedResponse(for: request) == nil, "UID transition retained legacy HTTP cache")
            let signedOutRequest = try seedHTTPResponse()
            f.state.signOut()
            try check(URLCache.shared.cachedResponse(for: signedOutRequest) == nil, "sign-out did not purge HTTP cache synchronously")
            try await waitUntil("test sign-out did not complete") { (try? await f.auth.currentUserSub()) == nil }
            print("PASS HTTP cache purges on UID changes and sign-out, not same-UID refresh")
        }

        for initiallyComplete in [false, true] {
            let f = try Fixture()
            let intent = ["A": ["includeLegacy": false, "localComplete": initiallyComplete, "serverComplete": false]]
            f.defaults.set(try JSONSerialization.data(withJSONObject: intent), forKey: "walkworthy.accountDeletionIntents.v2")
            for _ in 0..<2 {
                let request = try seedHTTPResponse()
                SnapshotStore.shared.beforeDurableDelete = {
                    try check(URLCache.shared.cachedResponse(for: request) == nil, "deletion reached durable cleanup before HTTP-cache purge")
                }
                await f.state.resumePendingLocalDeletions()
                try check(f.state.accountDeletionError == nil, "deletion cleanup failed")
                try check(URLCache.shared.cachedResponse(for: request) == nil, "repeatable deletion retained HTTP cache")
                let data = f.defaults.data(forKey: "walkworthy.accountDeletionIntents.v2")!
                let saved = try JSONSerialization.jsonObject(with: data) as! [String: [String: Bool]]
                try check(saved["A"]?["localComplete"] == true, "local cleanup was not marked complete")
            }
            print("PASS repeated deletion purges HTTP cache before completion (initiallyComplete=\(initiallyComplete))")
        }

        // Missing and corrupt B snapshots exercise the production hydrator's
        // nil-return branches while the reset runs in the real AppState.
        for corrupt in [false, true] {
            let f = try Fixture()
            try await f.populateA()
            let outgoing = f.state.authenticatedSession!
            let originalSnapshots = SnapshotStore.shared.data
            if corrupt {
                for kind in [SnapshotKind.profile, .moodStatus, .dailyReflection, .weekSummary] {
                    SnapshotStore.shared.corrupt(kind: kind, userSub: "B")
                }
            }
            SnapshotStore.shared.beforeBegin = { try checkCleared(f.state) }
            await f.use("B")
            if let error = SnapshotStore.shared.beginError { throw error }
            SnapshotStore.shared.beforeBegin = nil
            try checkCleared(f.state)
            try check(!f.state.isCurrentSession(outgoing), "A identity remained valid in B")
            let rows = try f.container.mainContext.fetch(FetchDescriptor<JournalEntry>())
            try check(rows.count == 1 && rows[0].userSub == "A", "transition deleted A's stored journal")
            try check(SnapshotStore.shared.deletedUsers.isEmpty, "transition deleted stored snapshots")
            for (key, value) in originalSnapshots {
                try check(SnapshotStore.shared.data[key] == value, "transition changed outgoing snapshot")
            }
            let calls = f.api.statusCalls
            await f.state.loadMoodStatus()
            try check(f.api.statusCalls == calls + 1, "B inherited A's mood-status throttle")
            print("PASS A-to-B clears memory before hydration; persistence retained (corrupt=\(corrupt))")
        }

        do {
            let f = try Fixture()
            try await f.populateA()
            try SnapshotStore.shared.seed(profile("Bob"), kind: .profile, userSub: "B")
            try SnapshotStore.shared.seed([summary("B-day")], kind: .weekSummary, userSub: "B")
            await f.use("B")
            try check(f.state.currentProfile?.firstName == "Bob", "B profile failed to hydrate")
            try check(f.state.weekSummary.first?.date == "B-day", "B summary failed to hydrate")
            let current = f.state.authenticatedSession!
            await f.use("B")
            try check(f.state.authenticatedSession == current, "same-UID refresh changed generation")
            try check(f.state.currentProfile?.firstName == "Bob", "same-UID refresh lost state")
            print("PASS valid B hydration and same-UID refresh")
        }

        do {
            let f = try Fixture()
            await f.use("A")
            let oldA = f.state.authenticatedSession!
            await f.use("B")
            await f.use("A")
            try check(!f.state.isCurrentSession(oldA), "A-to-B-to-A revived old identity")
            await f.state.publishWeekSummary([summary("stale")], session: oldA)
            try check(f.state.weekSummary.isEmpty, "old A published a week summary")
            try check(SnapshotStore.shared.readSync([DailyMoodSummary].self, kind: .weekSummary, userSub: "A") == nil, "old A wrote a snapshot")
            let newA = f.state.authenticatedSession!
            await f.state.publishWeekSummary([summary("current")], session: newA)
            try check(f.state.weekSummary.first?.date == "current", "current session publication rejected")
            f.state.signOut()
            try check(f.state.authenticatedSession == nil && !f.state.isCurrentSession(newA), "sign-out did not invalidate synchronously")
            try checkCleared(f.state)
            // Wait for the test auth adapter's sign-out, then deliver the signed-out
            // state as Firebase's listener would. No actual Firebase SDK is loaded.
            try await waitUntil("test auth sign-out did not complete") {
                (try? await f.auth.currentUserSub()) == nil
            }
            f.state.isAuthenticated = false
            await f.state.refreshAuthenticatedUser()
            await f.use("A")
            try check(!f.state.isCurrentSession(newA), "sign-out/re-login reused identity")
            print("PASS ABA and sign-out/re-login generations; current publication allowed")
        }

        do {
            let f = try Fixture()
            await f.use("A")
            let oldA = f.state.authenticatedSession!
            await f.auth.failSignOut(true)
            f.api.profile = profile("recovered Alice")
            f.state.signOut()
            try check(!f.state.isCurrentSession(oldA), "failed sign-out did not invalidate eagerly")
            try await waitUntil("failed sign-out did not recover") {
                f.state.authenticatedSession != nil
            }
            await f.state.refreshAuthenticatedUser()
            await f.state.refreshProfileFromBackend()
            await f.state.loadMoodStatus()
            try check(!f.state.isCurrentSession(oldA), "failed sign-out revived the old generation")
            try check(f.state.authenticatedUserSub == "A", "failed sign-out changed the account")
            try check(f.state.currentProfile?.firstName == "recovered Alice" && f.state.currentMoodStatus != nil, "failed sign-out stranded account-owned reads")
            try check(f.state.authenticationNotice == "Sign out could not be completed. Please try again.", "failed sign-out did not report recovery")
            print("PASS failed sign-out recovery uses a fresh generation")
        }

        // Held network responses prove the real production publishers reject
        // prior-session work, including return to the same UID (ABA).
        for returnToA in [false, true] {
            let f = try Fixture()
            await f.use("A")
            f.api.holdProfile = true
            f.api.holdStatus = true
            let oldProfile = Task { await f.state.refreshProfileFromBackend() }
            let oldStatus = Task { await f.state.loadMoodStatus() }
            try await waitUntil("test requests did not suspend") {
                f.api.heldProfile != nil && f.api.heldStatus != nil
            }
            await f.use("B")
            if returnToA { await f.use("A") }
            f.api.heldProfile!.resume(returning: profile("stale Alice"))
            f.api.heldStatus!.resume(returning: .init(status: "stale A", pendingCheckIn: nil, checkIn: nil, summary: nil))
            await oldProfile.value
            await oldStatus.value
            try check(f.state.currentProfile == nil && f.state.currentMoodStatus == nil, "stale response published")
            try check(SnapshotStore.shared.data.isEmpty, "stale response wrote a snapshot")
            f.api.holdProfile = false
            f.api.holdStatus = false
            f.api.profile = profile("current")
            await f.state.refreshProfileFromBackend()
            await f.state.loadMoodStatus()
            try check(f.state.currentProfile?.firstName == "current" && f.state.currentMoodStatus != nil, "current responses rejected")
            print("PASS delayed profile/status rejection and legitimate controls (ABA=\(returnToA))")
        }

        do {
            let f = try Fixture()
            await f.use("A")
            let confirmation = f.state.authenticatedSession!
            f.api.deletion = {
                try check(f.state.authenticatedSession == confirmation, "deletion rotated confirmation identity")
                try check(!f.state.isCurrentSession(confirmation), "ordinary work allowed during deletion")
                try check(f.state.isCurrentSession(confirmation, allowingAccountDeletion: true), "confirmation-bound deletion rejected")
            }
            try await f.state.deleteAccount(session: confirmation)
            try check(!f.state.isCurrentSession(confirmation, allowingAccountDeletion: true), "completed deletion retained identity")
            print("PASS deletion continuation preserves identity but blocks ordinary publication")
        }
        print("All account-state regression scenarios passed. Forced transitions only; shipped exploit reachability remains unproven.")
    }
}
