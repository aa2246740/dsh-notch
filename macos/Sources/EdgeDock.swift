import AppKit
import Combine
import SwiftUI

/// Coordinates relative to the original top-right corner, with y downward.
struct EdgeDockPose: Equatable {
  var width: CGFloat = 38
  var height: CGFloat = 44
  var inward: CGFloat = 0
  var down: CGFloat = 0
  var conceal: CGFloat = 0
  var size: CGSize { CGSize(width: width, height: height) }
  var body: CGRect { CGRect(x: -width - inward, y: down, width: width, height: height) }
  static let hidden = EdgeDockPose(width: 6, height: 28, conceal: 1)
  static let peek = EdgeDockPose(width: 12, height: 28, conceal: 1)
}

struct EdgeSpring {
  var value: CGFloat
  var velocity: CGFloat = 0
  mutating func step(to target: CGFloat, dt: Double, frequency: CGFloat = 15, damping: CGFloat = 0.60) {
    let steps = max(1, Int(ceil(dt / (1.0 / 240))))
    let h = CGFloat(dt / Double(steps))
    for _ in 0..<steps {
      velocity += (-frequency * frequency * (value - target) - 2 * damping * frequency * velocity) * h
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
  var contentSize = CGSize(width: 38, height: 44)
  var restSize = CGSize(width: 38, height: 44)
  var onFrame: (() -> Void)?
  var onBegin: (() -> Void)?
  var onHidden: ((Bool) -> Void)?
  var onSettled: ((Bool) -> Void)?
  var automaticTicks = true
  var reduceMotionOverride: Bool?
  var reduceMotion: Bool { reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
  private var hovered = false
  private var beganHidden = false
  private var grabbed = EdgeDockPose()
  private var grabFraction = CGPoint(x: 0.5, y: 0.5)
  private var lastMotionTime = 0.0
  private var releaseVelocity = CGSize.zero
  private var displacement = CGSize.zero
  private var springs: [EdgeSpring] = []
  private var target = EdgeDockPose()
  private var timer: Timer?
  private var generation = 0
  private var clockTime = 0.0
  private var contactFromInside = true
  var blocksContent: Bool { hidden || dragging || pose.conceal > 0.01 }
  var contentOpacity: Double {
    let t = min(1, max(0, (pose.conceal - 0.25) / 0.60))
    return Double(1 - t * t * (3 - 2 * t))
  }
  var geometry: EdgeDockGeometry { EdgeDockGeometry(pose: pose, attachmentY: contentSize.height / 2) }

  func updateRest(_ size: CGSize) {
    let previous = restSize
    restSize = CGSize(width: max(1, size.width), height: max(1, size.height))
    if !engaged { contentSize = restSize; pose = EdgeDockPose(width: restSize.width, height: restSize.height) }
    else if settling && !hidden && previous != restSize { animate(to: shownPose) }
  }
  private var shownPose: EdgeDockPose { EdgeDockPose(width: restSize.width, height: restSize.height) }

  func begin(size: CGSize, grab: CGPoint = CGPoint(x: 0.5, y: 0.5), at time: Double) {
    stop()
    if !engaged { pose = EdgeDockPose(width: size.width, height: size.height); contentSize = size }
    beganHidden = hidden
    if hidden { contentSize = restSize }
    grabFraction = CGPoint(x: min(1, max(0, grab.x)), y: min(1, max(0, grab.y)))
    grabbed = pose; lastMotionTime = time; displacement = .zero; releaseVelocity = .zero
    engaged = true; dragging = true
    onBegin?()
  }

  func drag(inward: CGFloat, down: CGFloat = 0, at time: Double) {
    guard dragging else { return }
    let moved = CGSize(width: inward - displacement.width, height: down - displacement.height)
    let dt = time - lastMotionTime
    // A mouse-up at the same point must not erase the release velocity.
    if hypot(moved.width, moved.height) > 0.01 {
      if dt > 0.0001 {
        releaseVelocity = CGSize(width: min(2200, max(-2200, moved.width / CGFloat(dt))),
                                 height: min(2200, max(-2200, moved.height / CGFloat(dt))))
      }
      lastMotionTime = time
    }
    displacement = CGSize(width: inward, height: down)
    var next = grabbed
    if beganHidden {
      let reveal = min(1, max(0, hypot(inward, down) / 64))
      next.width += (restSize.width - grabbed.width) * reveal
      next.height += (restSize.height - grabbed.height) * reveal
      next.conceal = grabbed.conceal * (1 - reveal)
    }
    // Preserve the point under the cursor, including while the nub grows.
    next.inward = grabbed.inward + inward - (next.width - grabbed.width) * (1 - grabFraction.x)
    next.down = grabbed.down + down - (next.height - grabbed.height) * grabFraction.y
    pose = next; onFrame?()
  }

  func end(at time: Double? = nil) {
    guard dragging else { return }
    dragging = false
    if let time, time - lastMotionTime > 0.12 { releaseVelocity = .zero }
    let distance = hypot(displacement.width, displacement.height)
    let projection = hypot(displacement.width + releaseVelocity.width * 0.045, displacement.height + releaseVelocity.height * 0.045)
    let commits = distance > 24 || (distance > 10 && projection > 40)
    setHidden(commits ? !beganHidden : beganHidden, velocity: releaseVelocity)
  }
  func cancel() {
    guard dragging || settling else { return }
    dragging = false; setHidden(beganHidden)
  }
  func setHidden(_ value: Bool, velocity: CGSize? = nil, animated: Bool = true) {
    if !engaged { pose = shownPose; contentSize = restSize }
    if !value && hidden { contentSize = restSize }
    engaged = true; hidden = value; dragging = false
    contactFromInside = pose.inward >= 0
    onHidden?(value)
    animate(to: value ? (hovered ? .peek : .hidden) : shownPose, velocity: velocity, animated: animated)
  }
  func hover(_ value: Bool) {
    guard hovered != value else { return }
    hovered = value
    // Hover must not restart or cancel the flight back to the edge.
    guard hidden && !dragging && abs(pose.inward) < 0.1 && abs(pose.down) < 0.1 else { return }
    animate(to: value ? .peek : .hidden)
  }
  private func animate(to next: EdgeDockPose, velocity: CGSize? = nil, animated: Bool = true) {
    let old = springs
    stop(); target = next
    let values = [pose.inward, pose.down, pose.width, pose.height, pose.conceal]
    springs = values.enumerated().map { index, value in
      let inherited = old.count == 5 ? old[index].velocity : 0
      let speed = index == 0 ? velocity?.width : index == 1 ? velocity?.height : nil
      return EdgeSpring(value: value, velocity: speed ?? inherited)
    }
    if !animated || reduceMotion { finish(); return }
    settling = true
    guard automaticTicks else { return }
    let current = generation
    clockTime = ProcessInfo.processInfo.systemUptime
    let tick = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.generation == current else { return }
        let now = ProcessInfo.processInfo.systemUptime
        self.advance(by: min(0.05, now - self.clockTime)); self.clockTime = now
      }
    }
    timer = tick; RunLoop.main.add(tick, forMode: .common)
  }
  func advance(by dt: Double) {
    guard settling, dt > 0 else { return }
    let values = [target.inward, target.down, target.width, target.height, target.conceal]
    for index in springs.indices {
      springs[index].step(to: values[index], dt: min(dt, 0.05), damping: index < 2 ? 0.60 : 1)
    }
    // A soft contact compresses the shell rather than losing it off-screen.
    let contact = contactFromInside ? max(0, -springs[0].value) : 0
    let compression = 1 / (1 + contact * 0.035)
    pose = EdgeDockPose(width: max(3, springs[2].value * compression),
                        height: max(12, springs[3].value * (1 + min(0.16, contact * 0.012))),
                        inward: contactFromInside ? max(0, springs[0].value) : springs[0].value, down: springs[1].value,
                        conceal: min(1, max(0, springs[4].value)))
    if springs.indices.allSatisfy({ springs[$0].settled(at: values[$0]) }) { finish() }
    else { onFrame?() }
  }
  private func finish() {
    stop(); pose = target
    if !hidden { engaged = false; contentSize = restSize }
    onFrame?(); onSettled?(hidden)
    if hidden && target != (hovered ? .peek : .hidden) { animate(to: hovered ? .peek : .hidden) }
  }
  func stop() { generation += 1; timer?.invalidate(); timer = nil; settling = false }
}

struct EdgeDockGeometry {
  let body: CGRect
  let bounds: CGRect
  let path: Path
  let radius: CGFloat

  init(pose: EdgeDockPose, attachmentY: CGFloat) {
    body = pose.body
    let distance = hypot(pose.inward, pose.down)
    radius = min(pose.width / 2, 16 + (2 - 16) * pose.conceal)
    let rightRadius = radius * min(1, distance / 20)
    var outline = Self.roundedBody(body, left: radius, right: rightRadius)
    if distance > 0.01 {
      let c = CGPoint(x: body.midX, y: body.midY)
      let anchor = CGPoint(x: 0, y: attachmentY)
      let dx = anchor.x - c.x, dy = anchor.y - c.y
      let length = max(1, hypot(dx, dy))
      let normal = CGPoint(x: -dy / length, y: dx / length)
      let head = min(body.width, body.height) * 0.38
      let neck = max(2, min(12, head) / (1 + distance / 85))
      let a = CGPoint(x: c.x - normal.x * head, y: c.y - normal.y * head)
      let b = CGPoint(x: c.x + normal.x * head, y: c.y + normal.y * head)
      let reach = min(length * 0.42, max(20, body.width * 0.8 + abs(pose.inward) * 0.4))
      var tail = Path()
      tail.move(to: a)
      tail.addCurve(to: CGPoint(x: 0, y: anchor.y - neck),
                    control1: CGPoint(x: a.x + dx * 0.45, y: a.y + dy * 0.45),
                    control2: CGPoint(x: -reach, y: anchor.y - neck))
      tail.addLine(to: CGPoint(x: 0, y: anchor.y + neck))
      tail.addCurve(to: b, control1: CGPoint(x: -reach, y: anchor.y + neck),
                    control2: CGPoint(x: b.x + dx * 0.45, y: b.y + dy * 0.45))
      tail.closeSubpath()
      outline.addPath(tail)
    }
    path = outline
    let raw = outline.boundingRect
    bounds = CGRect(x: min(-1, raw.minX), y: raw.minY,
                    width: max(1, -min(-1, raw.minX)), height: max(1, raw.height))
  }
  var localBody: CGRect { body.offsetBy(dx: -bounds.minX, dy: -bounds.minY) }
  var localPath: Path { path.applying(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)) }

  static func roundedBody(_ b: CGRect, left: CGFloat, right: CGFloat) -> Path {
    let l = min(left, b.height / 2), r = min(right, b.height / 2)
    var p = Path()
    p.move(to: CGPoint(x: b.minX + l, y: b.minY))
    p.addLine(to: CGPoint(x: b.maxX - r, y: b.minY))
    p.addQuadCurve(to: CGPoint(x: b.maxX, y: b.minY + r), control: CGPoint(x: b.maxX, y: b.minY))
    p.addLine(to: CGPoint(x: b.maxX, y: b.maxY - r))
    p.addQuadCurve(to: CGPoint(x: b.maxX - r, y: b.maxY), control: CGPoint(x: b.maxX, y: b.maxY))
    p.addLine(to: CGPoint(x: b.minX + l, y: b.maxY))
    p.addQuadCurve(to: CGPoint(x: b.minX, y: b.maxY - l), control: CGPoint(x: b.minX, y: b.maxY))
    p.addLine(to: CGPoint(x: b.minX, y: b.minY + l))
    p.addQuadCurve(to: CGPoint(x: b.minX + l, y: b.minY), control: CGPoint(x: b.minX, y: b.minY))
    p.closeSubpath(); return p
  }
}

struct EdgeDockOutline: Shape {
  var geometry: EdgeDockGeometry?
  func path(in rect: CGRect) -> Path { geometry?.localPath ?? Path(rect) }
}

struct EdgeDockSurface<Content: View>: View {
  @ObservedObject var dock: EdgeDockModel
  var content: Content
  var body: some View {
    GeometryReader { viewport in
      let g = dock.geometry
      let base = dock.engaged ? dock.contentSize : viewport.size
      let body = dock.engaged ? g.localBody : CGRect(origin: .zero, size: viewport.size)
      ZStack(alignment: .topLeading) {
        if dock.engaged { g.localPath.fill(Color.black) }
        content
          .frame(width: max(1, base.width), height: max(1, base.height))
          .scaleEffect(x: body.width / max(1, base.width), y: body.height / max(1, base.height), anchor: .topLeading)
          .offset(x: body.minX, y: body.minY)
          .opacity(dock.contentOpacity)
          .allowsHitTesting(!dock.blocksContent)
          .accessibilityHidden(dock.blocksContent)
      }
      .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
      .clipShape(EdgeDockOutline(geometry: dock.engaged ? g : nil))
      .contentShape(EdgeDockOutline(geometry: dock.engaged ? g : nil))
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
  private(set) var downTime: TimeInterval = 0
  private(set) var eventTime: TimeInterval = 0
  private func capture(_ event: NSEvent) {
    currentScreen = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    eventTime = event.timestamp
  }
  override func mouseDown(with event: NSEvent) {
    if let root = event.window?.contentView {
      var hit = root.hitTest(root.convert(event.locationInWindow, from: nil))
      while let view = hit {
        if view is NSTextView || (view as? NSTextField).map({ $0.isEditable || $0.isSelectable }) == true { state = .failed; return }
        hit = view.superview
      }
    }
    capture(event); downScreen = currentScreen; downTime = eventTime
    super.mouseDown(with: event)
  }
  override func mouseDragged(with event: NSEvent) {
    capture(event)
    if state == .possible && hypot(currentScreen.x - downScreen.x, currentScreen.y - downScreen.y) < 4 { return }
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
    pan.buttonMask = 1; pan.delaysPrimaryMouseButtonEvents = false
    hosting.addGestureRecognizer(pan)
    resetAnchor()
    dock.onFrame = { [weak self] in self?.render() }
    dock.onBegin = { [weak self] in self?.panel?.cancelResize(); self?.onBegin?() }
    panel.cancelDock = { [weak dock] in dock?.cancel() }
  }

  @objc private func panned(_ gesture: NSPanGestureRecognizer) {
    let pointer = pan.currentScreen
    switch gesture.state {
    case .began:
      guard let panel else { return }
      if !dock.engaged { resetAnchor() }
      pointerOrigin = pan.downScreen
      let body = dock.engaged ? dock.pose.body : CGRect(x: -panel.frame.width, y: 0, width: panel.frame.width, height: panel.frame.height)
      let grab = CGPoint(x: (pointerOrigin.x - origin.x - body.minX) / body.width,
                         y: (origin.y - pointerOrigin.y - body.minY) / body.height)
      dock.begin(size: panel.frame.size, grab: grab, at: pan.downTime)
      fallthrough
    case .changed:
      dock.drag(inward: pointerOrigin.x - pointer.x, down: pointerOrigin.y - pointer.y, at: pan.eventTime)
    case .ended:
      dock.drag(inward: pointerOrigin.x - pointer.x, down: pointerOrigin.y - pointer.y, at: pan.eventTime)
      dock.end(at: pan.eventTime)
    case .cancelled, .failed: if dock.dragging { dock.cancel() }
    default: break
    }
  }
  func resetAnchor() {
    guard let panel else { return }
    let g = dock.geometry
    origin = dock.engaged ? NSPoint(x: panel.frame.minX - g.bounds.minX, y: panel.frame.maxY + g.bounds.minY)
                          : NSPoint(x: panel.frame.maxX, y: panel.frame.maxY)
  }
  func updateRest(_ size: CGSize) {
    dock.updateRest(size)
    if !dock.engaged { panel?.resizeAnchored(to: size) }
  }
  private func render() {
    guard let panel else { return }
    panel.cancelResize()
    let g = dock.geometry
    let b = dock.engaged ? g.bounds : CGRect(x: -dock.restSize.width, y: 0, width: dock.restSize.width, height: dock.restSize.height)
    panel.setFrame(NSRect(x: origin.x + b.minX, y: origin.y - b.maxY, width: b.width, height: b.height), display: true)
    var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: b.height)
    panel.elasticMask(dock.engaged ? g.localPath.cgPath.copy(using: &flip) : nil)
  }
}
