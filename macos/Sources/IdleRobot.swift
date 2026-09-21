import AppKit
import SwiftUI

struct IdleEye: Decodable {
  var x: Double; var y: Double; var w: Double; var h: Double
  var r: Double; var angle: Double; var opacity: Double
}
struct IdleFrame: Decodable {
  var points: [[Double]]; var eyes: [IdleEye]; var body: Int; var eye: Int
}
struct IdleClip: Decodable {
  var fps: Double; var duration: Double; var frames: [IdleFrame]
}

enum IdleInterpolation {
  static func mix(_ a: IdleFrame, _ b: IdleFrame, _ t: Double) -> IdleFrame {
    let w = max(0, min(1, t))
    func n(_ x: Double, _ y: Double) -> Double { x + (y-x)*w }
    func color(_ x: Int, _ y: Int) -> Int {
      [16,8,0].reduce(0) { $0 | (Int(n(Double((x >> $1)&255), Double((y >> $1)&255)).rounded()) << $1) }
    }
    let points = zip(a.points,b.points).map { [n($0[0],$1[0]),n($0[1],$1[1])] }
    let eyes = zip(a.eyes,b.eyes).map { e,f in
      IdleEye(x:n(e.x,f.x),y:n(e.y,f.y),w:n(e.w,f.w),h:n(e.h,f.h),r:n(e.r,f.r),angle:n(e.angle,f.angle),opacity:n(e.opacity,f.opacity))
    }
    return IdleFrame(points:points,eyes:eyes,body:color(a.body,b.body),eye:color(a.eye,b.eye))
  }
  // Shape-preserving cubic Hermite interpolation: continuous velocity between
  // authored samples, without overshoot or changing the clip's choreography.
  static func sample(_ clip: IdleClip, at position: Double) -> IdleFrame {
    let p = min(Double(clip.frames.count-1), max(0, position)), i = Int(p), t = p-Double(i)
    let a=clip.frames[max(0,i-1)], b=clip.frames[i]
    let c=clip.frames[min(i+1,clip.frames.count-1)], d=clip.frames[min(i+2,clip.frames.count-1)]
    func curve(_ a:Double,_ b:Double,_ c:Double,_ d:Double) -> Double {
      func slope(_ x:Double,_ y:Double)->Double { x*y > 0 ? 2*x*y/(x+y) : 0 }
      let m=slope(b-a,c-b), n=slope(c-b,d-c), t2=t*t, t3=t2*t
      return (2*t3-3*t2+1)*b+(t3-2*t2+t)*m+(-2*t3+3*t2)*c+(t3-t2)*n
    }
    var result=mix(b,c,t)
    result.points=b.points.indices.map { j in (0...1).map { k in curve(a.points[j][k],b.points[j][k],c.points[j][k],d.points[j][k]) } }
    result.eyes=b.eyes.indices.map { j in
      let a=a.eyes[j],b=b.eyes[j],c=c.eyes[j],d=d.eyes[j]
      return IdleEye(x:curve(a.x,b.x,c.x,d.x),y:curve(a.y,b.y,c.y,d.y),w:curve(a.w,b.w,c.w,d.w),h:curve(a.h,b.h,c.h,d.h),r:curve(a.r,b.r,c.r,d.r),angle:curve(a.angle,b.angle,c.angle,d.angle),opacity:curve(a.opacity,b.opacity,c.opacity,d.opacity))
    }
    return result
  }
  static func carry(_ source:IdleFrame, previous:IdleFrame?, seconds:Double) -> IdleFrame {
    guard let previous else { return source }
    var result=source
    let distance=seconds*240
    result.points=zip(source.points,previous.points).map { a,b in [a[0]+(a[0]-b[0])*distance,a[1]+(a[1]-b[1])*distance] }
    result.eyes=zip(source.eyes,previous.eyes).map { a,b in
      func n(_ x:Double,_ y:Double)->Double { x+(x-y)*distance }
      return IdleEye(x:n(a.x,b.x),y:n(a.y,b.y),w:max(0,n(a.w,b.w)),h:max(0,n(a.h,b.h)),r:max(0,n(a.r,b.r)),angle:n(a.angle,b.angle),opacity:min(1,max(0,n(a.opacity,b.opacity))))
    }
    return result
  }
  static func smooth(_ value: Double) -> Double {
    let t=max(0,min(1,value));return t*t*t*(t*(t*6-15)+10)
  }
}

@MainActor
final class IdleLibrary {
  static let shared = IdleLibrary()
  private var clips: [String: IdleClip] = [:]
  func clip(_ id: String) -> IdleClip? {
    if let clip = clips[id] { return clip }
    guard let url = Bundle.module.url(forResource: id, withExtension: "json", subdirectory: "Idle"),
          let data = try? Data(contentsOf: url), let clip = try? JSONDecoder().decode(IdleClip.self, from: data),
          !clip.frames.isEmpty else { return nil }
    clips[id] = clip
    return clip
  }
}

/// Only advances while an idle robot is visible. Screen sleep never queues overdue gags.
@MainActor
final class IdleDirector: ObservableObject {
  static weak var previewInstance: IdleDirector?
  static let basics = ["blink", "scan", "tilt", "nod", "stretch", "hop", "balance", "sneeze", "sleep"]
  @Published var action: String? = "blink"
  @Published var began = Date()
  @Published var asleep = false
  private(set) var currentDuration: Double = 7
  static func restDuration() -> Double { Double.random(in: 5...10) }
  private var timer: Timer?
  private var nextBasic = Date()
  private var nextRare = Date()
  private var previous = "blink"
  private var blendFrom: IdleFrame?
  private var blendPrevious: IdleFrame?
  private var blendBegan = Date()
  private let blinkEpoch=Date()
  var animating: Bool { timer != nil || action != nil || blendFrom != nil }
  static func blinkClosure(at elapsed:Double) -> Double {
    let durations=[3.7,4.9,3.2,4.6,4.1,3.5]
    let cycle=durations.reduce(0,+)
    var phase=max(0,elapsed).truncatingRemainder(dividingBy:cycle)
    for duration in durations {
      if phase < duration {
        let t=phase-(duration-0.28)
        guard t >= 0 else { return 0 }
        return t < 0.09 ? IdleInterpolation.smooth(t/0.09) : 1-IdleInterpolation.smooth((t-0.09)/0.19)
      }
      phase-=duration
    }
    return 0
  }
  func displayFrame(at now:Date)->IdleFrame? {
    guard var f=frame(at:now) else { return nil }
    guard !reduceMotion,action != "sleep",action != "blink",action != "sneeze" else { return f }
    let close=Self.blinkClosure(at:now.timeIntervalSince(blinkEpoch))
    f.eyes=f.eyes.map { eye in var e=eye;e.h=max(0.5,e.h*(1-0.95*close));e.r=min(e.r,e.h/2);return e }
    return f
  }
  func frame(at now: Date) -> IdleFrame? {
    guard let neutral=IdleLibrary.shared.clip("blink")?.frames.first else { return nil }
    var target=neutral
    if let id=action,let clip=IdleLibrary.shared.clip(id) {
      let elapsed=max(0,now.timeIntervalSince(began))
      let position=min(elapsed*clip.fps,Double(clip.frames.count-1))
      target=IdleInterpolation.sample(clip,at:position)
      if id == "dance" {
        let weight=IdleInterpolation.smooth(min(elapsed/0.35,(currentDuration-elapsed)/0.45))
        target=IdleInterpolation.mix(neutral,target,weight)
      }
    }
    if let source=blendFrom {
      let elapsed=max(0,now.timeIntervalSince(blendBegan))
      let moving=IdleInterpolation.carry(source,previous:blendPrevious,seconds:0.06*(1-exp(-elapsed/0.06)))
      return IdleInterpolation.mix(moving,target,IdleInterpolation.smooth(elapsed/0.35))
    }
    return target
  }
  private func beginBlend(from source: IdleFrame?, at now: Date) {
    let previous=frame(at:now.addingTimeInterval(-1.0/240))
    blendPrevious=previous;blendFrom=source;blendBegan=now
  }

  var automaticActions = true
  private var sequence = 0
  private var observers: [NSObjectProtocol] = []
  var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
  func start(playImmediately: Bool = true) {
    Self.previewInstance = self
    guard timer == nil else { return }
    blendFrom = nil
    currentDuration = IdleLibrary.shared.clip("blink")?.duration ?? 7
    began = Date(); action = reduceMotion || !playImmediately ? nil : "blink"
    schedule(from: began)
    let nc = NSWorkspace.shared.notificationCenter
    observers = [nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.asleep = true; self?.action = nil }
    }, nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in guard let self else { return }; self.asleep = false; self.schedule(from: Date()) }
    }]
    timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick(Date()) }
    }
  }
  private func schedule(from date: Date) {
    nextBasic = date.addingTimeInterval(Self.restDuration())
    nextRare = date.addingTimeInterval(Double.random(in: 1200...2400))
  }
  func tick(_ now: Date) {
    guard !asleep, !reduceMotion else { blendFrom = nil; action = nil; return }
    if blendFrom != nil && now.timeIntervalSince(blendBegan) >= 0.35 { blendFrom = nil; objectWillChange.send() }
    if action != nil {
      let duration = currentDuration
      if now.timeIntervalSince(began) >= duration { let source=frame(at:now); beginBlend(from:source,at:now); self.action = nil; nextBasic = now.addingTimeInterval(Self.restDuration()) }
      return
    }
    guard automaticActions else { return }
    if now >= nextRare {
      play("dance"); nextRare = now.addingTimeInterval(Double.random(in: 1200...2400))
    } else if now >= nextBasic {
      play(Self.basics.filter { $0 != previous }.randomElement() ?? "blink")
    }
  }
  func play(_ id: String, at now: Date = Date()) {
    guard !asleep, !reduceMotion else { return }
    guard IdleLibrary.shared.clip(id) != nil else { return }
    let source=frame(at:now)
    beginBlend(from:source,at:now)
    currentDuration = id == "dance" ? Double.random(in: 3...5) : (IdleLibrary.shared.clip(id)?.duration ?? 7)
    previous = id; began = now; action = id
    if id == "dance" { nextRare = began.addingTimeInterval(Double.random(in: 1200...2400)) }
  }
  func resume(_ id: String, elapsed: Double, from source: IdleFrame? = nil) {
    guard !reduceMotion, !asleep else { return }
    beginBlend(from:source,at:Date()); blendPrevious=source
    currentDuration = id == "dance" ? Double.random(in: 3...5) : (IdleLibrary.shared.clip(id)?.duration ?? 7)
    previous = id; action = id; began = Date().addingTimeInterval(-elapsed)
  }
  func tryNext() { play(Self.basics[sequence % Self.basics.count]); sequence += 1 }
  func stop() {
    if Self.previewInstance === self { Self.previewInstance = nil }
    timer?.invalidate(); timer = nil; action = nil; blendFrom = nil
    for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    observers.removeAll()
  }
}

struct IdleRobotCanvas: View {
  let clip: IdleClip?
  let elapsed: Double
  var visibility: Double = 1
  var entering: Bool = false
  var entryColor: Int? = nil
  var exitColor: Int = 0x4d6bfe
  private func color(_ rgb: Int) -> Color {
    Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
  }
  var body: some View {
    let neutralFrame = IdleLibrary.shared.clip("blink")?.frames.first
    return Canvas { context, size in
      guard let clip, !clip.frames.isEmpty else { return }
      // Sampled vector paths are interpolated at display cadence, never enlarged bitmaps.
      let position = min(max(0, elapsed * clip.fps), Double(clip.frames.count - 1))
      let index = Int(position), amount = position - Double(index)
      let a = clip.frames[index], b = clip.frames[min(index + 1, clip.frames.count - 1)]
      let edge = clip.duration > 10 ? min(1, max(0, min(elapsed / 0.35, (clip.duration - elapsed) / 0.45))) : 1
      let danceBlend = edge * edge * (3 - 2 * edge)
      func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * amount }
      func mixedColor(_ x: Int, _ y: Int) -> Color {
        Color(red: mix(Double((x >> 16) & 255), Double((y >> 16) & 255)) / 255,
              green: mix(Double((x >> 8) & 255), Double((y >> 8) & 255)) / 255,
              blue: mix(Double(x & 255), Double(y & 255)) / 255)
      }
      context.translateBy(x: size.width / 2, y: size.height / 2)
      context.scaleBy(x: 40.0 / 280.0, y: 40.0 / 280.0)
      var centerX = 0.0, centerY = 0.0
      for i in a.points.indices {
        let n = neutralFrame?.points[i] ?? a.points[i]
        centerX += mix(a.points[i][0], b.points[i][0]) * danceBlend + n[0] * (1-danceBlend)
        centerY += mix(a.points[i][1], b.points[i][1]) * danceBlend + n[1] * (1-danceBlend)
      }
      centerX /= Double(a.points.count); centerY /= Double(a.points.count)
      var bodyPath = Path()
      for i in a.points.indices {
        let q = a.points[i], r = b.points[i]
        let n = neutralFrame?.points[i] ?? q
        let x = mix(q[0], r[0]) * danceBlend + n[0] * (1 - danceBlend)
        let y = mix(q[1], r[1]) * danceBlend + n[1] * (1 - danceBlend)
        let angle = atan2(y - centerY, x - centerX)
        let radius = (entering ? 9.5:5.7) * 280.0 / 40.0
        let point = CGPoint(x: x * visibility + cos(angle) * radius * (1 - visibility),
                            y: y * visibility + sin(angle) * radius * (1 - visibility))
        if i == 0 { bodyPath.move(to: point) } else { bodyPath.addLine(to: point) }
      }
      bodyPath.closeSubpath()
      // Dance begins and ends through the neutral body, retaining original bounce speed.
      let pigment = mixedColor(a.body, b.body)
      var filled = context
      filled.opacity = entering ? 1 : max(0, (visibility - 0.30) / 0.70)
      let entryBlend=visibility
      let origin=entryColor ?? 0x4d6bfe
      func entryChannel(_ shift:Int,_ end:Double)->Double { (Double((origin >> shift)&255)*(1-entryBlend)+end*entryBlend)/255 }
      let entryInk=Color(red:entryChannel(16,229),green:entryChannel(8,229),blue:entryChannel(0,231))
      filled.fill(bodyPath, with: .color(entering ? entryInk : color(0xe5e5e7)))
      var painted = filled; painted.opacity *= danceBlend * (entering ? entryBlend:1); painted.fill(bodyPath, with: .color(pigment))
      if !entering && visibility < 1 {
        var outline = context; outline.opacity = min(1, (1 - visibility) * 3) * min(1, visibility * 4)
        func inkChannel(_ shift: Int, _ neutral: Double, _ blue: Double) -> Double {
          let current = mix(Double((a.body >> shift) & 255), Double((b.body >> shift) & 255)) * danceBlend + neutral * (1-danceBlend)
          return (current * visibility + Double((exitColor >> shift)&255) * (1-visibility))/255
        }
        let ink = Color(red: inkChannel(16,229,77), green: inkChannel(8,229,107), blue: inkChannel(0,231,254))
        outline.stroke(bodyPath, with: .color(ink), lineWidth: 1.7 * 280/40)
      }
      context.clip(to: bodyPath)
      for i in a.eyes.indices where i < b.eyes.count {
        let rawE = a.eyes[i], rawF = b.eyes[i]
        let neutral = neutralFrame?.eyes[i] ?? rawE
        func blendEye(_ v: IdleEye) -> IdleEye {
          func blend(_ x: Double, _ n: Double) -> Double { x*danceBlend+n*(1-danceBlend) }
          return IdleEye(x:blend(v.x,neutral.x),y:blend(v.y,neutral.y),w:blend(v.w,neutral.w),h:blend(v.h,neutral.h),r:blend(v.r,neutral.r),angle:blend(v.angle,neutral.angle),opacity:blend(v.opacity,neutral.opacity))
        }
        let e = blendEye(rawE), f = blendEye(rawF)
        var eyeContext = context
        eyeContext.translateBy(x: mix(e.x, f.x) * visibility, y: mix(e.y, f.y) * visibility)
        eyeContext.rotate(by: .degrees(mix(e.angle, f.angle)))
        eyeContext.opacity = mix(e.opacity, f.opacity) * max(0, min(1, (visibility - 0.60) / 0.40))
        let w = mix(e.w, f.w), h = mix(e.h, f.h), r = mix(e.r, f.r)
        eyeContext.fill(Path(roundedRect: CGRect(x: -w/2, y: -h/2, width: w, height: h), cornerRadius: r), with: .color(mixedColor(a.eye, b.eye)))
      }
    }
    .allowsHitTesting(false)
  }
}

struct RobotDeparture {
  let progress:Double
  static let duration=1.22
  private var robotProgress:Double { progress*Self.duration/0.9 }
  var scale:Double { 1-0.94*IdleInterpolation.smooth((robotProgress-0.48)/0.20) }
  var opacity:Double { 1-IdleInterpolation.smooth((robotProgress-0.68)/0.06) }
  var statusOpacity:Double { IdleInterpolation.smooth((robotProgress-0.68)/0.06) }
  var statusScale:Double { min(1,max(0,(progress*Self.duration-0.666)/(Self.duration-0.666))) }
}

@MainActor
final class IdlePresence: ObservableObject {
  @Published var visibility: Double = 1
  var returnColor: Int = 0x4d6bfe
  @Published var entering = true
  @Published var transitioning = false
  @Published var departureProgress = 1.0
  private var transitionAt=Date()
  private var transitionIdle=true
  private var blendReversal=false
  func presentedFrame(at now:Date)->IdleFrame? {
    guard transitioning,let clip=IdleLibrary.shared.clip(transitionIdle ? "cube-in":"satellite-out") else { return coastFrame(at:now) }
    let elapsed=max(0,now.timeIntervalSince(transitionAt))
    let target=IdleInterpolation.sample(clip,at:elapsed*clip.fps)
    guard (!transitionIdle || blendReversal),let source=coastFrame(at:now) else { return target }
    return IdleInterpolation.mix(source,target,IdleInterpolation.smooth(elapsed/0.22))
  }
  var frozenFrame: IdleFrame?
  var frozenID = "blink"
  var frozenElapsed = 0.0
  private var frozenPrevious: IdleFrame?
  private var frozenAt=Date()
  func coastFrame(at now:Date)->IdleFrame? {
    guard let frozenFrame else { return nil }
    let t=max(0,now.timeIntervalSince(frozenAt))
    return IdleInterpolation.carry(frozenFrame,previous:frozenPrevious,seconds:0.06*(1-exp(-t/0.06)))
  }
  private var timer: Timer?
  private var generation = 0
  func set(_ idle: Bool, director: IdleDirector, animated: Bool = true) {
    let reversing=transitioning
    if reversing { frozenFrame=presentedFrame(at:Date());frozenPrevious=nil;frozenAt=Date() }
    blendReversal=reversing
    timer?.invalidate(); timer = nil
    generation += 1; let current = generation
    if !idle {
      if visibility >= 1 && !blendReversal {
      frozenAt=Date()
      frozenPrevious=director.displayFrame(at:frozenAt.addingTimeInterval(-1.0/240))
      frozenFrame = director.displayFrame(at:frozenAt)
      frozenID = director.action ?? "blink"
      frozenElapsed = director.action == nil ? 0 : max(0, Date().timeIntervalSince(director.began))
      }
      director.stop()
    } else {
      frozenFrame=coastFrame(at:Date());frozenPrevious=nil
      director.start(playImmediately: false)
      // Continue the same geometry when a partially completed transition reverses.
      if visibility == 0 { frozenID = "blink"; frozenElapsed = 0; frozenFrame = IdleLibrary.shared.clip("blink")?.frames.first }
    }
    // Preserve circle geometry when reversing mid-flight.
    if !blendReversal { entering = idle }
    let start = visibility, end = idle ? 1.0 : 0.0
    transitionAt=Date();transitionIdle=idle;transitioning=animated
    if !idle { departureProgress=animated ? 0:1 }

    guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { transitioning=false;visibility=end;entering=idle;return }
    let began = ProcessInfo.processInfo.systemUptime
    timer = Timer.scheduledTimer(withTimeInterval: 1/60.0, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.generation == current else { return }
        let t = min(1, (ProcessInfo.processInfo.systemUptime - began) / (idle ? 1.05 : RobotDeparture.duration))
        if !idle { self.departureProgress=t }
        let smooth = idle ? IdleInterpolation.smooth(t/0.32) : IdleInterpolation.smooth((t-0.68)/0.32)
        self.visibility = start + (end-start)*smooth
        if t >= 1 {
          self.finishTransition(director: director)
        }
      }
    }
  }
  func finishTransition(director: IdleDirector) {
    timer?.invalidate(); timer=nil; generation += 1
    let final=presentedFrame(at:Date())
    // A tiny positive residue still paints a solid origin disk on entering.
    // Set the exact endpoint and invalidate queued ticks after a reversal.
    visibility=transitionIdle ? 1:0
    entering=transitionIdle
    if !transitionIdle { departureProgress=1 }
    transitioning=false
    if transitionIdle { director.resume("blink", elapsed:0, from:final) }
  }
  func showsRobot(whenIdle idle: Bool) -> Bool { idle || visibility > 0.0001 }
  func stop() { generation += 1; timer?.invalidate(); timer = nil }
}

struct IdleStatusSlot: View {
  @ObservedObject var model: BoardModel
  @StateObject private var director = IdleDirector()
  @StateObject private var presence = IdlePresence()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var idle: Bool { model.showsIdleRobot }
  private var hasStatus: Bool { model.orbitLayout.total > 0.0001 || model.anyFailed || model.completedUnreadCount > 0 || model.busyCount > 0 || model.statusFlight != nil }
  var body: some View {
    let departing = presence.transitioning && !presence.entering
    let departure = RobotDeparture(progress:presence.departureProgress)
    ZStack {
      if hasStatus {
        StatusOrbitView(model: model,workReveal:departing ? departure.statusScale:1)
          .opacity(departing ? departure.statusOpacity:1-presence.visibility)
      }
      if presence.showsRobot(whenIdle: idle) {
        TimelineView(.animation(minimumInterval: 1/60.0, paused: (!director.animating && !presence.transitioning && presence.visibility >= 1) || director.asleep || reduceMotion)) { timeline in
          let stable = idle && !presence.transitioning
          let frame = stable ? director.displayFrame(at: timeline.date) : presence.presentedFrame(at:timeline.date)
          let sampled = frame.map { IdleClip(fps:1,duration:7,frames:[$0]) }
          IdleRobotCanvas(clip: sampled, elapsed: 0, visibility: departing ? 1:presence.visibility, entering: presence.entering, entryColor:presence.returnColor,exitColor:model.needsAction ? 0xf2ff14:0x4d6bfe)
        }
        .frame(width: 30, height: 42)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .scaleEffect(departing ? departure.scale:1)
        .opacity(departing ? departure.opacity:1)
        .accessibilityLabel("待机机器人")
        .contextMenu {
          if idle {
            Button("试试下一个待机动作") { director.tryNext() }
            Button("播放变色跳舞彩蛋") { director.play("dance") }
          }
        }
      }
    }
    .frame(height: !hasStatus && !idle ? 0 : nil)
    .onAppear { presence.set(idle, director: director, animated: false) }
    .onChange(of: idle) { _, value in
      if value { presence.returnColor=model.orbitLayout.decision > 0.1 ? 0xf2ff14:model.retainedFailureCount > 0 ? 0xff4000:model.retainedSuccessCount > 0 ? 0x34c759:0x4d6bfe }
      presence.set(value, director: director)
    }
    .onChange(of: presence.transitioning) { _, value in
      model.recordIdleTransition(entering: presence.entering, transitioning: value, visibility: presence.visibility)
    }
    .onDisappear { presence.stop(); director.stop() }
  }
}
