import AppKit
import Combine
import SwiftUI

@main
enum DshNotchMain {
  static func main() {
    if CommandLine.arguments.contains("--verify-idle-resources") {
      let ids = IdleDirector.basics + ["dance"]
      let missing = ids.filter { IdleLibrary.shared.clip($0) == nil }
      print("IDLE_RESOURCES=\(ids.count - missing.count)/\(ids.count)")
      exit(missing.isEmpty ? 0 : 1)
    }
    let app = NSApplication.shared
    if CommandLine.arguments.contains("--elastic-preview") || Bundle.main.bundleIdentifier == "local.dsh.notch.elastic-preview" {
      app.setActivationPolicy(.regular)
      let delegate = ElasticPreviewDelegate()
      ElasticPreviewDelegate.hold = delegate
      app.delegate = delegate
      app.run()
      return
    }
    if CommandLine.arguments.contains("--demo") {
      app.setActivationPolicy(.regular)
      let delegate = DemoStudioDelegate()
      DemoStudioDelegate.hold = delegate
      app.delegate = delegate
      delegate.show()
      app.run()
      return
    }
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let panelW: CGFloat = 480
  private let restW: CGFloat = 32
  private let restH: CGFloat = 110
  private let topOffset: CGFloat = 100
  private let model = BoardModel()
  private let dock = EdgeDockModel()
  private var dockController: EdgeDockController?
  private var panel: NotchPanel?
  private var hosting: NotchHostingView<EdgeDockSurface<RootView>>?
  private var cursorTimer: Timer?
  private var hostLifetime: HostLifetimeMonitor?
  private var foldWork: DispatchWorkItem?
  private var enteredIsland = false
  private var cancellables = Set<AnyCancellable>()

  func applicationDidFinishLaunching(_ notification: Notification) {
    ProcessInfo.processInfo.disableAutomaticTermination("dsh-notch")
    ProcessInfo.processInfo.disableSuddenTermination()
    let panel = NotchPanel(size: NSSize(width: panelW, height: restH))
    let root = RootView(
      model: model,
      panelSize: CGSize(width: panelW, height: restH),
      restSize: CGSize(width: restW, height: restH)
    )
    let hosting = NotchHostingView(rootView: EdgeDockSurface(dock: dock, content: root))
    hosting.sizingOptions = []
    hosting.wantsLayer = true
    hosting.layer?.isOpaque = false
    hosting.layer?.backgroundColor = NSColor.clear.cgColor
    panel.embedHost(hosting)
    panel.ignoresMouseEvents = false
    self.panel = panel
    self.hosting = hosting
    pinToScreen()
    dockController = EdgeDockController(dock: dock, panel: panel, hosting: hosting)
    dockController?.onBegin = { [weak self] in
      self?.foldWork?.cancel(); self?.foldWork = nil
      self?.model.isPillHovered = false
    }
    dock.onHidden = { [weak self] hidden in
      self?.model.visuallyDocked = hidden
      UserDefaults.standard.set(hidden, forKey: "elastic-edge-hidden-v1")
    }
    dock.onSettled = { [weak self] hidden in if hidden { self?.model.expanded = false } }
    updateHits()
    if UserDefaults.standard.bool(forKey: "elastic-edge-hidden-v1") { dock.setHidden(true, animated: false) }
    panel.orderFrontRegardless()
    model.start()
    let runtimeURL = ProcessInfo.processInfo.environment["DSH_NOTCH_RUNTIME_FILE"].map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh/dsh-notch/runtime.json")
    hostLifetime = HostLifetimeMonitor(runtimeURL: runtimeURL) {
      NSApplication.shared.terminate(nil)
    }
    hostLifetime?.start()
    Publishers.CombineLatest3(model.$expanded, model.$currentIslandWidth, model.$currentIslandHeight)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.updateHits() }
      .store(in: &cancellables)
    cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.tickPointer()
      }
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(pinToScreen),
      name: NSApplication.didChangeScreenParametersNotification,
      object: nil
    )
  }

  func applicationWillTerminate(_ notification: Notification) {
    hostLifetime?.stop()
    cursorTimer?.invalidate()
    dock.stop()
  }

  @objc private func pinToScreen() {
    guard let panel else { return }
    panel.cancelResize()
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
      ?? NSScreen.main
      ?? NSScreen.screens.first
    guard let screen else { return }
    let visible = screen.visibleFrame
    let layout = NotchScreenLayout(availableHeight: visible.height, preferredInset: topOffset)
    model.maximumExpandedHeight = layout.maximumHeight
    // Anchor capsule to upper-right edge, ~100pt below top of usable screen.
    // Keep the test helper separate from the real Notch during walkthroughs.
    let demoInset: CGFloat = ProcessInfo.processInfo.environment["DSH_NOTCH_RUNTIME_FILE"] == nil ? 0 : 360
    let width = max(1, model.currentIslandWidth)
    let height = min(max(1, model.currentIslandHeight), model.maximumExpandedHeight)
    let frame = NSRect(
      x: visible.maxX - demoInset - width,
      y: visible.maxY - layout.edgeInset - height,
      width: width,
      height: height
    )
    panel.setFrame(frame, display: true)
    dockController?.resetAnchor()
    if dock.hidden { dock.setHidden(true, animated: false) }
  }

  private func pointerOverVisual() -> Bool {
    guard let panel else { return false }
    return panel.frame.contains(NSEvent.mouseLocation)
  }

  private func tickPointer() {
    guard panel != nil else { return }
    let hit = pointerOverVisual()
    dock.hover(hit)
    guard !dock.engaged else { return }
    if hit {
      enteredIsland = true
      foldWork?.cancel()
      foldWork = nil
      model.foldEnabled = true
      // Expand when hovering if there are items needing action or if user triggered expansion.
      if !model.expanded && (model.needsAction || model.allowExpandOnHover) {
        model.expanded = true
        updateHits()
      }
      return
    }
    // A guided local walkthrough stays visible until its test answer is sent.
    if ProcessInfo.processInfo.environment["DSH_NOTCH_RUNTIME_FILE"] != nil && model.needsAction { return }
    guard model.expanded, model.foldEnabled, enteredIsland, foldWork == nil else { return }
    let work = DispatchWorkItem { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.foldWork = nil
        if self.pointerOverVisual() { return }
        self.enteredIsland = false
        self.model.expanded = false
        self.updateHits()
        self.panel?.orderFrontRegardless()
      }
    }
    foldWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.38, execute: work)
  }

  private func updateHits() {
    guard let panel else { return }
    if dock.hidden && !dock.settling && model.expanded { model.expanded = false }
    let width = max(1, model.currentIslandWidth)
    let height = min(max(1, model.currentIslandHeight), model.maximumExpandedHeight)
    if let dockController { dockController.updateRest(NSSize(width: width, height: height)) }
    else { panel.resizeAnchored(to: NSSize(width: width, height: height), animated: true) }
  }
}
