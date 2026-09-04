//
//  SnapshotStore.swift
//  WalkWorthy
//
//  On-disk snapshot cache for server-backed AppState. Reads are synchronous
//  during sign-in hydration; writes are debounced and atomic (write-then-
//  rename). One directory per authenticated user. See
//  docs/superpowers/specs/2026-07-18-instant-launch-snapshot-cache-design.md.
//

import Foundation

/// Wraps a payload with the metadata needed to invalidate stale on-disk data
/// after a payload's Codable shape changes (bump `SnapshotKind.currentSchemaVersion`).
///
/// Marked `nonisolated` because the project defaults actor isolation to
/// `@MainActor` (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`); without this,
/// the type's `Codable` conformance would be main-actor-isolated, which
/// breaks the deliberately off-main-actor `SnapshotStore.readSync`/`write`.
nonisolated struct Snapshot<T: Codable>: Codable {
    let payload: T
    let capturedAt: Date
    let schemaVersion: Int
}

/// Marked `nonisolated` for the same reason as `Snapshot` above — this is a
/// plain value type read from both `readSync` (nonisolated) and the
/// `SnapshotStore` actor, so it must not inherit the project's main-actor
/// default isolation.
nonisolated enum SnapshotKind: String {
    case profile
    case moodStatus
    case dailyReflection
    case weekSummary
    case moodLogFirstPage

    /// Bump this any time the payload's `Codable` shape changes non-additively.
    /// Stale files fall through as a cache miss on the next read.
    var currentSchemaVersion: Int {
        switch self {
        case .profile: return 1
        case .moodStatus: return 1
        case .dailyReflection: return 1
        case .weekSummary: return 1
        case .moodLogFirstPage: return 1
        }
    }
}

actor SnapshotStore {
    static let shared = SnapshotStore()

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    /// Pending debounced write tasks keyed by absolute file URL, so a burst of
    /// writes to the same snapshot collapses into one disk touch.
    private var pendingWrites: [URL: Task<Void, Never>] = [:]
    /// Monotonic per-URL write generation. `performWrite` only proceeds (and
    /// only clears `pendingWrites`) when it still holds the newest generation
    /// for its URL, so a stale task whose cancellation raced with the actor
    /// hop cannot clobber a newer pending entry. Never reset — resetting
    /// would allow generation reuse and reintroduce the race.
    private var writeGeneration: [URL: UInt64] = [:]
    /// Tombstones set by `deleteAll` so an in-flight write that already
    /// passed its cancellation check cannot recreate a deleted user's
    /// directory. Only `beginSession(for:)` lifts a tombstone — `write()`
    /// itself never clears one, so a queued/in-flight write from the
    /// departed session can't resurrect the directory.
    private var deletedUsers: Set<String> = []

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    // MARK: - Read (synchronous)

    /// Synchronous read used during AppState hydration on the main actor.
    /// Never throws. Any error (missing file, corrupt JSON, schema mismatch)
    /// is treated as a cache miss and returns nil.
    nonisolated func readSync<T: Codable & Sendable>(
        _ type: T.Type,
        kind: SnapshotKind,
        userSub: String,
        dateSuffix: String? = nil
    ) -> Snapshot<T>? {
        guard let url = Self.snapshotURL(kind: kind, userSub: userSub, dateSuffix: dateSuffix) else {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(Snapshot<T>.self, from: data) else {
            #if DEBUG
            print("[SnapshotStore] Failed to decode \(kind.rawValue) at \(url.lastPathComponent)")
            #endif
            return nil
        }
        guard snapshot.schemaVersion == kind.currentSchemaVersion else {
            return nil
        }
        return snapshot
    }

    // MARK: - Write (debounced + atomic)

    /// Debounced write: bursts within 250ms collapse into one atomic rename.
    /// Fire-and-forget from the caller's perspective.
    func write<T: Codable & Sendable>(
        _ payload: T,
        kind: SnapshotKind,
        userSub: String,
        dateSuffix: String? = nil
    ) {
        guard let url = Self.snapshotURL(kind: kind, userSub: userSub, dateSuffix: dateSuffix) else {
            return
        }
        let generation = (writeGeneration[url] ?? 0) &+ 1
        writeGeneration[url] = generation
        pendingWrites[url]?.cancel()
        pendingWrites[url] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            await self?.performWrite(
                payload: payload,
                url: url,
                kind: kind,
                userSub: userSub,
                generation: generation
            )
        }
    }

    private func performWrite<T: Codable & Sendable>(
        payload: T,
        url: URL,
        kind: SnapshotKind,
        userSub: String,
        generation: UInt64
    ) {
        // Superseded by a newer write for this URL: our cancellation raced
        // with the actor hop. Bail without touching the newer pending entry.
        guard writeGeneration[url] == generation else { return }
        pendingWrites[url] = nil
        // deleteAll ran after this write was queued — honor the deletion
        // rather than recreating the user's snapshot directory.
        guard !deletedUsers.contains(userSub) else { return }
        // Cancellation may have landed after the sleep-side check.
        if Task.isCancelled { return }
        let snapshot = Snapshot(
            payload: payload,
            capturedAt: Date(),
            schemaVersion: kind.currentSchemaVersion
        )
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            try Self.excludeFromBackup(url.deletingLastPathComponent())
            let data = try encoder.encode(snapshot)
            let tmpURL = url.appendingPathExtension("tmp")
            // Ensure no stale temp file confuses the atomic replace.
            try? fileManager.removeItem(at: tmpURL)
            try data.write(to: tmpURL, options: [.atomic, .completeFileProtection])
            // Atomic on the same volume: readers see either the old file or
            // the new file, never a partially written snapshot.
            _ = try fileManager.replaceItemAt(url, withItemAt: tmpURL)
            try Self.excludeFromBackup(url)
        } catch {
            #if DEBUG
            print("[SnapshotStore] Write failed for \(url.lastPathComponent): \(error)")
            #endif
        }
    }

    // MARK: - Delete (sign-out / account delete)

    func deleteAll(for userSub: String) {
        // Tombstone first: an in-flight write that already passed its
        // cancellation check will see this in performWrite and abort instead
        // of recreating the directory. Only beginSession(for:) lifts this
        // tombstone (i.e. a fresh sign-in) — write() no longer clears it.
        deletedUsers.insert(userSub)
        guard let dir = Self.userDirectory(userSub: userSub) else { return }
        // Cancel any queued writes for this user so they can't recreate the
        // directory after we delete it.
        for (url, task) in pendingWrites where url.deletingLastPathComponent().path == dir.path {
            task.cancel()
            pendingWrites[url] = nil
        }
        try? fileManager.removeItem(at: dir)
    }

    /// Re-enables writes for a user after a fresh sign-in. deleteAll(for:)
    /// tombstones the sub so queued/in-flight writes from the departed
    /// session can't recreate the directory; only an explicit new session
    /// may lift the tombstone.
    func beginSession(for userSub: String) {
        deletedUsers.remove(userSub)
    }

    // MARK: - Paths

    private static let rootDirectoryName = "WalkWorthy/Snapshots"

    private nonisolated static func excludeFromBackup(_ url: URL) throws {
        var protectedURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedURL.setResourceValues(values)
    }

    private static func rootDirectory() -> URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent(rootDirectoryName, isDirectory: true)
    }

    private static func userDirectory(userSub: String) -> URL? {
        guard !userSub.isEmpty, !userSub.contains("/") else { return nil }
        return rootDirectory()?.appendingPathComponent(userSub, isDirectory: true)
    }

    private static func snapshotURL(
        kind: SnapshotKind,
        userSub: String,
        dateSuffix: String?
    ) -> URL? {
        guard let dir = userDirectory(userSub: userSub) else { return nil }
        let fileName: String
        if let dateSuffix, !dateSuffix.isEmpty {
            fileName = "\(kind.rawValue)_\(dateSuffix).json"
        } else {
            fileName = "\(kind.rawValue).json"
        }
        return dir.appendingPathComponent(fileName)
    }
}

// MARK: - DEBUG self-check

#if DEBUG
extension SnapshotStore {
    /// Round-trips a fake profile snapshot through disk, verifies each
    /// invariant, then cleans up. Logs `[SnapshotStore] self-check OK` on
    /// success. Called at app launch from AppState.init in DEBUG builds; a
    /// failure indicates a regression in the store, not user data corruption.
    nonisolated static func runSelfCheck() async {
        struct Fake: Codable, Equatable { let a: String; let b: Int }
        let sub = "self-check-user-\(UUID().uuidString)"
        let store = SnapshotStore()

        // Write → readSync round-trip
        await store.write(Fake(a: "hi", b: 42), kind: .profile, userSub: sub)
        // Wait past the 250 ms debounce plus a small margin.
        try? await Task.sleep(for: .milliseconds(400))
        guard let read: Snapshot<Fake> = store.readSync(Fake.self, kind: .profile, userSub: sub),
              read.payload == Fake(a: "hi", b: 42) else {
            print("[SnapshotStore] self-check FAILED: round-trip")
            await store.deleteAll(for: sub)
            return
        }

        // deleteAll clears the directory, and a write queued BEFORE deleteAll
        // must not recreate any data afterwards (cancellation + tombstone).
        await store.write(Fake(a: "bye", b: 7), kind: .profile, userSub: sub)
        await store.deleteAll(for: sub)
        if store.readSync(Fake.self, kind: .profile, userSub: sub) != nil {
            print("[SnapshotStore] self-check FAILED: deleteAll left data behind")
            return
        }
        // Wait past the debounce window; the queued write must stay dead.
        try? await Task.sleep(for: .milliseconds(400))
        if store.readSync(Fake.self, kind: .profile, userSub: sub) != nil {
            print("[SnapshotStore] self-check FAILED: queued write recreated data after deleteAll")
            return
        }

        // A brand-new write() call after deleteAll — with no beginSession —
        // must also stay dead. write() no longer lifts the tombstone itself;
        // only an explicit new session (beginSession) may.
        await store.write(Fake(a: "ghost", b: 1), kind: .profile, userSub: sub)
        try? await Task.sleep(for: .milliseconds(400))
        if store.readSync(Fake.self, kind: .profile, userSub: sub) != nil {
            print("[SnapshotStore] self-check FAILED: write after deleteAll resurrected data without beginSession")
            return
        }

        // Simulate a fresh sign-in: beginSession lifts the tombstone, and a
        // subsequent write for the same sub should succeed again.
        await store.beginSession(for: sub)
        await store.write(Fake(a: "reborn", b: 2), kind: .profile, userSub: sub)
        try? await Task.sleep(for: .milliseconds(400))
        guard let revived: Snapshot<Fake> = store.readSync(Fake.self, kind: .profile, userSub: sub),
              revived.payload == Fake(a: "reborn", b: 2) else {
            print("[SnapshotStore] self-check FAILED: write after beginSession did not persist")
            await store.deleteAll(for: sub)
            return
        }
        await store.deleteAll(for: sub)

        print("[SnapshotStore] self-check OK")
    }
}
#endif
