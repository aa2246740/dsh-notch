import AppKit
import Combine
import SwiftUI

/// Opt-in preview diagnostics. These are update/commit timings, not a claim
/// about photons presented by WindowServer; no task content is recorded.
@MainActor
final class EdgeDockDiagnostics {
  private var intervals = [Double]()
  private var renderCosts = [Double]()
  private var resizes = 0
  private var masks = 0
  private var compositorSamples = 0
  private var clock = "timer-120"
  private var active = false
  private var lastTick = 0.0
  func begin(clock: String) {
    self.clock = clock; intervals = []; renderCosts = []; resizes = 0; masks = 0; compositorSamples = 0; active = true; lastTick = CACurrentMediaTime()
  }
  func composite(samples: Int) { compositorSamples = samples }
  func tick() {
    guard active else { return }
    let now = CACurrentMediaTime(); intervals.append((now-lastTick)*1000); lastTick = now
  }
  func render(seconds: Double, resized: Bool, newMask: Bool) {
    guard active else { return }
    renderCosts.append(seconds * 1000)
    if resized { resizes += 1 }; if newMask { masks += 1 }
  }
  func finish() {
    guard active else { return }; active = false
    func percentile(_ values: [Double], _ p: Double) -> Double {
      let sorted = values.sorted(); return sorted.isEmpty ? 0 : sorted[min(sorted.count-1,Int(Double(sorted.count-1)*p))]
    }
    let result: [String: Any] = ["clock":clock,"frames":intervals.count,
      "intervalP50Ms":percentile(intervals,0.5),"intervalP95Ms":percentile(intervals,0.95),
      "intervalMaxMs":intervals.max() ?? 0,"intervalsOver20Ms":intervals.filter{$0>20}.count,
      "renderP95Ms":percentile(renderCosts,0.95),"renderMaxMs":renderCosts.max() ?? 0,
      "windowResizes":resizes,"maskAllocations":masks,"renderUpdates":renderCosts.count,"compositorSamples":compositorSamples,
      "intervalsMs":intervals,"renderCostsMs":renderCosts]
    let folder = URL(fileURLWithPath:"/tmp/dsh-notch-motion",isDirectory:true)
    try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    let file = folder.appendingPathComponent("frames-\(Int(Date().timeIntervalSince1970*1000)).json")
    if let data = try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:file,options:.atomic) }
  }
}

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
final class EdgeDockModel: NSObject, ObservableObject {
  private(set) var pose = EdgeDockPose()
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
  var diagnostics: EdgeDockDiagnostics?
  var makeDisplayLink: ((Any, Selector) -> CADisplayLink?)?
  var presentationBounds: CGRect?
  var presentedPose: (() -> EdgeDockPose?)?
  private(set) var flightRevision = 0
  var targetPose: EdgeDockPose { target }
  var momentumPadding: CGSize {
    CGSize(width:24+abs(springs.first?.velocity ?? 0)/15,
           height:24+abs(springs.count > 1 ? springs[1].velocity : 0)/15)
  }
  var dragMomentumPadding: CGSize {
    CGSize(width:24+abs(releaseVelocity.width)/15,height:24+abs(releaseVelocity.height)/15)
  }
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
  private var displayLink: CADisplayLink?
  private var clockTime = 0.0
  var blocksContent: Bool { hidden || dragging || settling }
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
    let visible = settling ? presentedPose?() : nil
    stop()
    if let visible { pose = visible }
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
    flightRevision += 1
    diagnostics?.begin(clock:"display-link")
    onFrame?()
    guard automaticTicks else { return }
    clockTime = CACurrentMediaTime()
    let link = makeDisplayLink?(self,#selector(displayFrame(_:))) ?? NSScreen.main?.displayLink(target:self,selector:#selector(displayFrame(_:)))
    displayLink = link
    link?.add(to:.main,forMode:.common)
  }
  @objc private func displayFrame(_ link: CADisplayLink) {
    guard settling else { return }
    diagnostics?.tick()
    let next = link.targetTimestamp
    advance(by:min(0.05,max(0,next-clockTime)))
    clockTime = next
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
    // A settled shell has no residual size velocity. Carrying the tiny final
    // spring velocity into a later drag would restart an invisible size change.
    springs = [target.inward,target.down,target.width,target.height,target.conceal].map { EdgeSpring(value:$0) }
    if !hidden { engaged = false; contentSize = restSize }
    onFrame?(); onSettled?(hidden)
    diagnostics?.finish(); diagnostics = nil
    if hidden && target != tuckedPose { animate(to: tuckedPose) }
  }
  func stop() { displayLink?.invalidate(); displayLink = nil; settling = false }

  /// Sample the same spring solver for a compositor-owned flight. No second
  /// easing curve: the layer keyframes retain both components of release speed.
  func flightSamples(interval: Double = 1.0/120) -> [EdgeDockPose] {
    guard springs.count == 5 else { return [pose] }
    var state = springs, frames = [pose]
    let values = [target.inward,target.down,target.width,target.height,target.conceal]
    for _ in 0..<360 {
      for i in state.indices {
        let damping: CGFloat = i == 0 ? (hidden ? 0.90 : 0.60) : i == 1 ? 0.60 : 1
        state[i].step(to:values[i],dt:interval,damping:damping)
      }
      if state.indices.allSatisfy({state[$0].settled(at:values[$0])}) { frames.append(target); break }
      frames.append(EdgeDockPose(width:max(1,state[2].value),height:max(1,state[3].value),
        inward:state[0].value,down:state[1].value,conceal:min(1,max(0,state[4].value))))
    }
    return frames
  }
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
  func path(in viewport: CGRect) -> Path { path.applying(CGAffineTransform(translationX:-viewport.minX,y:-viewport.minY)) }

  static func shell(in rect: CGRect, radius: CGFloat = 16, trailing: CGFloat = 0) -> Path {
    UnevenRoundedRectangle(topLeadingRadius:radius,bottomLeadingRadius:radius,
                          bottomTrailingRadius:trailing,topTrailingRadius:trailing,style:.continuous).path(in:rect)
  }

  private static func stretchedHull(_ original: Path, anchors: [CGPoint]) -> Path {
    // Sample the very same continuous corners used by RootView. Convex tension
    // keeps that cap, joins its tangents to the full edge and cannot form an
    // S-shaped cable or an overlapping second body. Curve error is subpixel.
    var points = anchors, current = CGPoint.zero
    func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x:(a.x+b.x)/2,y:(a.y+b.y)/2) }
    func cubic(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint, depth: Int = 0) {
      let dx = d.x-a.x, dy = d.y-a.y, length2 = dx*dx+dy*dy
      let e1 = (b.x-a.x)*dy-(b.y-a.y)*dx, e2 = (c.x-a.x)*dy-(c.y-a.y)*dx
      if length2 < 1e-12 && max(hypot(b.x-a.x,b.y-a.y),hypot(c.x-a.x,c.y-a.y)) <= 0.025 {
        points.append(d); return
      }
      // Bound flatness to 0.025 pt (0.05 physical pixels at 2x). Fixed 32-way
      // subdivision greatly over-sampled nearly straight corner segments and
      // made the compositor upload thousands of unnecessary vertices.
      if depth >= 12 || (length2 > 0 && max(e1*e1,e2*e2) <= 0.025*0.025*length2) {
        points.append(d); return
      }
      let ab = midpoint(a,b), bc = midpoint(b,c), cd = midpoint(c,d)
      let abc = midpoint(ab,bc), bcd = midpoint(bc,cd), middle = midpoint(abc,bcd)
      cubic(a,ab,abc,middle,depth:depth+1); cubic(middle,bcd,cd,d,depth:depth+1)
    }
    original.forEach { element in
      switch element {
      case .move(let p), .line(let p): points.append(p); current = p
      case .quadCurve(let p, let c):
        let a = current
        cubic(a,CGPoint(x:a.x+2*(c.x-a.x)/3,y:a.y+2*(c.y-a.y)/3),
              CGPoint(x:p.x+2*(c.x-p.x)/3,y:p.y+2*(c.y-p.y)/3),p)
        current = p
      case .curve(let p, let c, let d):
        cubic(current,c,d,p)
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

extension NotchElasticFrame {
  init(pose: EdgeDockPose, viewport: CGRect) {
    let g = EdgeDockGeometry(pose:pose)
    var flip = CGAffineTransform(a:1,b:0,c:0,d:-1,tx:0,ty:viewport.height)
    outline = g.path(in:viewport).cgPath.copy(using:&flip)!
    translation = CGPoint(x:g.body.minX-viewport.minX,y:viewport.maxY-g.body.maxY)
    let t = min(1,max(0,(pose.conceal-0.25)/0.60))
    opacity = Double(1-t*t*(3-2*t))
    let body = CGRect(origin:.zero,size:pose.size)
    var bodyFlip = CGAffineTransform(a:1,b:0,c:0,d:-1,tx:0,ty:body.height)
    bodyClip = EdgeDockGeometry.shell(in:body,radius:g.radius,trailing:g.radius*min(1,max(0,pose.inward)/16)).cgPath.copy(using:&bodyFlip)!
  }
}

struct EdgeDockSurface<Content: View>: View {
  @ObservedObject var dock: EdgeDockModel
  var content: Content
  var body: some View {
    GeometryReader { viewport in
      ZStack(alignment: .topLeading) {
        content
          .frame(width: max(1, viewport.size.width), height: max(1, viewport.size.height))
          .disabled(dock.blocksContent)
          .allowsHitTesting(!dock.blocksContent)
          .accessibilityHidden(dock.blocksContent)
      }
      .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
      .clipped()
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
  private var canvas: CGRect?
  private var wasSettling = false
  private var flightRevision = -1
  private var compositorPoses: [EdgeDockPose] = []
  private var compositorBegan = 0.0
  private let sampleInterval = 1.0/120
  var onBegin: (() -> Void)?

  init(dock: EdgeDockModel, panel: NotchPanel, hosting: NSView) {
    self.dock = dock; self.panel = panel
    super.init()
    pan = EdgePanGesture(target: self, action: #selector(panned(_:)))
    // Deliver an ordinary click when the pan fails, but never replay a release
    // into an option/approval after that same press has become a drag.
    pan.buttonMask = 1; pan.delaysPrimaryMouseButtonEvents = true
    (panel.contentView ?? hosting).addGestureRecognizer(pan)
    resetAnchor()
    dock.makeDisplayLink = { [weak panel] target, selector in
      guard let panel else { return nil }
      // Content becomes transparent/off-screen during retraction; the window's
      // visible cap, rather than that content view, owns the animation clock.
      let link = panel.displayLink(target:target,selector:selector)
      link.preferredFrameRateRange = CAFrameRateRange(minimum:60,maximum:60,preferred:60)
      return link
    }
    dock.onFrame = { [weak self] in self?.render() }
    dock.presentedPose = { [weak self] in self?.compositedPose() }
    dock.onBegin = { [weak self] in self?.wasSettling = false; self?.panel?.cancelResize(); self?.onBegin?() }
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
    let b = dock.presentationBounds ?? dock.geometry.bounds
    origin = dock.engaged ? NSPoint(x: panel.frame.minX - b.minX, y: panel.frame.maxY + b.minY)
                          : NSPoint(x: panel.frame.maxX, y: panel.frame.maxY)
  }
  func contains(_ point: NSPoint) -> Bool {
    guard let panel else { return false }
    guard dock.engaged else { return panel.frame.contains(point) }
    let geometry = compositedPose().map(EdgeDockGeometry.init(pose:)) ?? dock.geometry
    return point.x <= origin.x && geometry.path.contains(CGPoint(x:point.x-origin.x,y:origin.y-point.y))
  }
  private func compositedPose() -> EdgeDockPose? {
    guard !compositorPoses.isEmpty else { return nil }
    let index = min(compositorPoses.count-1,max(0,Int((CACurrentMediaTime()-compositorBegan)/sampleInterval)))
    return compositorPoses[index]
  }
  func updateRest(_ size: CGSize) {
    dock.updateRest(size)
    if !dock.engaged { panel?.resizeAnchored(to: size) }
  }
  private func render() {
    guard let panel else { return }
    if dock.settling && flightRevision == dock.flightRevision && !compositorPoses.isEmpty { return }
    if !compositorPoses.isEmpty { panel.stopElasticFlight(); compositorPoses = [] }
    let began = CACurrentMediaTime(), previousFrame = panel.frame
    let previousMask = panel.dockContourLayer
    panel.cancelResize()
    let g = dock.geometry
    var b = dock.engaged ? g.bounds : CGRect(x:-dock.restSize.width,y:0,width:dock.restSize.width,height:dock.restSize.height)
    func reserve(_ rect: CGRect, x: CGFloat, y: CGFloat) -> CGRect {
      CGRect(x:rect.minX-x,y:rect.minY-y,width:-rect.minX+x,height:rect.height+2*y)
    }
    if dock.engaged && (dock.dragging || dock.settling) {
      if dock.dragging {
        let rest = CGRect(x:-dock.restSize.width,y:0,width:dock.restSize.width,height:dock.restSize.height)
        let padding = dock.dragMomentumPadding
        let envelope = reserve(b.union(rest),x:padding.width,y:padding.height)
        // Reserve the release envelope while the pointer is still moving. A
        // native backing resize on mouse-up can otherwise delay lift-off by an
        // entire frame (or more) before the compositor gets its trajectory.
        if canvas == nil || !canvas!.contains(envelope) {
          let expanded = reserve(envelope,x:96,y:96)
          canvas = canvas.map { $0.union(expanded) } ?? expanded
        }
      }
      if canvas == nil { canvas = reserve(b,x:24,y:24) }
      if dock.settling && (!wasSettling || flightRevision != dock.flightRevision) {
        let target = EdgeDockGeometry(pose:dock.targetPose).bounds
        let padding = dock.momentumPadding
        canvas = canvas!.union(reserve(b.union(target),x:padding.width,y:padding.height))
      } else if dock.dragging && !canvas!.contains(b) {
        canvas = canvas!.union(reserve(b,x:24,y:24))
      }
      b = canvas!
    } else { canvas = nil }
    wasSettling = dock.settling
    // Keep the native backing store stationary throughout the spring. The
    // contour and content translate inside it, on one display-synchronized tick.
    let scale = panel.backingScaleFactor
    let left = floor(b.minX*scale)/scale, top = floor(b.minY*scale)/scale, bottom = ceil(b.maxY*scale)/scale
    b = CGRect(x:left,y:top,width:-left,height:bottom-top)
    dock.presentationBounds = dock.engaged ? b : nil
    let frame = NSRect(x:origin.x+b.minX,y:origin.y-b.maxY,width:b.width,height:b.height)
    // Ensure a run-loop transaction exists before nesting our atomic contour /
    // content update. A root explicit transaction commits synchronously here,
    // competing with AppKit's commit and stalling on WindowServer backpressure.
    CATransaction.setDisableActions(CATransaction.disableActions())
    CATransaction.begin(); CATransaction.setDisableActions(true)
    if frame != previousFrame {
      panel.setFrame(frame,display:false)
      panel.contentView?.layoutSubtreeIfNeeded()
    }
    var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: b.height)
    panel.elasticMask(dock.engaged ? g.path(in:b).cgPath.copy(using:&flip) : nil)
    let contentFrame = dock.engaged ? CGRect(x:g.body.minX-b.minX,y:b.maxY-g.body.maxY,width:g.body.width,height:g.body.height) : nil
    panel.positionMotionContent(contentFrame,opacity:dock.engaged ? dock.contentOpacity : 1,
                                trailingRadius:g.radius * min(1,max(0,dock.pose.inward)/16))
    flightRevision = dock.flightRevision
    if dock.settling && dock.automaticTicks && dock.pose.size == dock.targetPose.size {
      let poses = dock.flightSamples(interval:sampleInterval)
      if poses.count > 1 && poses.allSatisfy({ $0.size == dock.pose.size }) {
        let frames = poses.map { NotchElasticFrame(pose:$0,viewport:b) }
        compositorBegan = CACurrentMediaTime()
        panel.startElasticFlight(frames:frames,interval:sampleInterval,began:compositorBegan)
        dock.diagnostics?.composite(samples:poses.count)
        compositorPoses = poses
      }
    }
    CATransaction.commit()
    dock.diagnostics?.render(seconds:CACurrentMediaTime()-began,resized:panel.frame != previousFrame,
                             newMask:dock.engaged && panel.dockContourLayer !== previousMask)
  }
}
