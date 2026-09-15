import Foundation
import Security
import TakeformAuthorityEngine
import TakeformAppAuthorityWire
import TakeformCore
import TakeformWorkspace

/// Exists only in the app-service target. The shipping CLI has no dependency on this target or the engine.
public enum CreatorAuthorityService {
    public enum PeerRole: Sendable { case app, cli }

    public static func allows(_ request: AppAuthorityRequest, for role: PeerRole) -> Bool {
        switch (role, request) {
        case (.app, .open), (.app, .execute), (.app, .pair), (.app, .revoke), (.app, .listGrants), (.cli, .pairedExecute): true
        default: false
        }
    }

    public static func respond(to request: AppAuthorityRequest, from role: PeerRole) -> AppAuthorityResponse {
        guard allows(request, for: role) else { return .failure(.creatorAuthorizationRequired) }
        do { return try handle(request) }
        catch { return .failure(workspaceFailure(error)) }
    }

    private static func token() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AuthorityFailure.unauthorized }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func handle(_ request: AppAuthorityRequest) throws -> AppAuthorityResponse {
        switch request {
        case let .open(url, rebind, credential):
            let authority = try ProjectAuthority(packageURL: url)
            let opened = try authority.openForAuthenticatedCreator(credential: String(decoding: credential, as: UTF8.self), rebindMovedPackage: rebind)
            return .snapshot(WorkspaceSnapshot(document: opened.document, projectionMatches: opened.projectionMatches, packageURL: url))
        case let .execute(url, envelope, credential):
            let authority = try ProjectAuthority(packageURL: url)
            return .result(try authority.executeForAuthenticatedCreator(envelope, credential: String(decoding: credential, as: UTF8.self)))
        case let .pair(url, label, expires, credential):
            let authority = try ProjectAuthority(packageURL: url)
            let raw = try token()
            let grant = try authority.issuePairedCLIGrant(credential: String(decoding: credential, as: UTF8.self), label: label, scopes: [.editProject], expiresAt: expires, rawToken: raw)
            return .pairing(grant.id, raw)
        case let .revoke(url, grantID, credential):
            let authority = try ProjectAuthority(packageURL: url)
            try authority.revokePairedCLIGrant(credential: String(decoding: credential, as: UTF8.self), grantID: grantID)
            return .success
        case let .listGrants(url, credential):
            let authority = try ProjectAuthority(packageURL: url)
            return .grants(try authority.pairedCLIGrants(credential: String(decoding: credential, as: UTF8.self)))
        case let .pairedExecute(url, envelope, grantID, token):
            let authority = try ProjectAuthority(packageURL: url)
            return .result(try authority.execute(envelope, grantID: grantID, token: token))
        }
    }

    public static func workspaceFailure(_ error: Error) -> WorkspaceFailure {
        guard let error = error as? AuthorityFailure else { return .authorityUnavailable }
        switch error {
        case .copyDecisionRequired: return .copyDecisionRequired
        case .corruptDatabase: return .corruptProject
        case .newerSchema(let schema): return .newerSchema(schema)
        case .missingObject(let object): return .missingObject(object)
        default: return .rejected(error.localizedDescription)
        }
    }
}
