// islandctl — send a command to the running Island app: toggle | dump
// Build: swiftc -O scripts/islandctl.swift -o ~/Library/Caches/island-build/islandctl
import Foundation

let cmd = CommandLine.arguments.dropFirst().first ?? "dump"
guard ["toggle", "dump"].contains(cmd) else {
    FileHandle.standardError.write("usage: islandctl toggle|dump\n".data(using: .utf8)!)
    exit(2)
}
DistributedNotificationCenter.default().postNotificationName(
    .init("local.claude-kit.island.\(cmd)"), object: nil, userInfo: nil, deliverImmediately: true)
RunLoop.current.run(until: Date().addingTimeInterval(0.3))
