import Foundation
import Darwin

/// Follows the Host named by the plugin's runtime file, including helpers that
/// were replaced outside the desktop shell. HTTP failures are not exit signals.
@MainActor
final class HostLifetimeMonitor {
  struct Owner: Decodable, Equatable, Sendable {
    let pid: Int32
    let writtenAt: Double?
  }
  enum Liveness: Sendable { case alive, dead, unknown }

  private let runtimeURL: URL
  private let grace: TimeInterval
  private let interval: TimeInterval
  private let probe: (Int32) -> Liveness
  private let onExit: () -> Void
  private var timer: Timer?
  private var processSource: DispatchSourceProcess?
  private var owner: Owner?
  private var exitedOwner: Owner?
  private var deadSince: TimeInterval?
  private var finished = false

  init(runtimeURL: URL, grace: TimeInterval = 0, interval: TimeInterval = 1,
       probe: @escaping (Int32) -> Liveness = HostLifetimeMonitor.liveness,
       onExit: @escaping () -> Void) {
    self.runtimeURL = runtimeURL
    self.grace = grace
    self.interval = interval
    self.probe = probe
    self.onExit = onExit
  }

  nonisolated static func liveness(_ pid: Int32) -> Liveness {
    guard pid > 1 else { return .unknown }
    if kill(pid, 0) == 0 { return .alive }
    return errno == ESRCH ? .dead : .unknown
  }

  func start() {
    guard timer == nil, !finished else { return }
    timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.check() }
    }
    check()
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    processSource?.cancel()
    processSource = nil
  }

  private func check() {
    guard !finished else { return }
    if let data = try? Data(contentsOf: runtimeURL),
       let current = try? JSONDecoder().decode(Owner.self, from: data),
       current.pid > 1, current != owner {
      processSource?.cancel()
      processSource = nil
      owner = current
      exitedOwner = nil
      deadSince = nil
      if probe(current.pid) == .alive {
        let source = DispatchSource.makeProcessSource(identifier: current.pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
          Task { @MainActor in
            guard let self, self.owner == current else { return }
            self.exitedOwner = current
            self.check()
          }
        }
        processSource = source
        source.resume()
      }
    }
    // Older runtimes and offline demos may not declare an owner. Keep working.
    guard let owner else { return }
    let state = exitedOwner == owner ? Liveness.dead : probe(owner.pid)
    guard state == .dead else { deadSince = nil; return }
    let now = ProcessInfo.processInfo.systemUptime
    if deadSince == nil { deadSince = now }
    guard now - (deadSince ?? now) >= grace else { return }
    finished = true
    stop()
    // Never include the runtime file's authentication fields in diagnostics.
    FileHandle.standardError.write(Data("[dsh-notch] Host \(owner.pid) exited; closing helper\n".utf8))
    onExit()
  }
}
