import AppKit
import Combine
import SwiftUI

@MainActor
final class ElasticPreviewDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  static var hold: ElasticPreviewDelegate?
  private var window: NSWindow?
  private var panel: NotchPanel?
  private var controller: EdgeDockController?
  private var observers = Set<AnyCancellable>()
  private var cursorTimer: Timer?
  let model = BoardModel()
  let dock = EdgeDockModel()

  func applicationDidFinishLaunching(_ notification: Notification) {
    let menu = NSMenu()
    let application = NSMenuItem(); menu.addItem(application)
    let actions = NSMenu(); application.submenu = actions
    for (title, key, selector) in [("待机", "1", #selector(showIdle)), ("运行中", "2", #selector(showBusy)), ("等待选择", "3", #selector(showQuestion)), ("恢复 Notch", "r", #selector(restore)), ("显示预览控制", "0", #selector(showControls))] {
      actions.addItem(withTitle: title, action: selector, keyEquivalent: key).target = self
    }
    for (title,key,selector) in [("观察短拉", "4", #selector(inspectShortPull)),
                                 ("观察中拉", "5", #selector(inspectMediumPull)),
                                 ("观察长拉", "6", #selector(inspectLongPull))] {
      actions.addItem(withTitle:title,action:selector,keyEquivalent:key).target = self
    }
    actions.addItem(.separator())
    actions.addItem(withTitle:"记录下一次回弹帧", action:#selector(traceNextSpring), keyEquivalent:"t").target = self
    actions.addItem(withTitle:"回放并测量收纳", action:#selector(replaySpring), keyEquivalent:"p").target = self
    actions.addItem(withTitle: "退出预览", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
    NSApp.mainMenu = menu
    model.previewMode = true; model.maximumExpandedHeight = 320; model.connected = true
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 580), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    window.title = "Notch · 弹性收纳预览"
    window.delegate = self; window.isReleasedWhenClosed = false
    let studio = ElasticPreviewView(dock: dock, choose: { [weak self] in self?.choose($0) })
    window.contentView = NSHostingView(rootView: studio)
    self.window = window; window.center(); window.makeKeyAndOrderFront(nil)

    let panel = NotchPanel(size: CGSize(width: 38, height: 66))
    panel.title = "Notch · 拖动预览"
    panel.allowsMainWindow = true
    panel.styleMask = [.borderless]
    panel.becomesKeyOnlyIfNeeded = false
    panel.level = .floating
    let root = RootView(model: model, panelSize: CGSize(width: 420, height: 320), restSize: CGSize(width: 38, height: 66))
    let host = NotchHostingView(rootView: EdgeDockSurface(dock: dock, content: root))
    host.sizingOptions = []; panel.embedHost(host)
    self.panel = panel
    locate()
    let controller = EdgeDockController(dock: dock, panel: panel, hosting: host)
    self.controller = controller
    controller.onBegin = { [weak self] in self?.model.isPillHovered = false }
    dock.onHidden = { [weak self] hidden in self?.model.visuallyDocked = hidden }
    dock.onSettled = { [weak self] hidden in if hidden { self?.model.expanded = false } }
    Publishers.CombineLatest3(model.$currentIslandWidth, model.$currentIslandHeight, model.$expanded)
      .receive(on: DispatchQueue.main).sink { [weak self] width, height, expanded in
        guard let self else { return }
        if self.dock.hidden && !self.dock.settling && expanded { self.model.expanded = false }
        self.controller?.updateRest(CGSize(width: width, height: min(height, 320)))
      }.store(in: &observers)
    window.addChildWindow(panel, ordered: .above); panel.makeKeyAndOrderFront(nil)
    cursorTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self, let panel = self.panel else { return }
        self.dock.hover(self.controller?.contains(NSEvent.mouseLocation) ?? panel.frame.contains(NSEvent.mouseLocation))
      }
    }
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  @objc private func inspectShortPull() { inspectPull(32) }
  @objc private func inspectMediumPull() { inspectPull(140) }
  @objc private func inspectLongPull() { inspectPull(320) }
  private func inspectPull(_ distance: CGFloat) {
    choose(0)
    dock.updateRest(CGSize(width:38,height:44))
    dock.setHidden(false,animated:false)
    let began=CACurrentMediaTime()
    dock.begin(size:dock.restSize,at:began)
    dock.drag(inward:distance,at:began+1)
    window?.makeKeyAndOrderFront(nil)
  }
  @objc private func showIdle() { choose(0) }
  @objc private func showBusy() { choose(1) }
  @objc private func showQuestion() { choose(2) }
  @objc private func restore() { dock.setHidden(false) }
  @objc private func showControls() { window?.makeKeyAndOrderFront(nil) }
  @objc private func traceNextSpring() { dock.diagnostics = EdgeDockDiagnostics() }
  @objc private func replaySpring() {
    choose(0); dock.setHidden(false,animated:false)
    // Leave time for the menu/AX inspection to finish before measuring. Reading
    // the accessibility tree during a spring can itself stall its main thread.
    DispatchQueue.main.asyncAfter(deadline:.now()+3) { [weak self] in
      guard let self else { return }
      let began = CACurrentMediaTime()
      self.dock.begin(size:self.dock.restSize,at:began)
      for step in 1...18 {
        DispatchQueue.main.asyncAfter(deadline:.now()+Double(step)/100) { [weak self] in
          guard let self else { return }
          let t = Double(step)/18
          self.dock.drag(inward:140*t,down:88*t,at:began+Double(step)/100)
          if step == 18 { self.dock.diagnostics = EdgeDockDiagnostics(); self.dock.end(at:began+0.18) }
        }
      }
    }
  }

  func choose(_ state: Int) {
    model.expanded = false
    let rows: [NotchRow]
    if state == 0 { rows = [] }
    else if state == 1 { rows = [NotchRow(id: "elastic-offline", title: "本地预览任务", child: false, busy: true, unread: false)] }
    else {
      let wire: [String: Any] = ["id":"elastic-offline", "title":"本地选择", "child":false, "busy":true, "unread":false,
        "ask":["id":"elastic-ask", "questions":[["id":"elastic-q", "question":"今晚想看什么？", "options":[["label":"看星星", "description":"本地测试，不会发给 DSH。"],["label":"看月亮"]]]]]]
      rows = [try! JSONDecoder().decode(NotchRow.self, from: JSONSerialization.data(withJSONObject: wire))]
    }
    model.applySnapshot(NotchSnapshot(ok: true, generatedAt: Date().timeIntervalSince1970, origin: "offline-elastic-preview", rows: rows))
  }

  private func locate() {
    guard let window, let panel else { return }
    let top = window.frame.maxY - 175
    panel.setFrameOrigin(NSPoint(x: window.frame.maxX - 54 - panel.frame.width, y: top - panel.frame.height))
    controller?.resetAnchor()
  }
  func windowDidMove(_ notification: Notification) { locate() }
  func windowWillClose(_ notification: Notification) { dock.stop(); panel?.close(); NSApplication.shared.terminate(nil) }
  func applicationWillTerminate(_ notification: Notification) { cursorTimer?.invalidate(); dock.stop() }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ElasticPreviewView: View {
  @ObservedObject var dock: EdgeDockModel
  let choose: (Int) -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 6) {
          Text("给屏幕让点地方").font(.system(size: 26, weight: .semibold))
          Text("抓住 Notch 任意方向拖动，松手弹回边缘。再拉出来恢复。").font(.system(size: 14)).foregroundStyle(.secondary)
        }
        Spacer()
        Text("独立预览 · 不调用模型").font(.system(size: 11)).foregroundStyle(.secondary)
      }.padding(.horizontal, 38).padding(.top, 32)
      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: 18).fill(Color.white)
        VStack(alignment: .leading, spacing: 16) {
          Text("留给你的工作").font(.system(size: 16, weight: .medium))
          ForEach(0..<5) { i in Capsule().fill(Color.black.opacity(0.045)).frame(width: CGFloat(180 + i % 3 * 80), height: 9) }
        }.padding(28)
        HStack { Spacer(); Rectangle().fill(Color.black.opacity(0.08)).frame(width: 1) }
      }.padding(.leading, 38).padding(.trailing, 54).padding(.top, 28)
      HStack(spacing: 14) {
        Button("待机") { choose(0) }
        Button("运行中") { choose(1) }
        Button("等待选择") { choose(2) }
        Spacer()
        Text(dock.dragging ? "松手回弹" : dock.hidden ? "已收纳 · 悬停探出，拖动恢复" : "任意方向拖动")
          .font(.system(size: 12)).foregroundStyle(.secondary)
        Button("恢复") { dock.setHidden(false) }.keyboardShortcut("r", modifiers: .command)
        Button("关闭预览") { NSApp.terminate(nil) }
      }.buttonStyle(.bordered).padding(38)
    }.frame(width: 920, height: 580).background(Color(red: 0.95, green: 0.95, blue: 0.96))
      .preferredColorScheme(.light)
  }
}
