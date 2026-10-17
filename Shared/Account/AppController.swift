import Foundation
import Observation
import SwiftData
import Supabase
import Network

nonisolated enum CloudConfiguration {
    struct Settings: Sendable {
        let url: URL
        let publishableKey: String
    }
    static let current = read(Bundle.main.infoDictionary ?? [:])
    static func read(_ info: [String: Any]) -> Settings? {
        guard let rawURL = info["SupabaseURL"] as? String,
              let rawKey = info["SupabasePublishableKey"] as? String else { return nil }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty, host != "your-project.supabase.co",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)),
              key.hasPrefix("sb_publishable_"), key.count > "sb_publishable_".count else { return nil }
        return Settings(url: url, publishableKey: key)
    }
}

@MainActor @Observable final class AppController {
    static let redirectURL = URL(string: "ericktracker://auth/callback")!
    let client: SupabaseClient?
    var isCloudConfigured: Bool { client != nil }
    var persistence: PersistenceController
    var sync: SyncEngine?
    var sessions: SessionStore?
    var userID: UUID?
    var email: String?
    var isRestoring = true
    var isBusy = false
    var recoveryMode = false
    var requestedSessionID: UUID?
    var authError: String?
    var authMessage: String?
    var legacyImportCount = 0
    var sceneActive = true
    @ObservationIgnored var onLocalSave: (() -> Void)?
    @ObservationIgnored var onSignOut: (() -> Void)?
    @ObservationIgnored private var legacy: PersistenceController?
    @ObservationIgnored private var authTask: Task<Void, Never>?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        client = CloudConfiguration.current.map { configuration in
            SupabaseClient(supabaseURL: configuration.url, supabaseKey: configuration.publishableKey,
                options: .init(auth: .init(storage: KeychainLocalStorage(service: "ErickTracker.Auth"),
                    redirectToURL: Self.redirectURL, emitLocalSessionAsInitialSession: true)))
        }
        #if DEBUG
        if let id = UITestBootstrap.storeID {
            persistence = UITestBootstrap.makePersistence(id: id)
            userID = id; email = "testes@example.invalid"; isRestoring = false
            sessions = persistence.store.map(SessionStore.init)
            persistence.store?.onSave = { [weak self] in self?.onLocalSave?() }
            return
        }
        #endif
        if UserDefaults.standard.string(forKey: "legacyClaimedBy") == nil {
            let local = PersistenceController(); persistence = local; legacy = local
            if let c = local.container { legacyImportCount = (try? Snapshots.all(in: c.mainContext).count) ?? 0 }
        } else {
            persistence = PersistenceController(url: Self.guestURL)
        }
        sessions = persistence.store.map(SessionStore.init)
        guard let client else {
            isRestoring = false
            persistence.store?.onSave = { [weak self] in self?.onLocalSave?() }
            return
        }
        authTask = Task { [weak self, client] in
            for await (event, session) in client.auth.authStateChanges {
                guard let self else { return }
                if event == .passwordRecovery { self.recoveryMode = true }
                if self.userID != session?.user.id || self.isRestoring {
                    self.openAccount(session?.user.id, email: session?.user.email)
                } else { self.email = session?.user.email }
                self.isRestoring = false
            }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied {
                Task { @MainActor [weak self] in if self?.sceneActive == true { self?.sync?.schedule() } }
            }
        }
        monitor.start(queue: DispatchQueue(label: "ErickTracker.Network"))
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                if let self, self.sceneActive { await self.sync?.sync() }
            }
        }
    }
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "ErickTracker", directoryHint: .isDirectory)
    }
    static var guestURL: URL { directory.appending(path: "Guest.store") }
    static func accountURL(_ id: UUID) -> URL { directory.appending(path: "Accounts/\(id.uuidString.lowercased()).store") }
    private func openAccount(_ id: UUID?, email: String?) {
        sync?.stop(); onSignOut?(); self.userID = id; self.email = email
        if let id { persistence = PersistenceController(url: Self.accountURL(id)) }
        else if UserDefaults.standard.string(forKey: "legacyClaimedBy") == nil, let legacy { persistence = legacy }
        else { persistence = PersistenceController(url: Self.guestURL) }
        sessions = persistence.store.map(SessionStore.init)
        if let store = persistence.store, let id, let client, let configuration = CloudConfiguration.current {
            let engine = SyncEngine(store: store, transport: SupabaseTransport(client: client, ownerID: id, configuration: configuration))
            sync = engine
            store.onSave = { [weak self, weak engine] in engine?.schedule(); self?.onLocalSave?() }
            engine.schedule()
        } else {
            sync = nil
            persistence.store?.onSave = { [weak self] in self?.onLocalSave?() }
        }
        onLocalSave?()
    }
    func setActive(_ active: Bool) { sceneActive = active; if active { sync?.schedule(); onLocalSave?() } }
    func signIn(email: String, password: String, create: Bool) async {
        guard let client else { authError = AccountFailure.notConfigured.localizedDescription; return }
        guard !isBusy else { return }; isBusy = true; authError = nil; authMessage = nil; defer { isBusy = false }
        do {
            if create {
                _ = try await client.auth.signUp(email: WorkoutRules.trimmed(email), password: password, redirectTo: Self.redirectURL)
                authMessage = "Confira seu email para confirmar a conta. Depois entre nos dois aparelhos com a mesma conta."
            } else { _ = try await client.auth.signIn(email: WorkoutRules.trimmed(email), password: password) }
        } catch { authError = error.localizedDescription }
    }
    func resetPassword(email: String) async {
        guard let client else { authError = AccountFailure.notConfigured.localizedDescription; return }
        isBusy = true; authError = nil; defer { isBusy = false }
        do {
            try await client.auth.resetPasswordForEmail(WorkoutRules.trimmed(email), redirectTo: Self.redirectURL)
            authMessage = "Se o email estiver cadastrado, você receberá as instruções para recuperar a senha."
        } catch { authError = error.localizedDescription }
    }
    func updatePassword(_ password: String) async {
        guard let client else { authError = AccountFailure.notConfigured.localizedDescription; return }
        isBusy = true; authError = nil; defer { isBusy = false }
        do {
            _ = try await client.auth.update(user: UserAttributes(password: password))
            recoveryMode = false; authMessage = "Senha atualizada."
        } catch { authError = error.localizedDescription }
    }
    func handle(_ url: URL) async {
        guard let client else { return }
        guard url.scheme == "ericktracker", url.host == "auth" else { return }
        do { _ = try await client.auth.session(from: url) }
        catch { authError = error.localizedDescription }
    }
    func signOut() async {
        sync?.stop(); onSignOut?()
        // The SDK removes Keychain session data before attempting server revocation.
        do { try await client?.auth.signOut(scope: .local) }
        catch { authMessage = "Sessão encerrada neste aparelho. As alterações locais foram preservadas." }
        openAccount(nil, email: nil)
    }
    func claimLegacyData() {
        guard let userID, let source = legacy?.store, let target = persistence.store else { return }
        guard sync?.isSyncing != true else { authError = "Aguarde a sincronização terminar para vincular os dados locais."; return }
        sync?.stop()
        do {
            guard source.save() else { throw AccountFailure.saveFailed }
            let snapshots = try Snapshots.all(in: source.context)
            let existing = try Snapshots.all(in: target.context)
            for (kind, id, data) in snapshots {
                if let match = existing.first(where: { $0.0 == kind && $0.1 == id }), match.2 != data {
                    throw AccountFailure.collision
                }
            }
            for (kind, id, data) in snapshots { try Snapshots.apply(kind: kind, id: id, payload: data, in: target.context) }
            guard target.save() else { throw AccountFailure.saveFailed }
            let verified = try Snapshots.all(in: target.context)
            guard snapshots.allSatisfy({ source in verified.contains { $0.0 == source.0 && $0.1 == source.1 && $0.2 == source.2 } }) else {
                throw AccountFailure.saveFailed
            }
            UserDefaults.standard.set(userID.uuidString, forKey: "legacyClaimedBy")
            legacyImportCount = 0; legacy = nil
            authMessage = "Dados vinculados à conta, com os identificadores originais. A cópia local anterior foi preservada."
        } catch { target.context.rollback(); authError = error.localizedDescription }
        sync?.enabled = true; sync?.schedule()
    }
}

@MainActor final class SupabaseTransport: CloudTransport {
    nonisolated struct Identity: Sendable { var userID: UUID; var accessToken: String }
    private let database: PostgrestClient
    convenience init(client: SupabaseClient, ownerID: UUID, configuration: CloudConfiguration.Settings) {
        let auth = client.auth
        self.init(ownerID: ownerID, configuration: configuration, identity: {
            let session = try await auth.session
            return Identity(userID: session.user.id, accessToken: session.accessToken)
        })
    }
    init(ownerID: UUID, configuration: CloudConfiguration.Settings, identity: @escaping @Sendable () async throws -> Identity,
         fetch: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        // SupabaseClient's shared request adapter always injects its current user's
        // token. Bind this transport to one store owner so an in-flight request or
        // retry can never upload that store under a newly selected account.
        database = PostgrestClient(url: configuration.url.appending(path: "rest/v1"),
            headers: ["apikey": configuration.publishableKey], fetch: { request in
                let session = try await identity()
                guard session.userID == ownerID else { throw AccountFailure.accountChanged }
                var authorized = request
                authorized.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
                return try await fetch(authorized)
            }, retryEnabled: false)
    }
    nonisolated struct ApplyParams: Encodable, Sendable { var p_mutation: MutationRequest }
    nonisolated struct PullParams: Encodable, Sendable { var p_after: Int64; var p_limit: Int }
    func apply(_ request: MutationRequest) async throws -> MutationReply {
        try await database.rpc("tracker_apply_mutation", params: ApplyParams(p_mutation: request)).execute().value
    }
    func pull(after revision: Int64, limit: Int) async throws -> [RemoteChange] {
        try await database.rpc("tracker_pull_changes", params: PullParams(p_after: revision, p_limit: limit)).execute().value
    }
}
nonisolated enum AccountFailure: LocalizedError {
    case saveFailed, collision, accountChanged, notConfigured
    var errorDescription: String? {
        switch self {
        case .saveFailed: "Não foi possível verificar a gravação. A cópia anterior continua preservada."
        case .collision: "Há dados diferentes com o mesmo identificador nesta conta. A vinculação foi interrompida sem substituir seus registros."
        case .accountChanged: "A conta mudou durante a sincronização. As alterações continuam preservadas na conta de origem."
        case .notConfigured: "A sincronização não foi configurada nesta instalação. Seus dados locais continuam disponíveis."
        }
    }
}
