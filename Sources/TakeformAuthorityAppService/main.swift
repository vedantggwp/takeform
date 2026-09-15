import Darwin
import Foundation
import Security
@_spi(AuthorityAppService) import TakeformAuthority
import TakeformAppAuthorityWire
import TakeformCore
import TakeformWorkspace

func token() -> String { var bytes=[UInt8](repeating:0,count:32); _ = SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes); return bytes.map{String(format:"%02x",$0)}.joined() }
func appRequirement() -> String? {
 let me=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath(); let app=me.deletingLastPathComponent().appendingPathComponent("Takeform")
 var code:SecStaticCode?; guard SecStaticCodeCreateWithPath(app as CFURL,[],&code)==errSecSuccess,let code else{return nil}; var info:CFDictionary?; guard SecCodeCopySigningInformation(code,SecCSFlags(rawValue:UInt32(kSecCSSigningInformation)),&info)==errSecSuccess,let dict=info as? [String:Any],let id=dict[kSecCodeInfoIdentifier as String] as? String,let hash=dict[kSecCodeInfoUnique as String] as? Data else{return nil}; return "identifier \"\(id)\" and cdhash H\"\(hash.map{String(format:"%02x",$0)}.joined())\""
}
func authenticated(_ fd:Int32,_ requirement:String?)->Bool {
 guard let requirement else{return false}; var token=audit_token_t();var length=socklen_t(MemoryLayout<audit_token_t>.size);guard getsockopt(fd,SOL_LOCAL,LOCAL_PEERTOKEN,&token,&length)==0 else{return false}; let attrs:[CFString:Any]=[kSecGuestAttributeAudit:withUnsafeBytes(of:&token){Data($0)}];var code:SecCode?;guard SecCodeCopyGuestWithAttributes(nil,attrs as CFDictionary,[],&code)==errSecSuccess,let code else{return false};var req:SecRequirement?;guard SecRequirementCreateWithString(requirement as CFString,[],&req)==errSecSuccess,let req else{return false};return SecCodeCheckValidity(code,[],req)==errSecSuccess
}
func map(_ error:Error)->WorkspaceFailure { if let e=error as? AuthorityFailure { switch e {case .copyDecisionRequired:return .copyDecisionRequired;case .corruptDatabase:return .corruptProject;case .newerSchema(let x):return .newerSchema(x);case .missingObject(let x):return .missingObject(x);default:return .rejected(e.localizedDescription)} }; return .authorityUnavailable }
let requirement=appRequirement(); let listen=try AppAuthoritySocket.listen()
while true { let fd=accept(listen,nil,nil);guard fd>=0 else{continue}; Thread { defer{close(fd)}; guard authenticated(fd,requirement) else {try? AppAuthoritySocket.send(AppAuthorityResponse.failure(.creatorAuthorizationRequired),fd);return}; do { let request=try AppAuthoritySocket.receive(AppAuthorityRequest.self,fd); let response:AppAuthorityResponse
 switch request {
 case let .open(url,rebind,credential): let authority=try ProjectAuthority(packageURL:url); let open=try authority.open(rebindMovedPackage:rebind); let session=AuthorityAppServiceGate.session(creatorCredential:String(decoding:credential,as:UTF8.self)); try authority.establishCreator(session); response = .snapshot(WorkspaceSnapshot(document:open.document,projectionMatches:open.projectionMatches,packageURL:url))
 case let .execute(url,envelope,credential): let authority=try ProjectAuthority(packageURL:url); let session=AuthorityAppServiceGate.session(creatorCredential:String(decoding:credential,as:UTF8.self)); try authority.establishCreator(session); let raw = token(); let grant=try authority.issueCLIGrant(session,label:"native session",scopes:[.editProject],expiresAt:Date(timeIntervalSinceNow:30),rawToken:raw); response = .result(try authority.execute(envelope,grantID:grant.id,token:raw))
 case let .pair(url,label,expires,credential): let authority=try ProjectAuthority(packageURL:url); let session=AuthorityAppServiceGate.session(creatorCredential:String(decoding:credential,as:UTF8.self)); try authority.establishCreator(session); let raw=token();let grant=try authority.issueCLIGrant(session,label:label,scopes:[.editProject],expiresAt:expires,rawToken:raw);response = .pairing(grant.id,raw)
 case let .revoke(url,id,credential): let authority=try ProjectAuthority(packageURL:url);let session=AuthorityAppServiceGate.session(creatorCredential:String(decoding:credential,as:UTF8.self));try authority.revokeCLIGrant(session,grantID:id);response = .success }
 try AppAuthoritySocket.send(response,fd)
 } catch { try? AppAuthoritySocket.send(AppAuthorityResponse.failure(map(error)),fd) } }.start() }
