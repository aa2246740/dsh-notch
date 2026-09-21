import AppKit
import SwiftUI

@main enum EdgeDockProbe {
  @MainActor static func main() {
    NSApplication.shared.setActivationPolicy(.accessory)
    var failures = 0
    func check(_ ok: Bool, _ label: String) { if !ok { failures += 1; print("FAIL \(label)") } }
    func settle(_ dock: EdgeDockModel) { for _ in 0..<240 { dock.advance(by: 1.0/120) } }
    func make() -> EdgeDockModel { let d = EdgeDockModel(); d.automaticTicks = false; d.reduceMotionOverride = false; d.updateRest(CGSize(width: 38, height: 66)); return d }
    let dock = make()
    dock.begin(size: dock.restSize, at: 0); dock.drag(inward: 70, at: 0.2)
    check(dock.pose.width > 80 && dock.pose.height < 66 && dock.pose.stretch > 0, "drag stretches and thins same surface")
    let before = dock.pose; dock.end()
    check(dock.pose == before, "release does not jump to target")
    settle(dock)
    check(dock.hidden && dock.pose == .hidden, "hidden endpoint and hit area are exactly 5 by 28")
    dock.hover(true); settle(dock)
    check(dock.hidden && dock.pose == .peek && dock.contentOpacity == 0, "hover peeks without restoring content")
    dock.hover(false); settle(dock)
    dock.begin(size: dock.pose.size, at: 1); dock.drag(inward: 8, at: 1.3); dock.end(); settle(dock)
    check(dock.hidden && dock.pose == .hidden, "small pull returns to pocket")
    dock.begin(size: dock.pose.size, at: 2); dock.drag(inward: 52, at: 2.3); dock.end(); settle(dock)
    check(!dock.hidden && !dock.engaged && dock.pose.size == dock.restSize, "outward pull restores exact original geometry")
    for fraction in [0.01, 0.08, 0.2, 0.35] {
      dock.setHidden(true)
      for _ in 0..<max(1, Int(fraction * 120)) { dock.advance(by: 1.0/120) }
      let live = dock.pose
      dock.begin(size: live.size, at: 5)
      check(dock.pose == live, "grabbing a moving shell preserves current presentation")
      dock.drag(inward: 60, at: 5.2); dock.end(); settle(dock)
      check(!dock.hidden && dock.pose.size == dock.restSize, "interrupted hide can reverse fully")
    }
    dock.setHidden(true); settle(dock); dock.setHidden(false); dock.advance(by: 0.04)
    let beforeRetarget = dock.pose
    dock.updateRest(CGSize(width: 38, height: 112))
    check(dock.pose == beforeRetarget, "task geometry can retarget a restore without jumping")
    settle(dock)
    check(dock.pose.size == dock.restSize, "restore ends at latest task geometry")
    for distance in stride(from: CGFloat(0), through: 1000, by: 10) {
      check(EdgeDockModel.rubber(distance) <= distance && EdgeDockModel.rubber(distance) < 160, "rubber resistance is bounded")
    }
    dock.reduceMotionOverride = true; dock.setHidden(true)
    check(!dock.settling && dock.pose == .hidden, "reduced motion commits hidden endpoint immediately")
    dock.setHidden(false)
    check(!dock.settling && !dock.engaged && dock.pose.size == dock.restSize, "reduced motion restores immediately")

    // A drag must take ownership from an in-flight AppKit expansion, too.
    let native = make()
    let panel = NotchPanel(size: native.restSize)
    panel.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    let host = NotchHostingView(rootView: EdgeDockSurface(dock: native, content: Color.black))
    host.sizingOptions = []; panel.embedHost(host)
    let controller = EdgeDockController(dock: native, panel: panel, hosting: host)
    controller.updateRest(CGSize(width: 420, height: 320))
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    native.begin(size: panel.frame.size, at: 10)
    native.drag(inward: 70, at: 10.2)
    let locked = panel.frame
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    check(abs(panel.frame.width - locked.width) < 0.1 && abs(panel.frame.height - locked.height) < 0.1, "drag cancels old native geometry animation")
    native.end(); settle(native)
    check(panel.frame.size == EdgeDockPose.hidden.size, "actual hidden window matches visible nub")
    native.stop(); panel.close()
    let folder = ProcessInfo.processInfo.environment["NOTCH_EDGE_OUTPUT"] ?? NSTemporaryDirectory()
    try! FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let samples: [(String, EdgeDockPose)] = [("shown", EdgeDockPose()), ("stretched", EdgeDockPose(width: 140, height: 54, stretch: 0.9)), ("hidden", .hidden), ("peek", .peek)]
    for (name, pose) in samples {
      let shape = ElasticDockShape(stretch: pose.stretch)
      check(shape.path(in: CGRect(origin: .zero, size: pose.size)).boundingRect.width <= pose.width + 0.01, "shape stays in actual mouse hit rectangle")
      let view = ZStack(alignment: .trailing) {
        Color(red: 0.94, green: 0.94, blue: 0.95)
        shape.fill(Color.black).frame(width: pose.width, height: pose.height)
      }.frame(width: 260, height: 140)
      let host = NSHostingView(rootView: view); host.frame = NSRect(x: 0, y: 0, width: 260, height: 140)
      let panel = NSPanel(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false); panel.contentView = host
      host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
      let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
      host.cacheDisplay(in: host.bounds, to: rep)
      try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
      panel.close()
    }
    dock.stop(); print("CHECKED elastic drag, hide, hover, restore, interruption, hit area, reduced motion"); print("FAILURES=\(failures)")
    exit(failures == 0 ? 0 : 1)
  }
}
