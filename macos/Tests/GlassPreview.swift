import AppKit
import SwiftUI
import Combine

private struct PreviewBackdrop: View {
  var body: some View {
    HStack(spacing: 0) {
      Color(red: 0.94, green: 0.94, blue: 0.95)
      Color(red: 0.10, green: 0.11, blue: 0.13)
    }
    .overlay(alignment: .bottom) {
      LinearGradient(colors: [.indigo, .cyan.opacity(0.6), .orange.opacity(0.6)], startPoint: .leading, endPoint: .trailing)
        .frame(height: 440)
    }
    .overlay(alignment: .topLeading) {
      HStack {
        Text("浅色背景 · Light").foregroundStyle(.black.opacity(0.7))
        Spacer()
        Text("深色背景 · Dark").foregroundStyle(.white.opacity(0.8))
      }.font(.system(size: 14, weight: .medium)).padding(28)
    }
  }
}

@main enum GlassPreview {
  @MainActor static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let menu = NSMenu()
    let appItem = NSMenuItem()
    menu.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Quit Notch Glass Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    app.mainMenu = menu
    let floating = CommandLine.arguments.contains("--floating")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 650), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    window.title = "Notch · 暗色液态玻璃预览"
    window.isReleasedWhenClosed = false
    let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 1060, height: 650))
    let backdrop = NSHostingView(rootView: PreviewBackdrop())
    backdrop.frame = canvas.bounds
    backdrop.autoresizingMask = [.width, .height]
    canvas.addSubview(backdrop)
    window.contentView = canvas
    window.center()
    var subscriptions = Set<AnyCancellable>()
    var models: [BoardModel] = []
    var panels: [NotchPanel] = []
    for i in 0..<2 {
      let model = BoardModel()
      model.previewMode = true
      model.maximumExpandedHeight = 500
      let question = NotchQuestion(id: "glass-question", question: "这个暗色玻璃的文字清楚吗？", detail: "界面与正式 Notch 共用代码。这里的选择只在本地模拟，不调用模型，也不会操作 DSH 对话。", options: [
        NotchOption(label: "文字清楚，继续试用", description: "观察标题、选项说明以及玻璃边缘。背景变化时，正文仍应保持清晰。"),
        NotchOption(label: "背景再深一点", description: "保留边缘的液态质感，提高阅读区域的稳定性。")
      ])
      model.rows = [NotchRow(id: "preview", title: "Glass preview", child: false, busy: false, unread: false, ask: NotchAsk(id: "glass-ask", questions: [question]))]
      let host = NotchHostingView(rootView: RootView(model: model, panelSize: CGSize(width: 470, height: 500), restSize: CGSize(width: 38, height: 44)))
      host.sizingOptions = []
      let panel = NotchPanel(size: NSSize(width: 470, height: 320))
      panel.embedHost(host)
      let surface = panel.contentView!
      if floating {
        panel.setFrame(NSRect(x: window.frame.minX + CGFloat(i) * 530 + 30, y: window.frame.minY + 200, width: 470, height: 350), display: true)
        window.addChildWindow(panel, ordered: .above)
      } else {
        surface.removeFromSuperview()
        canvas.addSubview(surface)
        surface.frame = NSRect(x: CGFloat(i) * 530 + 30, y: 200, width: 470, height: 350)
      }
      Publishers.CombineLatest(model.$currentIslandWidth, model.$currentIslandHeight)
        .receive(on: DispatchQueue.main).sink { width, height in
          if floating { panel.resizeAnchored(to: NSSize(width: width, height: height)) }
          else {
            let frame = NSRect(x: CGFloat(i) * 530 + 500 - width, y: 550 - height, width: width, height: height)
            if #available(macOS 15.0, *) {
              NSAnimationContext.animate(NotchGeometryAnimation.animation) { surface.animator().frame = frame }
            } else { surface.frame = frame }
          }
        }.store(in: &subscriptions)
      models.append(model)
      panels.append(panel)
      model.expanded = true
    }
    window.makeKeyAndOrderFront(nil)
    app.activate()
    app.run()
    withExtendedLifetime((window, subscriptions, models, panels)) {}
  }
}
