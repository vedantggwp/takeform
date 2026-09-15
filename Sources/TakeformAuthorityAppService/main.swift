import Darwin
import Foundation
import TakeformAuthorityAppServiceCore
import TakeformAppAuthorityWire
import TakeformCore
import TakeformWorkspace

func bundledPeer(_ name: String) -> String? {
    let service = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    return AppAuthorityPeer.requirement(for: service.deletingLastPathComponent().appendingPathComponent(name))
}

let appRequirement = bundledPeer("Takeform")
let cliRequirement = bundledPeer("takeform")
let listen = try AppAuthoritySocket.listen()

while true {
    let fd = accept(listen, nil, nil)
    guard fd >= 0 else { continue }
    Thread {
        defer { close(fd) }
        let role: CreatorAuthorityService.PeerRole?
        if let appRequirement, AppAuthorityPeer.matches(fd: fd, requirement: appRequirement) { role = .app }
        else if let cliRequirement, AppAuthorityPeer.matches(fd: fd, requirement: cliRequirement) { role = .cli }
        else { role = nil }
        guard let role else { return }
        do {
            let request = try AppAuthoritySocket.receive(AppAuthorityRequest.self, fd)
            if CreatorAuthorityService.allows(request, for: role) {
                try AppAuthoritySocket.send(try CreatorAuthorityService.handle(request), fd)
            } else {
                try AppAuthoritySocket.send(AppAuthorityResponse.failure(.creatorAuthorizationRequired), fd)
            }
        } catch {
            try? AppAuthoritySocket.send(AppAuthorityResponse.failure(CreatorAuthorityService.workspaceFailure(error)), fd)
        }
    }.start()
}
