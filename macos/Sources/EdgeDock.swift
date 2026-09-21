import AppKit
import Combine
import SwiftUI

struct EdgeDockPose: Equatable {
  var width: CGFloat = 38
  var height: CGFloat = 66
  var stretch: CGFloat = 0
  var conceal: CGFloat = 0
  var size: CGSize { CGSize(width: width, height: height) }
  static let hidden = EdgeDockPose(width: 5, height: 28, conceal: 1)
  static let peek = EdgeDockPose(width: 11, height: 32, conceal: 1)
}

/// One damped spring, with velocity retained when its destination changes.
struct EdgeSpring {
  var value: CGFloat
  var velocity: CGFloat = 0
  mutating func step(to target: CGFloat, dt: Double) {
    let steps = max(1, Int(ceil(dt / (1.0 / 240))))
    let h = CGFloat(dt / Double(steps)), omega: CGFloat = 24, damping: CGFloat = 0.84
    for _ in 0..<steps {
      velocity += (-omega * omega * (value - target) - 2 * damping * omega * velocity) * h
      value += velocity * h
    }
  }
  func settled(at target: CGFloat) -> Bool { abs(value - target) < 0.025 && abs(velocity) < 0.15 }
}

@MainActor
final class EdgeDockModel: ObservableObject {
  @Published private(set) var pose = EdgeDockPose()
  @Published private(set) var hidden = false
  @Published private(set) var dragging = false
  @Published private(set) var settling = false
  @Published private(set) var engaged = false
  var contentSize = CGSize(width: 38, height: 66)
  var restSize = CGSize(width: 38, height: 66)
  var onFrame: (() -> Void)?
  var onBegin: (() -> Void)?
  var onHidden: ((Bool) -> Void)?
  var onSettled: ((Bool) -> Void)?
  var automaticTicks = true
  var reduceMotion: Bool { reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
  var reduceMotionOverride: Bool?
  private var hovered = false
  private var beganHidden = false
  private var grabbed = EdgeDockPose()
  private var lastTime = 0.0
  private var releaseSpeed: CGFloat = 0
  private var distance: CGFloat = 0
  private var springs: [EdgeSpring] = []
  private var target = EdgeDockPose()
  private var timer: Timer?
  private var generation = 0
  var blocksContent: Bool { hidden || dragging || pose.conceal > 0.01 }
  var contentOpacity: Double { Double(max(0, 1 - pose.conceal * 1.8)) }

  static func rubber(_ distance: CGFloat, limit: CGFloat = 160) -> CGFloat {
    let amount = abs(distance)
    return (distance < 0 ? -1 : 1) * limit * amount / (limit + amount)
  }

  func updateRest(_ size: CGSize) {
    let previous = restSize
    restSize = CGSize(width: max(1, size.width), height: max(1, size.height))
    if !engaged { contentSize = restSize; pose = EdgeDockPose(width: size.width, height: size.height) }
    else if settling && !hidden && previous != restSize {
      animate(to: EdgeDockPose(width: restSize.width, height: restSize.height))
    }
  }

  func begin(size: CGSize, at time: Double) {
    stop()
    if !engaged { pose = EdgeDockPose(width: size.width, height: size.height) }
    beganHidden = hidden
    contentSize = hidden ? restSize : size
    grabbed = pose; lastTime = time; distance = 0; releaseSpeed = 0
    engaged = true; dragging = true
    onBegin?()
  }

  func drag(inward: CGFloat, at time: Double) {
    guard dragging else { return }
    distance = inward
    let pull = Self.rubber(inward, limit: beganHidden ? 90 : 160)
    var next = grabbed
    next.width = max(3, grabbed.width + pull)
    next.stretch = min(1, max(0, pull / 110))
    if beganHidden {
      let reveal = min(1, max(0, pull / 46))
      next.height = grabbed.height + (restSize.height - grabbed.height) * reveal
      next.conceal = 1 - reveal
    } else {
      next.height = max(24, grabbed.height * (1 - min(0.2, max(0, pull) / 650)))
    }
    let dt = time - lastTime
    if dt > 0.001 { releaseSpeed = min(1600, max(-1600, (next.width - pose.width) / CGFloat(dt))) }
    lastTime = time; pose = next; onFrame?()
  }

  func end() {
    guard dragging else { return }
    dragging = false
    let projected = distance + releaseSpeed * 0.06
    let commits = distance > (beganHidden ? 26 : 24) || (distance > 12 && projected > 42)
    setHidden(commits ? !beganHidden : beganHidden, velocity: releaseSpeed)
  }

  func cancel() {
    guard dragging || settling else { return }
    dragging = false
    setHidden(beganHidden)
  }

  func setHidden(_ value: Bool, velocity: CGFloat = 0, animated: Bool = true) {
    if !engaged { pose = EdgeDockPose(width: restSize.width, height: restSize.height); contentSize = restSize }
    if !value && hidden { contentSize = restSize }
    engaged = true; hidden = value; dragging = false
    onHidden?(value)
    animate(to: value ? (hovered ? .peek : .hidden) : EdgeDockPose(width: restSize.width, height: restSize.height), velocity: velocity, animated: animated)
  }

  func hover(_ value: Bool) {
    guard hovered != value else { return }
    hovered = value
    guard hidden && !dragging else { return }
    animate(to: value ? .peek : .hidden)
  }

  private func animate(to next: EdgeDockPose, velocity: CGFloat? = nil, animated: Bool = true) {
    let old = springs
    stop(); target = next
    let values = [pose.width, pose.height, pose.stretch, pose.conceal]
    springs = values.enumerated().map { index, value in
      EdgeSpring(value: value, velocity: index == 0 && velocity != nil ? velocity! : (old.count == 4 ? old[index].velocity : 0))
    }
    if !animated || reduceMotion { finish(); return }
    settling = true
    guard automaticTicks else { return }
    let current = generation
    lastTime = ProcessInfo.processInfo.systemUptime
    let tick = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.generation == current else { return }
        let now = ProcessInfo.processInfo.systemUptime
        self.advance(by: min(1.0 / 20, now - self.lastTime)); self.lastTime = now
      }
    }
    timer = tick; RunLoop.main.add(tick, forMode: .common)
  }

  func advance(by dt: Double) {
    guard settling, dt > 0 else { return }
    let values = [target.width, target.height, target.stretch, target.conceal]
    for index in springs.indices { springs[index].step(to: values[index], dt: min(dt, 0.05)) }
    pose = EdgeDockPose(width: max(2, springs[0].value), height: max(12, springs[1].value), stretch: min(1, max(0, springs[2].value)), conceal: min(1, max(0, springs[3].value)))
    if springs.indices.allSatisfy({ springs[$0].settled(at: values[$0]) }) { finish() }
    else { onFrame?() }
  }

  private func finish() {
    stop(); pose = target
    if !hidden { engaged = false; contentSize = restSize }
    onFrame?()
    onSettled?(hidden)
  }

  func stop() { generation += 1; timer?.invalidate(); timer = nil; settling = false }
}

/// Rounded head and a progressively thinner attachment to the display edge.
struct ElasticDockShape: Shape {
  var stretch: CGFloat
  func path(in rect: CGRect) -> Path {
    let w = rect.width, h = rect.height, r = min(16, min(w, h / 2))
    let pinch = min(1, max(0, stretch)) * h * 0.33
    var p = Path()
    p.move(to: CGPoint(x: w, y: pinch))
    p.addCurve(to: CGPoint(x: r, y: 0), control1: CGPoint(x: w * 0.60, y: pinch), control2: CGPoint(x: w * 0.42, y: 0))
    p.addQuadCurve(to: CGPoint(x: 0, y: r), control: .zero)
    p.addLine(to: CGPoint(x: 0, y: h - r))
    p.addQuadCurve(to: CGPoint(x: r, y: h), control: CGPoint(x: 0, y: h))
    p.addCurve(to: CGPoint(x: w, y: h - pinch), control1: CGPoint(x: w * 0.42, y: h), control2: CGPoint(x: w * 0.60, y: h - pinch))
    p.closeSubpath(); return p
  }
}

struct EdgeDockSurface<Content: View>: View {
  @ObservedObject var dock: EdgeDockModel
  var content: Content
  var body: some View {
    GeometryReader { geometry in
      let base = dock.engaged ? dock.contentSize : geometry.size
      ZStack(alignment: .leading) {
        if dock.engaged { ElasticDockShape(stretch: dock.pose.stretch).fill(Color.black) }
        content
          .frame(width: max(1, base.width), height: max(1, base.height))
          .scaleEffect(x: dock.engaged ? min(1.06, geometry.size.width / max(1, base.width)) : 1,
                       y: dock.engaged ? geometry.size.height / max(1, base.height) : 1, anchor: .leading)
          .opacity(dock.contentOpacity)
          .allowsHitTesting(!dock.blocksContent)
          .accessibilityHidden(dock.blocksContent)
      }
      .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
      .clipShape(ElasticDockShape(stretch: dock.engaged ? dock.pose.stretch : 0))
      .contentShape(Rectangle())
      .onHover { dock.hover($0) }
      .contextMenu { Button(dock.hidden ? "恢复 Notch" : "收起到屏幕边缘") { dock.setHidden(!dock.hidden) } }
      .accessibilityElement(children: dock.hidden ? .ignore : .contain)
      .accessibilityLabel(dock.hidden ? "已收起的 Notch" : "Notch")
      .accessibilityAction(named: Text(dock.hidden ? "恢复 Notch" : "收起到屏幕边缘")) { dock.setHidden(!dock.hidden) }
    }
    .transaction { if dock.engaged { $0.animation = nil } }
  }
}

@MainActor
final class EdgePanGesture: NSPanGestureRecognizer {
  private(set) var downScreen = NSPoint.zero
  private(set) var currentScreen = NSPoint.zero
  private(set) var eventTime: TimeInterval = 0
  private func capture(_ event: NSEvent) {
    currentScreen = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    eventTime = event.timestamp
  }
  override func mouseDown(with event: NSEvent) {
    // Let native editors own text-selection drags and editing shortcuts.
    if let root = event.window?.contentView {
      var hit = root.hitTest(root.convert(event.locationInWindow, from: nil))
      while let view = hit {
        if view is NSTextView || (view as? NSTextField).map({ $0.isEditable || $0.isSelectable }) == true {
          state = .failed; return
        }
        hit = view.superview
      }
    }
    capture(event); downScreen = currentScreen
    super.mouseDown(with: event)
  }
  override func mouseDragged(with event: NSEvent) {
    capture(event)
    if state == .possible {
      let dx = abs(currentScreen.x - downScreen.x), dy = abs(currentScreen.y - downScreen.y)
      if max(dx, dy) < 7 { return }
      if dy >= dx / 1.2 { state = .failed; return }
    }
    super.mouseDragged(with: event)
  }
  override func mouseUp(with event: NSEvent) { capture(event); super.mouseUp(with: event) }
}

@MainActor
final class EdgeDockController: NSObject {
  let dock: EdgeDockModel
  private weak var panel: NotchPanel?
  private var origin = NSPoint.zero
  private var pointerOrigin = NSPoint.zero
  private var pan: EdgePanGesture!
  var onBegin: (() -> Void)?

  init(dock: EdgeDockModel, panel: NotchPanel, hosting: NSView) {
    self.dock = dock; self.panel = panel
    super.init()
    pan = EdgePanGesture(target: self, action: #selector(panned(_:)))
    pan.buttonMask = 1
    pan.delaysPrimaryMouseButtonEvents = false
    hosting.addGestureRecognizer(pan)
    resetAnchor()
    dock.onFrame = { [weak self] in self?.render() }
    dock.onBegin = { [weak self] in self?.panel?.cancelResize(); self?.onBegin?() }
    panel.cancelDock = { [weak dock] in dock?.cancel() }
  }

  @objc private func panned(_ gesture: NSPanGestureRecognizer) {
    if gesture.state != .changed { trace("gesture", ["state": CGFloat(gesture.state.rawValue)]) }
    let pointer = pan.currentScreen, now = pan.eventTime
    switch gesture.state {
    case .began:
      guard let panel else { return }
      if !dock.engaged { resetAnchor() }
      pointerOrigin = pan.downScreen
      dock.begin(size: panel.frame.size, at: now)
      dock.drag(inward: pointerOrigin.x - pointer.x, at: now)
    case .changed: dock.drag(inward: pointerOrigin.x - pointer.x, at: now)
    case .ended: dock.drag(inward: pointerOrigin.x - pointer.x, at: now); dock.end()
    case .cancelled, .failed: if dock.dragging { dock.cancel() }
    default: break
    }
  }

  func resetAnchor() {
    guard let panel else { return }
    origin = NSPoint(x: panel.frame.maxX, y: panel.frame.maxY)
  }

  func updateRest(_ size: CGSize) {
    dock.updateRest(size)
    if !dock.engaged { panel?.resizeAnchored(to: size) }
  }

  private func render() {
    guard let panel else { return }
    panel.cancelResize()
    let size = dock.engaged ? dock.pose.size : dock.restSize
    panel.setFrame(NSRect(x: origin.x - size.width, y: origin.y - size.height, width: size.width, height: size.height), display: true)
    panel.elasticMask(dock.engaged ? ElasticDockShape(stretch: dock.pose.stretch).path(in: NSRect(origin: .zero, size: size)).cgPath : nil)
    if !dock.settling && !dock.dragging { trace("settled", ["width": size.width, "height": size.height, "hidden": dock.hidden ? 1 : 0]) }
  }

  private func trace(_ event: String, _ values: [String: CGFloat]) {
    guard Bundle.main.bundleIdentifier == "local.dsh.notch.elastic-preview" else { return }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("notch-elastic-preview-events.jsonl")
    var record: [String: Any] = ["event": event, "pid": ProcessInfo.processInfo.processIdentifier, "at": Date().timeIntervalSince1970]
    for (key, value) in values { record[key] = Double(value) }
    guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
    data.append(10)
    if !FileManager.default.fileExists(atPath: url.path) { try? data.write(to: url); return }
    if let handle = try? FileHandle(forWritingTo: url) { defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data) }
  }
}
