import Foundation
import Combine
import AuthenticationServices

/// The deletion ceremony uses only an identity captured before confirmation.
/// AppState and the transport independently enforce the same identity at use.
@MainActor
protocol AccountDeletionActions: AnyObject {
    var authenticatedSession: AuthSessionIdentity? { get }
    var accountDeletionBusy: Bool { get }
    func isCurrentSession(_ session: AuthSessionIdentity, allowingAccountDeletion: Bool) -> Bool
    func prepareAccountDeletion(session: AuthSessionIdentity) async throws -> Bool
    func reauthenticateForAccountDeletion(password: String, session: AuthSessionIdentity) async throws
    func deleteAccount(session: AuthSessionIdentity) async throws
}

/// RootView owns this flow so entering the durable-cleanup screen does not
/// destroy an authorized request. Dismissal and account changes invalidate
/// unfinished ceremonies, including callbacks that do not honor cancellation.
@MainActor
final class AccountDeletionFlow: ObservableObject {
    enum Phase {
        case idle, confirmation, preparing, password, reauthenticating, deleting
    }

    private struct Ceremony {
        let id = UUID()
        let session: AuthSessionIdentity
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var passwordError: Error?
    @Published private(set) var deletionError: Error?
    private var ceremony: Ceremony?
    private var operation: Task<Void, Never>?

    var isWorking: Bool {
        phase == .preparing || phase == .reauthenticating || phase == .deleting
    }

    var isPresentingPassword: Bool {
        phase == .password || phase == .reauthenticating
    }

    func begin(using actions: any AccountDeletionActions, requireConfirmation: Bool = true) {
        guard phase == .idle, !actions.accountDeletionBusy,
              let session = actions.authenticatedSession,
              actions.isCurrentSession(session, allowingAccountDeletion: true) else { return }
        deletionError = nil
        passwordError = nil
        ceremony = Ceremony(session: session)
        phase = .confirmation
        if !requireConfirmation { confirm(using: actions) }
    }

    func confirm(using actions: any AccountDeletionActions) {
        guard phase == .confirmation, let ceremony else { return }
        phase = .preparing
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.releaseOperation(for: ceremony) }
            do {
                try self.check(ceremony, using: actions)
                let needsPassword = try await actions.prepareAccountDeletion(session: ceremony.session)
                try self.check(ceremony, using: actions)
                if needsPassword {
                    self.phase = .password
                } else {
                    try await self.performDeletion(ceremony, using: actions)
                }
            } catch {
                self.handle(error, for: ceremony, using: actions)
            }
        }
    }

    func submit(password: String, using actions: any AccountDeletionActions) {
        guard phase == .password, !password.isEmpty, let ceremony else { return }
        passwordError = nil
        phase = .reauthenticating
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.releaseOperation(for: ceremony) }
            do {
                try self.check(ceremony, using: actions)
                try await actions.reauthenticateForAccountDeletion(password: password, session: ceremony.session)
                try self.check(ceremony, using: actions)
            } catch {
                if self.isActive(ceremony, using: actions), !(error is CancellationError) {
                    self.passwordError = error
                    self.phase = .password
                } else {
                    self.handle(error, for: ceremony, using: actions)
                }
                return
            }
            do {
                try await self.performDeletion(ceremony, using: actions)
            } catch {
                self.handle(error, for: ceremony, using: actions)
            }
        }
    }

    func dismissConfirmation() {
        if phase == .confirmation { cancel() }
    }

    func dismissPassword() {
        if isPresentingPassword { cancel() }
    }

    func dismissError() { deletionError = nil }

    func cancel() {
        ceremony = nil
        operation?.cancel()
        operation = nil
        phase = .idle
        passwordError = nil
        deletionError = nil
    }

    private func performDeletion(_ ceremony: Ceremony, using actions: any AccountDeletionActions) async throws {
        try check(ceremony, using: actions)
        phase = .deleting
        try await actions.deleteAccount(session: ceremony.session)
        // Successful deletion normally signs out. Retire only this operation;
        // never clear a newer ceremony started by another session.
        if self.ceremony?.id == ceremony.id {
            self.ceremony = nil
            phase = .idle
        }
    }

    private func isActive(_ ceremony: Ceremony, using actions: any AccountDeletionActions) -> Bool {
        self.ceremony?.id == ceremony.id
            && actions.isCurrentSession(ceremony.session, allowingAccountDeletion: true)
            && !Task.isCancelled
    }

    private func check(_ ceremony: Ceremony, using actions: any AccountDeletionActions) throws {
        guard isActive(ceremony, using: actions) else { throw CancellationError() }
    }

    private func handle(_ error: Error, for ceremony: Ceremony, using actions: any AccountDeletionActions) {
        guard self.ceremony?.id == ceremony.id else { return }
        // Dismissing Apple's sheet is a choice, not a failure.
        let userCanceled = (error as? ASAuthorizationError)?.code == .canceled
        let shouldPresent = isActive(ceremony, using: actions) && !(error is CancellationError) && !userCanceled
        self.ceremony = nil
        phase = .idle
        passwordError = nil
        deletionError = shouldPresent ? error : nil
        // An old request's auth error must never sign out the current account.
        // The pending-deletion screen keeps explicit retry and sign-out actions.
    }

    private func releaseOperation(for ceremony: Ceremony) {
        if self.ceremony == nil || self.ceremony?.id == ceremony.id {
            operation = nil
        }
    }
}

extension AppState: AccountDeletionActions {}
