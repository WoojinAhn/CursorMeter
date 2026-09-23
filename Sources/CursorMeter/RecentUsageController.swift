import CoreFoundation
import Foundation
import Observation

@MainActor
struct RecentUsageValidityPersistence {
    let read: () -> String?
    let commit: (String) -> Bool

    static func preferences(domain: String, key: String = "recentUsageValidityToken") -> Self {
        Self(read: {
            CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? String
        }, commit: { token in
            CFPreferencesSetAppValue(key as CFString, token as CFString, domain as CFString)
            return CFPreferencesAppSynchronize(domain as CFString)
        })
    }
}

enum RecentUsageStatus: Equatable, Sendable {
    case idle
    case cached
    case current
    case failed
}

@MainActor @Observable
final class RecentUsageController {
    struct Context: Equatable, Sendable {
        fileprivate let generation: UInt64
        fileprivate let attemptID: UInt64
        fileprivate let selectionRevision: UInt64
        fileprivate let credentialDigest: String
    }

    private struct DiskOperation {
        enum Mutation {
            case save(RecentUsageSnapshot, token: String, context: Context, publicationRevision: UInt64)
            case remove
        }
        let id: UInt64
        let mutation: Mutation
    }

    private(set) var snapshot: RecentUsageSnapshot?
    private(set) var status: RecentUsageStatus = .idle

    @ObservationIgnored private let store: RecentUsageStore?
    @ObservationIgnored private let validityPersistence: RecentUsageValidityPersistence?
    private static var disabledCacheFiles: Set<URL> = []

    private var diskEnabled: Bool {
        guard let store, validityPersistence != nil else { return false }
        return !Self.disabledCacheFiles.contains(store.cacheIdentity)
    }
    @ObservationIgnored private var validityToken: String?
    @ObservationIgnored private var mayHavePersistedSnapshot = true
    @ObservationIgnored private var knownPersistedCredentialDigest: String?
    @ObservationIgnored private var heldSnapshot: RecentUsageSnapshot?
    @ObservationIgnored private var eligibleCredentialDigest: String?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var greatestAttemptID: UInt64?
    @ObservationIgnored private var selectionRevision: UInt64 = 0
    @ObservationIgnored private var restoreRevision: UInt64 = 0
    @ObservationIgnored private var publicationRevision: UInt64 = 0
    @ObservationIgnored private var context: Context?
    @ObservationIgnored private var subjectDigest: String?
    @ObservationIgnored private var scopeDigest: String?
    @ObservationIgnored private var publishedContext: Context?
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    @ObservationIgnored private var diskOperationID: UInt64 = 0
    @ObservationIgnored private var pendingDiskOperation: DiskOperation?
    @ObservationIgnored private var diskTask: Task<Void, Never>?

    init(store: RecentUsageStore? = nil, validityPersistence: RecentUsageValidityPersistence? = nil) {
        self.store = store
        self.validityPersistence = validityPersistence
    }

    /// Reconnects require a newly selected outbound credential, but do not revoke the saved account.
    func beginSession(generation: UInt64) {
        invalidate(generation: generation, revokePersisted: false)
    }

    /// Call immediately before the credential's request attempt; disk restore never delays that request.
    @discardableResult
    func selectCredential(cookieHeader: String, generation: UInt64, attemptID: UInt64) -> Context? {
        guard generation == self.generation, greatestAttemptID.map({ attemptID >= $0 }) != false else { return nil }
        greatestAttemptID = attemptID
        selectionRevision += 1
        retireRestore()
        context = nil
        subjectDigest = nil
        scopeDigest = nil
        publishedContext = nil
        guard let credential = RecentUsageBinding.credentialDigest(cookieHeader: cookieHeader) else {
            clearCache()
            revokePersistence()
            status = .failed
            return nil
        }
        let selected = Context(generation: generation, attemptID: attemptID,
                               selectionRevision: selectionRevision, credentialDigest: credential)
        context = selected
        if let snapshot, eligibleCredentialDigest != credential {
            heldSnapshot = snapshot
            self.snapshot = nil
            publicationRevision += 1
            eligibleCredentialDigest = nil
            status = .idle
        }
        authorizeHeldSnapshot()
        guard snapshot == nil, heldSnapshot == nil, let store, let token = ensureValidityToken() else { return selected }
        let revision = restoreRevision
        let publication = publicationRevision
        let diskRevision = diskOperationID
        restoreTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let restored = await store.load(validityToken: token)
            guard let self, !Task.isCancelled, self.matches(selected),
                  self.restoreRevision == revision, self.publicationRevision == publication,
                  self.diskEnabled, self.validityToken == token, let restored else { return }
            if self.diskOperationID == diskRevision, self.diskTask == nil {
                self.knownPersistedCredentialDigest = restored.binding.credentialDigest
            }
            self.heldSnapshot = restored
            self.authorizeHeldSnapshot()
        }
        return selected
    }

    /// Subject must come from the authenticated /api/auth/me response; nil scope means unresolved.
    @discardableResult
    func validateIdentity(subject: String?, scope: RecentUsageRequestScope?, context: Context) -> Bool {
        guard matches(context) else { return false }
        let subject = RecentUsageBinding.subjectDigest(subject)
        let scope = scope?.digest
        let previous = snapshot ?? heldSnapshot
        if let previous, identityConflicts(with: previous.binding, subject: subject, scope: scope) {
            clearCache()
            retireRestore()
            revokePersistence()
        }
        subjectDigest = subject
        scopeDigest = scope
        authorizeHeldSnapshot()
        return true
    }

    @discardableResult
    func publish(candidate: RecentUsageCandidate, context: Context) -> Bool {
        guard matches(context), let scopeDigest else { return false }
        let binding = RecentUsageBinding(credentialDigest: context.credentialDigest,
                                         subjectDigest: subjectDigest, scopeDigest: scopeDigest)
        let next = RecentUsageSnapshot(candidate: candidate, binding: binding)
        guard next.isValid else { return false }
        retireRestore()
        snapshot = next
        heldSnapshot = nil
        eligibleCredentialDigest = context.credentialDigest
        publicationRevision += 1
        publishedContext = context
        status = .current
        if let token = ensureValidityToken() {
            enqueue(.save(next, token: token, context: context, publicationRevision: publicationRevision))
        }
        return true
    }

    /// A successful recent result is final for this attempt, regardless of another consumer's failure.
    func recordFailure(context: Context) {
        guard matches(context), publishedContext != context else { return }
        status = .failed
    }

    func rejectCredential(context: Context) {
        guard matches(context) else { return }
        if let held = heldSnapshot, held.binding.credentialDigest != context.credentialDigest {
            let preserveDisk = knownPersistedCredentialDigest == held.binding.credentialDigest
            invalidate(generation: generation, revokePersisted: !preserveDisk)
            heldSnapshot = held
            return
        }
        invalidate(generation: generation, revokePersisted: true)
    }

    func invalidate(generation: UInt64, revokePersisted: Bool) {
        guard generation >= self.generation else { return }
        if generation != self.generation { greatestAttemptID = nil }
        self.generation = generation
        selectionRevision += 1
        context = nil
        retireRestore()
        clearCache()
        if revokePersisted { revokePersistence() }
    }

    func testHook_waitForPersistence() async {
        await diskTask?.value
    }

    private func matches(_ context: Context) -> Bool {
        self.context == context && context.generation == generation
    }

    private func retireRestore() {
        restoreRevision += 1
        restoreTask?.cancel()
        restoreTask = nil
    }

    private func clearCache() {
        snapshot = nil
        heldSnapshot = nil
        eligibleCredentialDigest = nil
        subjectDigest = nil
        scopeDigest = nil
        publishedContext = nil
        publicationRevision += 1
        status = .idle
    }

    private func identityConflicts(with binding: RecentUsageBinding, subject: String?, scope: String?) -> Bool {
        if let scope, scope != binding.scopeDigest { return true }
        if let subject, let savedSubject = binding.subjectDigest, subject != savedSubject { return true }
        return false
    }

    private func authorizeHeldSnapshot() {
        guard let held = heldSnapshot, let context else { return }
        if identityConflicts(with: held.binding, subject: subjectDigest, scope: scopeDigest) {
            // The authenticated identity may resolve before the old file finishes loading.
            let subject = subjectDigest
            let scope = scopeDigest
            clearCache()
            retireRestore()
            revokePersistence()
            subjectDigest = subject
            scopeDigest = scope
            return
        }
        let exactCredential = held.binding.credentialDigest == context.credentialDigest
        let matchingIdentity = subjectDigest != nil && subjectDigest == held.binding.subjectDigest
            && scopeDigest != nil && scopeDigest == held.binding.scopeDigest
        guard exactCredential || matchingIdentity else { return }
        snapshot = held
        heldSnapshot = nil
        eligibleCredentialDigest = context.credentialDigest
        publicationRevision += 1
        if status != .failed { status = .cached }
    }

    private func ensureValidityToken() -> String? {
        guard diskEnabled, store != nil, let validityPersistence else { return nil }
        if let validityToken { return validityToken }
        if let saved = validityPersistence.read(), UUID(uuidString: saved) != nil {
            validityToken = saved
            return saved
        }
        let token = UUID().uuidString
        guard validityPersistence.commit(token) else {
            disablePersistence()
            return nil
        }
        validityToken = token
        return token
    }

    private func revokePersistence() {
        knownPersistedCredentialDigest = nil
        guard store != nil, mayHavePersistedSnapshot else { return }
        if diskEnabled, let validityPersistence {
            let token = UUID().uuidString
            // Confirm durable revocation before returning from the authentication boundary.
            guard validityPersistence.commit(token) else {
                disablePersistence()
                return
            }
            validityToken = token
            mayHavePersistedSnapshot = false
        }
        enqueue(.remove)
    }

    private func disablePersistence() {
        if let store { Self.disabledCacheFiles.insert(store.cacheIdentity) }
        validityToken = nil
        knownPersistedCredentialDigest = nil
        retireRestore()
        Log.error("Recent usage cache validity could not be persisted; disk cache disabled")
        enqueue(.remove)
    }

    private func enqueue(_ mutation: DiskOperation.Mutation) {
        guard store != nil else { return }
        knownPersistedCredentialDigest = nil
        if case .save = mutation { mayHavePersistedSnapshot = true }
        diskOperationID += 1
        // Keep one active operation and at most one pending replacement.
        pendingDiskOperation = DiskOperation(id: diskOperationID, mutation: mutation)
        guard diskTask == nil else { return }
        diskTask = Task { [weak self] in
            guard let self, let store = self.store else { return }
            while let operation = self.pendingDiskOperation {
                self.pendingDiskOperation = nil
                switch operation.mutation {
                case let .save(snapshot, token, context, publication):
                    guard self.diskEnabled, self.validityToken == token, self.matches(context),
                          self.publicationRevision == publication else { continue }
                    self.knownPersistedCredentialDigest = nil
                    if (try? await store.save(snapshot, validityToken: token, operation: operation.id)) != nil,
                       self.diskEnabled, self.validityToken == token, self.diskOperationID == operation.id {
                        self.knownPersistedCredentialDigest = snapshot.binding.credentialDigest
                    }
                case .remove:
                    try? await store.remove(operation: operation.id)
                }
            }
            self.diskTask = nil
        }
    }
}
