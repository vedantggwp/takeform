import Darwin
import Foundation
import TakeformAuthorityAppServiceCore
import TakeformAppAuthorityWire
import TakeformCore
import TakeformWorkspace

func bundledPeer(_ name: String) -> String? {
    let service = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let binary = service.deletingLastPathComponent().appendingPathComponent(name)
    return AppAuthorityPeer.requirement(for: binary)
}

let appRequirement = bundledPeer("TakeformApp")
let cliRequirement = bundledPeer("takeform")
let listener = try AppAuthoritySocket.makeListener()
signal(SIGTERM, SIG_IGN)
// Availability probes intentionally connect, verify the peer, and close before
// sending a request. A best-effort error reply to that closed socket must not
// terminate the app-session authority service.
signal(SIGPIPE, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler { listener.close(); exit(0) }
termination.resume()

Thread {
    while true {
        let fd = accept(listener.fileDescriptor, nil, nil)
        guard fd >= 0 else { return }
        Thread {
            defer { close(fd) }
            let role: CreatorAuthorityService.PeerRole?
            if let appRequirement, AppAuthorityPeer.matches(fd: fd, requirement: appRequirement) { role = .app }
            else if let cliRequirement, AppAuthorityPeer.matches(fd: fd, requirement: cliRequirement) { role = .cli }
            else { role = nil }
            guard let role else { return }
            do {
                let request = try AppAuthoritySocket.receive(AppAuthorityRequest.self, fd)
                try AppAuthoritySocket.send(CreatorAuthorityService.respond(to: request, from: role), fd)
            } catch {
                try? AppAuthoritySocket.send(AppAuthorityResponse.failure(CreatorAuthorityService.workspaceFailure(error)), fd)
            }
        }.start()
    }
}.start()
dispatchMain()
