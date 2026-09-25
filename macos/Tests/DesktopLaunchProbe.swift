@main enum DesktopLaunchProbe {
  @MainActor static func main() {
    let runtime = FileManager.default.temporaryDirectory.appendingPathComponent("notch-desktop-probe-\(getpid()).json")
    // No live Host, credentials, or model calls. Only exercise native startup.
    try! JSONSerialization.data(withJSONObject: ["origin":"http://127.0.0.1:1", "token":"offline-test", "pid":getpid()]).write(to:runtime)
    setenv("DSH_NOTCH_RUNTIME_FILE", runtime.path, 1)
    UserDefaults.standard.setVolatileDomain(["elastic-edge-hidden-v1":false], forName:UserDefaults.argumentDomain)
    let app=NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate=AppDelegate()
    app.delegate=delegate
    Task { @MainActor in
      try? await Task.sleep(for:.milliseconds(400))
      defer { try? FileManager.default.removeItem(at:runtime) }
      guard let panel=app.windows.first(where: { $0 is NotchPanel }), let screen=panel.screen else {
        print("FAIL missing native panel/screen"); exit(1)
      }
      let expected=Double(ProcessInfo.processInfo.environment["NOTCH_EXPECT_EDGE_GAP"] ?? "0") ?? 0
      let gap=screen.frame.maxX-panel.frame.maxX
      print("CUSTOM_RUNTIME_SCREEN_GAP=\(gap) EXPECTED=\(expected)")
      let passed=abs(gap-expected)<0.01
      delegate.applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification))
      panel.close()
      print("FAILURES=\(passed ? 0:1)")
      exit(passed ? 0:1)
    }
    app.run()
  }
}
