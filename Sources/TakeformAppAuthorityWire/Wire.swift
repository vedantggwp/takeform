import Darwin
import Foundation
import TakeformCore
import TakeformWorkspace

public enum AppAuthorityRequest: Codable, Sendable {
    case open(URL, Bool, Data)
    case create(URL, String, [String: String], Data)
    case execute(URL, CommandEnvelope, Data)
    case pair(URL, String, Date, Data)
    case revoke(URL, UUID, Data)
    case listGrants(URL, Data)
    case pairedExecute(URL, CommandEnvelope, UUID, String)
}
public enum AppAuthorityResponse: Codable, Sendable { case snapshot(WorkspaceSnapshot); case result(CommandResult); case pairing(UUID, String); case grants([CLIPairingSummary]); case success; case failure(WorkspaceFailure) }
public enum AppAuthoritySocketFailure: Error { case unverifiedPeer }
public final class AppAuthoritySocketListener: @unchecked Sendable {
    public let fileDescriptor: Int32
    private let path: String
    private let node: (dev_t, ino_t)
    private let lock = NSLock()
    private var isClosed = false

    fileprivate init(fileDescriptor: Int32, path: String, node: (dev_t, ino_t)) {
        self.fileDescriptor = fileDescriptor; self.path = path; self.node = node
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(fileDescriptor)
        var current = stat()
        if Darwin.lstat(path, &current) == 0, current.st_dev == node.0, current.st_ino == node.1 { _ = Darwin.unlink(path) }
    }

    deinit { close() }
}
public enum AppAuthoritySocket {
 nonisolated(unsafe) private static var testingPath: String?
 public static var path: String { testingPath ?? ProcessInfo.processInfo.environment["TAKEFORM_AUTHORITY_SOCKET"] ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!.appendingPathComponent("Takeform/app-authority.sock").path }
 @_spi(Testing) public static func setTestingPath(_ path: String?) { testingPath = path }
 static func address() -> sockaddr_un { var a=sockaddr_un(); a.sun_family=sa_family_t(AF_UNIX); let b=Array(path.utf8CString); withUnsafeMutableBytes(of:&a.sun_path){ r in for(i,x) in b.enumerated(){r[i]=UInt8(bitPattern:x)} }; a.sun_len=UInt8(MemoryLayout<sockaddr_un>.size); return a }
 public static func connect() throws -> Int32 { let fd=socket(AF_UNIX,SOCK_STREAM,0); guard fd >= 0 else {throw WorkspaceFailure.authorityUnavailable}; var a=address(); let rc=withUnsafePointer(to:&a){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}; guard rc==0 else {close(fd);throw WorkspaceFailure.authorityUnavailable}; return fd }
    public static func makeListener() throws -> AppAuthoritySocketListener { try FileManager.default.createDirectory(at:URL(fileURLWithPath:path).deletingLastPathComponent(),withIntermediateDirectories:true); let fd=socket(AF_UNIX,SOCK_STREAM,0); guard fd>=0 else{throw WorkspaceFailure.authorityUnavailable}; var a=address(); let rc=withUnsafePointer(to:&a){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}; guard rc==0 && Darwin.listen(fd,8)==0 else {close(fd);throw WorkspaceFailure.authorityUnavailable}; chmod(path,S_IRUSR|S_IWUSR); var info=stat(); guard Darwin.lstat(path,&info)==0 else {close(fd);throw WorkspaceFailure.authorityUnavailable}; return AppAuthoritySocketListener(fileDescriptor:fd,path:path,node:(info.st_dev,info.st_ino)) }
    public static func request(_ r:AppAuthorityRequest)throws->AppAuthorityResponse{let fd=try connect();defer{close(fd)};try send(r,fd);return try receive(AppAuthorityResponse.self,fd)}
    public static func verifiedRequest(_ request: AppAuthorityRequest, expectedService: URL) throws -> AppAuthorityResponse {
        let fd = try connect()
        defer { close(fd) }
        guard let requirement = AppAuthorityPeer.requirement(for: expectedService), AppAuthorityPeer.matches(fd: fd, requirement: requirement) else { throw AppAuthoritySocketFailure.unverifiedPeer }
        try send(request, fd)
        return try receive(AppAuthorityResponse.self, fd)
    }
 public static func send<T:Encodable>(_ x:T,_ fd:Int32)throws{var d=try JSONEncoder().encode(x);d.append(10);guard d.withUnsafeBytes({Darwin.write(fd,$0.baseAddress!,d.count)})==d.count else{throw WorkspaceFailure.authorityUnavailable}}
 public static func receive<T:Decodable>(_ t:T.Type,_ fd:Int32)throws->T{var d=Data();var b:UInt8=0;while d.count<1_000_000{guard Darwin.read(fd,&b,1)>0 else{throw WorkspaceFailure.authorityUnavailable};if b==10{return try JSONDecoder().decode(t,from:d)};d.append(b)};throw WorkspaceFailure.authorityUnavailable}
}

import Security
public enum AppAuthorityPeer {
 public static func requirement(for binary: URL) -> String? { var code:SecStaticCode?;guard SecStaticCodeCreateWithPath(binary as CFURL,[],&code)==errSecSuccess,let code else{return nil};var info:CFDictionary?;guard SecCodeCopySigningInformation(code,SecCSFlags(rawValue:UInt32(kSecCSSigningInformation)),&info)==errSecSuccess,let d=info as? [String:Any],let id=d[kSecCodeInfoIdentifier as String] as? String,let hash=d[kSecCodeInfoUnique as String] as? Data else{return nil};return "identifier \"\(id)\" and cdhash H\"\(hash.map{String(format:"%02x",$0)}.joined())\"" }
 public static func matches(fd:Int32, requirement:String)->Bool { var token=audit_token_t();var len=socklen_t(MemoryLayout<audit_token_t>.size);guard getsockopt(fd,SOL_LOCAL,LOCAL_PEERTOKEN,&token,&len)==0 else{return false};let attrs:[CFString:Any]=[kSecGuestAttributeAudit:withUnsafeBytes(of:&token){Data($0)}];var code:SecCode?;guard SecCodeCopyGuestWithAttributes(nil,attrs as CFDictionary,[],&code)==errSecSuccess,let code else{return false};var req:SecRequirement?;guard SecRequirementCreateWithString(requirement as CFString,[],&req)==errSecSuccess,let req else{return false};return SecCodeCheckValidity(code,[],req)==errSecSuccess }
}
