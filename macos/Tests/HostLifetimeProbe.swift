import Foundation

@main enum HostLifetimeProbe {
  @MainActor static func main() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let runtime = folder.appendingPathComponent("runtime.json")
    func child() throws -> Process {
      let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sleep"); p.arguments = ["30"]
      try p.run(); return p
    }
    func write(_ p: Process, generation: Int = 1) throws {
      try Data("{\"pid\":\(p.processIdentifier),\"writtenAt\":\(generation)}".utf8).write(to: runtime, options: .atomic)
    }
    func pause(_ seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)) }
    var exits = 0
    func monitor(probe: @escaping (Int32) -> HostLifetimeMonitor.Liveness = HostLifetimeMonitor.liveness) -> HostLifetimeMonitor {
      HostLifetimeMonitor(runtimeURL: runtime, grace: 0.3, interval: 0.05, probe: probe) { exits += 1 }
    }

    let first = try child()
    defer { if first.isRunning { first.terminate() } }
    try write(first)
    let m = monitor(); m.start()
    try await pause(0.5)
    precondition(exits == 0, "live owner must stay")
    // A briefly unreadable file (or failed HTTP request) is not a Host exit.
    try Data("{".utf8).write(to: runtime)
    try await pause(0.4)
    precondition(exits == 0, "partial runtime must preserve last owner")
    first.terminate(); first.waitUntilExit()
    try await pause(0.7)
    precondition(exits == 1, "detached helper must close after owner exits")
    try await pause(0.2)
    precondition(exits == 1, "exit callback must be once only")
    print("PASS live owner, unreadable runtime, owner exit, once-only termination")

    let second = try child(), replacement = try child()
    defer { if second.isRunning { second.terminate() }; if replacement.isRunning { replacement.terminate() } }
    try write(second)
    let rebound = monitor(); rebound.start()
    second.terminate(); second.waitUntilExit()
    try write(replacement, generation: 2)
    try await pause(0.65)
    precondition(exits == 1, "replacement within grace must stay")
    replacement.terminate(); replacement.waitUntilExit()
    try await pause(0.65)
    precondition(exits == 2, "must follow replacement lifetime")
    print("PASS Host replacement and replacement exit")

    let stale = monitor(); stale.start()
    try await pause(0.6)
    precondition(exits == 3, "stale dead PID at launch must close")
    let unknown = monitor(probe: { _ in .unknown }); unknown.start()
    try await pause(0.6)
    precondition(exits == 3, "permission denial must not prove death")
    unknown.stop()
    try Data("{\"origin\":\"http://localhost\"}".utf8).write(to: runtime)
    let legacy = monitor(); legacy.start()
    try await pause(0.6)
    precondition(exits == 3, "legacy/demo runtime without owner must stay")
    legacy.stop()
    print("PASS stale PID, unknown liveness, legacy runtime; 9 lifecycle checks")
  }
}
