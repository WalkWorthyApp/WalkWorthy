import Foundation
import SwiftData

/// Records every request that reaches the network layer. Paths listed in
/// `unauthorizedOnce` answer 401 the first time to exercise the forced retry.
nonisolated final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Sent { let path: String; let authorization: String? }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var log: [Sent] = []
    nonisolated(unsafe) private static var unauthorized: Set<String> = []

    static func reset(unauthorizedOnce: Set<String> = []) {
        lock.withLock { log = []; unauthorized = unauthorizedOnce }
    }

    static func sent(_ path: String) -> [Sent] {
        lock.withLock { log.filter { $0.path == path } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.lastPathComponent ?? ""
        let rejected = Self.lock.withLock {
            Self.log.append(Sent(path: path, authorization: request.value(forHTTPHeaderField: "Authorization")))
            return Self.unauthorized.remove(path) != nil
        }
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let (status, body): (Int, String) = switch path {
        case _ where rejected: (401, "{}")
        case "userProfile": (200, #"{"profile":null}"#)
        // Mirrors requestAccountDeletion: a new job needs auth_time < 5 minutes.
        case "deleteAccount" where authorization.hasSuffix(":stale"): (401, #"{"message":"Sign in again to delete your account"}"#)
        case "deleteAccount": (200, #"{"deleted":true}"#)
        default: (404, "{}")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Suspends the first caller that reaches it until opened.
@MainActor
final class Gate {
    private var armed = true
    private var waiter: CheckedContinuation<Void, Never>?
    var isHeld: Bool { waiter != nil }

    func pass() async {
        guard armed else { return }
        armed = false
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        waiter?.resume()
        waiter = nil
    }
}

@MainActor
struct TransportFixture {
    let auth = FirebaseAuthSession()
    let defaults = MemoryDefaults()
    let state: AppState

    init() throws {
        FakeFirebase.reset()
        StubURLProtocol.reset()
        SnapshotStore.shared.data = [:]
        SnapshotStore.shared.deletedUsers = []
        SnapshotStore.shared.erasedAccounts = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let api = LiveAPIClient(
            baseURL: URL(string: "https://walkworthy.invalid")!,
            tokenProvider: auth,
            appCheckProvider: auth,
            urlSession: URLSession(configuration: configuration)
        )
        let container = try ModelContainer(for: JournalEntry.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        state = AppState(apiClient: api, authSession: auth, defaults: defaults, modelContainer: container)
    }

    func use(_ sub: String) async {
        await auth.use(sub)
        state.isAuthenticated = true
        await state.refreshAuthenticatedUser()
    }

    /// A fresh sign-in with a chosen provider and `auth_time` age.
    func signIn(_ sub: String, apple: Bool = false, authenticatedAgo: TimeInterval = 0) async {
        FakeFirebase.signIn(sub, apple: apple, authenticatedAgo: authenticatedAgo)
        state.isAuthenticated = true
        await state.refreshAuthenticatedUser()
    }
}

/// Every way the signed-in account can change under in-flight work. The
/// `firebase*` cases model Firebase changing before AppState's listener runs.
enum Transition: CaseIterable {
    case firebaseSwitchToB, firebaseReSignInSameUID, switchToB, switchToBThenBackToA, signOutThenSignInSameUID

    @MainActor
    func apply(to f: TransportFixture) async throws {
        switch self {
        case .firebaseSwitchToB:
            FakeFirebase.signIn("B")
        case .firebaseReSignInSameUID:
            FakeFirebase.signIn("A")
        case .switchToB:
            await f.use("B")
        case .switchToBThenBackToA:
            await f.use("B")
            await f.use("A")
        case .signOutThenSignInSameUID:
            f.state.signOut()
            try await waitUntil("sign-out did not reach Firebase") { FakeFirebase.currentUser == nil }
            f.state.isAuthenticated = false
            await f.state.refreshAuthenticatedUser()
            FakeFirebase.signIn("A")
            f.state.isAuthenticated = true
            await f.state.refreshAuthenticatedUser()
        }
    }
}

/// Starts account-owned work as A's first sign-in, holds it at a suspension
/// point, applies `transition`, then releases it. Returns what reached the network.
@MainActor
func race(
    _ path: String,
    transition: Transition?,
    unauthorizedOnce: Bool = false,
    holdAt hold: (Gate) -> Void,
    start: (AppState) -> Task<Void, Never>?
) async throws -> [StubURLProtocol.Sent] {
    let f = try TransportFixture()
    await f.use("A")
    StubURLProtocol.reset(unauthorizedOnce: unauthorizedOnce ? [path] : [])
    let gate = Gate()
    hold(gate)
    let work = start(f.state)
    try await waitUntil("\(path) work did not reach the hold point") { gate.isHeld }
    if let transition { try await transition.apply(to: f) }
    let preferenceBeforeRelease = f.state.useProfilePersonalization
    gate.open()
    if transition == nil {
        let expected = unauthorizedOnce ? 2 : 1
        try await waitUntil("same-session \(path) request was not sent") { StubURLProtocol.sent(path).count == expected }
    } else {
        // Give a wrongly authorized request every chance to be dispatched.
        try await Task.sleep(for: .milliseconds(300))
        try check(f.state.useProfilePersonalization == preferenceBeforeRelease,
                  "\(path): superseded work rolled back the new session's preference")
    }
    // Settle before the next fixture reuses the process-wide Firebase stand-in.
    await work?.value
    return StubURLProtocol.sent(path)
}

let originalAToken = "Bearer token:A:1:recent"

@MainActor
func checkRaces(
    _ name: String,
    _ path: String,
    unauthorizedOnce: Bool = false,
    holdAt hold: @escaping (Gate) -> Void,
    start: @escaping (AppState) -> Task<Void, Never>?
) async throws {
    let control = try await race(path, transition: nil, unauthorizedOnce: unauthorizedOnce, holdAt: hold, start: start)
    try check(control.allSatisfy { $0.authorization == originalAToken }, "\(name): control used another credential")
    for transition in Transition.allCases {
        let sent = try await race(path, transition: transition, unauthorizedOnce: unauthorizedOnce, holdAt: hold, start: start)
        let expected = unauthorizedOnce ? 1 : 0 // the pre-transition 401 attempt
        try check(sent.count == expected, "\(name) after \(transition): \(sent.count) request(s) dispatched")
        try check(sent.allSatisfy { $0.authorization == originalAToken }, "\(name) after \(transition): sent another credential")
    }
    print("PASS \(name): same-session control sent; every transition blocked")
}

@main
struct TransportBindingTests {
    @MainActor
    static func main() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let holdToken: (Gate) -> Void = { gate in FakeFirebase.beforeToken = { _ in await gate.pass() } }
        let holdRefresh: (Gate) -> Void = { gate in FakeFirebase.beforeToken = { forcing in if forcing { await gate.pass() } } }
        let holdAppCheck: (Gate) -> Void = { gate in FakeFirebase.beforeAppCheck = { await gate.pass() } }
        let saveProfile: (AppState) -> Task<Void, Never>? = {
            $0.updateProfile(firstName: "Alice", age: 30, occupation: "student", major: "", hobbies: [], optIn: true)
            return nil
        }
        let togglePersonalization: (AppState) -> Task<Void, Never>? = { $0.setUseProfilePersonalization(true); return nil }

        try await checkRaces("debounced profile save at token fetch", "userProfile", holdAt: holdToken, start: saveProfile)
        try await checkRaces("debounced profile save after App Check", "userProfile", holdAt: holdAppCheck, start: saveProfile)
        try await checkRaces("profile save 401 forced-refresh retry", "userProfile", unauthorizedOnce: true, holdAt: holdRefresh, start: saveProfile)
        try await checkRaces("personalization toggle at token fetch", "userProfile", holdAt: holdToken, start: togglePersonalization)
        try await checkRaces("account deletion at token fetch", "deleteAccount", holdAt: holdToken) { state in
            Task { try? await state.deleteAccount(session: state.authenticatedSession!) }
        }
        try await runDeletionFlowTests()
        print("All transport-binding scenarios passed. Firebase is simulated; the binding logic is production code.")
    }
}
