import AppKit
import SwiftUI
import Combine

@main enum ExpandedHeightProbe {
  @MainActor static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let model = BoardModel()
    model.previewMode = true
    model.maximumExpandedHeight = 800
    let panel = NotchPanel(size: NSSize(width: 480, height: 110))
    let host = NotchHostingView(rootView: RootView(model: model, panelSize: CGSize(width: 480, height: 110), restSize: CGSize(width: 32, height: 110)))
    host.sizingOptions = []
    panel.embedHost(host)
    panel.setFrame(NSRect(x: -2000, y: -2000, width: 38, height: 44), display: true)
    panel.orderFrontRegardless()
    var subscriptions = Set<AnyCancellable>()
    Publishers.CombineLatest3(model.$expanded, model.$currentIslandWidth, model.$currentIslandHeight)
      .receive(on: DispatchQueue.main).sink { _ in
        panel.resizeAnchored(to: NSSize(width: model.currentIslandWidth, height: min(model.currentIslandHeight, model.maximumExpandedHeight)))
      }.store(in: &subscriptions)
    @MainActor func scrollViews(_ view: NSView) -> [NSScrollView] {
      ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }
    Task { @MainActor in
      var failures = 0
      @MainActor func check(_ condition: Bool, _ message: String) {
        if !condition { failures += 1; print("FAIL \(message)") }
      }
      @MainActor func question(_ detail: String? = nil, descriptions: Int = 1) -> NotchQuestion {
        NotchQuestion(id: "question", question: "要在哪个分支继续修改？", detail: detail, options: [
          NotchOption(label: "在 #17 分支上直接改（推荐）", description: String(repeating: "接着 cursor/reader-transcendent-merge-47c2 提交并重建，热更新到你现在这个页面验证，不用重启。", count: descriptions)),
          NotchOption(label: "另开分支/PR 改", description: "#17 保持给作者 review，玻璃改动走新分支。"),
          NotchOption(label: "暂时不改", description: "保留当前版本。")
        ])
      }
      @MainActor func show(_ questions: [NotchQuestion]) {
        model.wizard = nil
        model.rows = [NotchRow(id: "offline", title: "Local height fixture", child: false, busy: false, unread: false, ask: NotchAsk(id: "ask", questions: questions))]
        model.expanded = true
      }
      @MainActor func inspect(_ tag: String, overflowing: Bool = false) async {
        try? await Task.sleep(for: .milliseconds(850))
        host.layoutSubtreeIfNeeded()
        let scrolls = scrollViews(host)
        let overflows = scrolls.map { ($0.documentView?.frame.height ?? 0) - $0.contentView.bounds.height }
        print("CASE=\(tag) PANEL=\(panel.frame.height) MEASURED=\(model.measuredContentHeight) CAP=\(model.maximumExpandedHeight) OVERFLOWS=\(overflows)")
        if overflowing {
          check(abs(panel.frame.height - model.maximumExpandedHeight) < 2, "\(tag): reaches screen cap before scrolling")
          check(overflows.contains { $0 > 20 }, "\(tag): fixture has real overflow")
          if let scroll = scrolls.first, let document = scroll.documentView {
            let bottom = max(0, document.frame.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
            scroll.reflectScrolledClipView(scroll.contentView)
            check(abs(scroll.contentView.bounds.origin.y - bottom) < 2, "\(tag): bottom controls remain reachable")
          }
        } else {
          check(overflows.allSatisfy { $0 < 2 }, "\(tag): content fits without premature scrolling")
          check(panel.frame.height < model.maximumExpandedHeight - 5, "\(tag): short content doesn't fill screen cap")
        }
        if let output = ProcessInfo.processInfo.environment["NOTCH_HEIGHT_PROBE_OUTPUT"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
          host.cacheDisplay(in: host.bounds, to: bitmap)
          if let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: output).appendingPathComponent("\(tag).png"))
          }
        }
      }
      show([question()])
      await inspect("screenshot-options")
      model.expanded = false
      try? await Task.sleep(for: .milliseconds(40))
      model.rows = [NotchRow(id: "changed", title: "Changed during collapse", child: false, busy: false, unread: false, ask: NotchAsk(id: "changed-ask", questions: [question(descriptions: 15)]))]
      try? await Task.sleep(for: .milliseconds(80))
      model.expanded = true
      await inspect("new-content-during-collapse")
      show([question(String(repeating: "这是正文，需要完整展示。", count: 25))])
      await inspect("medium-markdown")
      show([question("第一行\n\n第二行\n\n第三行")])
      await inspect("short-markdown")
      show([question(descriptions: 80)])
      await inspect("long-options", overflowing: true)
      model.maximumExpandedHeight = 400
      await inspect("smaller-screen", overflowing: true)
      model.maximumExpandedHeight = 800
      show([question(String(repeating: "### 段落\n\n这是需要完整审核的计划正文。\n\n", count: 30))])
      await inspect("long-markdown", overflowing: true)
      show([question()])
      await inspect("shrink-back")
      model.rows = (0..<12).map { NotchRow(id: "task-\($0)", title: "任务 \($0)", child: false, busy: true, unread: false) }
      await inspect("twelve-tasks")
      show([question(), NotchQuestion(id: "other", question: "Another question", detail: String(repeating: "Long detail. ", count: 100))])
      await inspect("short-page-before-long-page")
      let ask = model.rows[0].ask!
      model.goQuestion(ask: ask, sessionId: "offline", delta: 1)
      await inspect("next-page")
      model.goQuestion(ask: ask, sessionId: "offline", delta: -1)
      await inspect("previous-page")
      model.toggleCustomField(ask: ask, sessionId: "offline")
      await inspect("custom-answer")
      print("FAILURES=\(failures)")
      exit(failures == 0 ? 0 : 1)
    }
    app.run()
    withExtendedLifetime(subscriptions) {}
  }
}
