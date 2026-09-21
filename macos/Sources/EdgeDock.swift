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
  static func tucked(size: CGSize, peeking: Bool = false) -> EdgeDockPose {
    let exposed = min(size.width, peeking ? 14 : 8)
    return EdgeDockPose(width: size.width, height: size.height, inward: exposed - size.width, conceal: 1)
  }
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
  private var lastMotionTime = 0.0
  private var releaseVelocity = CGSize.zero
  private var displacement = CGSize.zero
  private var springs: [EdgeSpring] = []
  private var target = EdgeDockPose()
  private var timer: Timer?
  private var generation = 0
  private var clockTime = 0.0
  var blocksContent: Bool { hidden || dragging || pose.conceal > 0.01 }
  var contentOpacity: Double {
    let t = min(1, max(0, (pose.conceal - 0.25) / 0.60))
    return Double(1 - t * t * (3 - 2 * t))
  }
  var geometry: EdgeDockGeometry { EdgeDockGeometry(pose: pose) }
  private var tuckedPose: EdgeDockPose { .tucked(size: contentSize, peeking: hovered) }

  func updateRest(_ size: CGSize) {
    let previous = restSize
    restSize = CGSize(width: max(1, size.width), height: max(1, size.height))
    if !engaged { contentSize = restSize; pose = EdgeDockPose(width: restSize.width, height: restSize.height) }
    else if settling && !hidden && previous != restSize { animate(to: shownPose) }
  }
  private var shownPose: EdgeDockPose { EdgeDockPose(width: restSize.width, height: restSize.height) }

  func begin(size: CGSize, at time: Double) {
    stop()
    if !engaged { pose = EdgeDockPose(width: size.width, height: size.height); contentSize = size }
    beganHidden = hidden
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
      next.conceal = grabbed.conceal * (1 - reveal)
    }
    // Translate the original shell, including when pulling its exposed slice out.
    next.inward = grabbed.inward + inward
    next.down = grabbed.down + down
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
    engaged = true; hidden = value; dragging = false
    onHidden?(value)
    animate(to: value ? tuckedPose : shownPose, velocity: velocity, animated: animated)
  }
  func hover(_ value: Bool) {
    guard hovered != value else { return }
    hovered = value
    // Hover must not restart or cancel the flight back to the edge.
    guard hidden && !dragging && !settling else { return }
    animate(to: tuckedPose)
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
      // Damping into the screen keeps the exposed slice visible; vertical
      // rebound and restoration preserve the rubber's elasticity.
      let damping: CGFloat = index == 0 ? (hidden ? 0.90 : 0.60) : index == 1 ? 0.60 : 1
      springs[index].step(to: values[index], dt: min(dt, 0.05), damping: damping)
    }
    pose = EdgeDockPose(width: max(1, springs[2].value), height: max(1, springs[3].value),
                        inward: springs[0].value, down: springs[1].value,
                        conceal: min(1, max(0, springs[4].value)))
    if springs.indices.allSatisfy({ springs[$0].settled(at: values[$0]) }) { finish() }
    else { onFrame?() }
  }
  private func finish() {
    stop(); pose = target
    if !hidden { engaged = false; contentSize = restSize }
    onFrame?(); onSettled?(hidden)
    if hidden && target != tuckedPose { animate(to: tuckedPose) }
  }
  func stop() { generation += 1; timer?.invalidate(); timer = nil; settling = false }
}

struct EdgeDockGeometry {
  let body: CGRect
  let bounds: CGRect
  let path: Path
  let radius: CGFloat

  init(pose: EdgeDockPose) {
    body = pose.body
    radius = min(16, pose.width / 2, pose.height / 2)
    // A single surface under tension, not a rigid head with a separate cable.
    // Behind the screen the attachment translates with the shell, leaving an
    // exact crop of the original cap instead of manufacturing a new nub.
    let anchorX = max(0, body.maxX)
    let freedCorner = radius * min(1, max(0, pose.inward) / 16)
    let original = Self.shell(in: body, radius: radius, trailing: freedCorner)
    let outline = abs(pose.down) < 0.0001 && pose.inward <= 0 ? original : Self.stretchedHull(
      original, anchors: [CGPoint(x: anchorX, y: 0), CGPoint(x: anchorX, y: pose.height)]
    )
    path = outline
    let raw = outline.boundingRect
    bounds = CGRect(x: min(-1, raw.minX), y: raw.minY,
                    width: max(1, -min(-1, raw.minX)), height: max(1, raw.height))
  }
  var localBody: CGRect { body.offsetBy(dx: -bounds.minX, dy: -bounds.minY) }
  var localPath: Path { path.applying(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)) }

  static func shell(in rect: CGRect, radius: CGFloat = 16, trailing: CGFloat = 0) -> Path {
    UnevenRoundedRectangle(topLeadingRadius:radius,bottomLeadingRadius:radius,
                          bottomTrailingRadius:trailing,topTrailingRadius:trailing,style:.continuous).path(in:rect)
  }

  private static func stretchedHull(_ original: Path, anchors: [CGPoint]) -> Path {
    // Sample the very same continuous corners used by RootView. Convex tension
    // keeps that cap, joins its tangents to the full edge and cannot form an
    // S-shaped cable or an overlapping second body. Curve error is subpixel.
    var points = anchors, current = CGPoint.zero
    original.forEach { element in
      switch element {
      case .move(let p), .line(let p): points.append(p); current = p
      case .quadCurve(let p, let c):
        let a = current
        for step in 1...32 {
          let t = CGFloat(step)/32, s = 1-t
          points.append(CGPoint(x:s*s*a.x+2*s*t*c.x+t*t*p.x, y:s*s*a.y+2*s*t*c.y+t*t*p.y))
        }
        current = p
      case .curve(let p, let c, let d):
        let a = current
        for step in 1...32 {
          let t = CGFloat(step)/32, s = 1-t
          points.append(CGPoint(x:s*s*s*a.x+3*s*s*t*c.x+3*s*t*t*d.x+t*t*t*p.x,
                                y:s*s*s*a.y+3*s*s*t*c.y+3*s*t*t*d.y+t*t*t*p.y))
        }
        current = p
      case .closeSubpath: break
      }
    }
    let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
    func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
      (b.x-a.x)*(c.y-a.y) - (b.y-a.y)*(c.x-a.x)
    }
    func half(_ input: [CGPoint]) -> [CGPoint] {
      var result = [CGPoint]()
      for point in input {
        while result.count >= 2 && cross(result[result.count-2], result.last!, point) <= 0 { result.removeLast() }
        result.append(point)
      }
      return Array(result.dropLast())
    }
    let hull = half(sorted) + half(Array(sorted.reversed()))
    var path = Path()
    path.addLines(hull)
    path.closeSubpath()
    return path
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
      let body = dock.engaged ? g.localBody : CGRect(origin: .zero, size: viewport.size)
      ZStack(alignment: .topLeading) {
        if dock.engaged { g.localPath.fill(Color.black) }
        content
          .frame(width: max(1, body.width), height: max(1, body.height))
          .offset(x: body.minX, y: body.minY)
          .opacity(dock.contentOpacity)
          .disabled(dock.blocksContent)
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
    // Deliver an ordinary click when the pan fails, but never replay a release
    // into an option/approval after that same press has become a drag.
    pan.buttonMask = 1; pan.delaysPrimaryMouseButtonEvents = true
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
      dock.begin(size: panel.frame.size, at: pan.downTime)
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
