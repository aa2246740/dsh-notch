import SwiftUI
import AppKit
import CoreText

struct OrbitLayout: Equatable {
  var top: Double = 0
  var middle: Double = 0
  var bottom: Double = 0
  var decision: Double = 0
  var total: Double { top+middle+bottom+decision }
  var height: CGFloat { 20+28*max(0,total-1) }
  var middleY: CGFloat { 10+28*(top+max(0,decision+middle-1)) }
  var bottomY: CGFloat { height-10 }
  static func mix(_ a:Self,_ b:Self,_ t:Double)->Self {
    Self(top:a.top+(b.top-a.top)*t,middle:a.middle+(b.middle-a.middle)*t,bottom:a.bottom+(b.bottom-a.bottom)*t,decision:a.decision+(b.decision-a.decision)*t)
  }
  static func flight(from a:Self,to b:Self,progress:Double,flight:StatusFlight)->Self {
    let growth=OrbitMotionFrame.ease(progress/0.48)
    var result=mix(a,b,growth)
    if !flight.returnsToRunning {
      let source=OrbitMotionFrame(progress:progress,failed:flight.failed,returns:false,angle:flight.angle).sourceOpacity
      // Existing result: close the vacated slot as ink leaves it. A new result
      // first needs room for its drawn circle, then releases the source slot.
      let remaining=flight.destinationBefore > 0 ? source:1-OrbitMotionFrame.ease((progress-0.72)/0.28)
      result.middle=max(a.middle,1)*remaining
    }
    return result
  }
}

enum StatusOutcome {
  case success, failure, decision
  var rgb: (Double, Double, Double) {
    switch self {
    case .success: (0.204, 0.780, 0.349)
    case .failure: (1.0, 0.251, 0.0)
    case .decision: (0.949, 1.0, 0.078)
    }
  }
  var color: Color { let c=rgb; return Color(red:c.0,green:c.1,blue:c.2) }
}

struct StatusFlight: Identifiable {
  let id = UUID()
  let outcome: StatusOutcome
  var failed: Bool { outcome == .failure }
  var decision: Bool { outcome == .decision }
  let startedAt: Date
  let busyBefore: Int
  let destinationBefore: Int
  let returnsToRunning: Bool
  let angle: Double
  init(failed: Bool, startedAt: Date, busyBefore: Int, destinationBefore: Int, returnsToRunning: Bool = true, angle:Double? = nil) {
    self.init(outcome:failed ? .failure:.success,startedAt:startedAt,busyBefore:busyBefore,destinationBefore:destinationBefore,returnsToRunning:returnsToRunning,angle:angle)
  }
  init(outcome: StatusOutcome, startedAt: Date, busyBefore: Int, destinationBefore: Int, returnsToRunning: Bool = true, angle:Double? = nil) {
    self.outcome = outcome
    self.startedAt = startedAt
    self.busyBefore = busyBefore
    self.destinationBefore = destinationBefore
    self.returnsToRunning = returnsToRunning
    self.angle=angle ?? startedAt.timeIntervalSinceReferenceDate*2 * .pi/3
  }
  static let duration: TimeInterval = 0.95
}

/// A reply returns the same task to the running lamp. It owns a clock so
/// polling and panel folding cannot reset its ink, count, or layout progress.
struct DecisionReturn: Identifiable {
  let id = UUID()
  let startedAt: Date
  let busyBefore: Int
  let from: OrbitLayout
  let angle: Double
  var travelling: Bool { from.middle > 0.001 || from.top > 0.001 }
  var duration: Double { travelling ? StatusFlight.duration:DecisionMorph.resumeDuration }
  func progress(at now:Date)->Double { min(1,max(0,now.timeIntervalSince(startedAt)/duration)) }
}

struct DecisionReturnFrame {
  let progress: Double
  let distance: CGFloat
  let tailLength: CGFloat
  let tint: Double
  let fill: Double
  let strokeOpacity: Double
  let countMix: Double
  let collapse: Double
  let baseRingOpacity: Double
  init(progress:Double,angle:Double) {
    let p=min(1,max(0,progress));self.progress=p
    let route=OrbitBrushRoute(failed:false,angle:angle)
    let u=min(1,max(0,(p-0.14)/0.86))
    let span=route.total-route.resultDrawn
    let terminal=9.5*DecisionSpin.runningVelocity*StatusFlight.duration*0.86/span
    let paced=(3*u*u-2*u*u*u)+terminal*(u*u*u-u*u)
    distance=route.resultDrawn+span*paced
    let leaving=OrbitMotionFrame.ease((distance-route.resultDrawn)/max(1,route.returned-route.resultDrawn))
    let joined=OrbitMotionFrame.ease((distance-route.returned)/max(1,route.total-route.returned))
    tailLength=(2 * .pi*9.5)+(18-2 * .pi*9.5)*leaving+(route.departure-18)*joined
    tint=1-leaving
    fill=1-OrbitMotionFrame.ease(p/0.28)
    strokeOpacity=OrbitMotionFrame.ease(p/0.14)
    countMix=joined
    collapse=OrbitMotionFrame.ease((p-0.35)/0.65)
    // The existing ring keeps rotating while the incoming tip approaches it;
    // the travelling trail becomes that same ring at the final phase/velocity.
    baseRingOpacity=1-OrbitMotionFrame.ease((leaving-0.55)/0.45)
  }
}

struct DecisionReturnStroke: Shape {
  let frame:DecisionReturnFrame
  let angle:Double
  let gap:CGFloat
  func path(in rect:CGRect)->Path {
    let route=OrbitBrushRoute(failed:false,angle:angle,gap:gap)
    let original=OrbitBrushRoute(failed:false,angle:angle)
    let source=[original.arrival,original.resultDrawn,original.returned,original.total]
    let target=[route.arrival,route.resultDrawn,route.returned,route.total]
    func mapped(_ d:CGFloat)->CGFloat {
      for i in 1..<source.count where d <= source[i] {
        return target[i-1]+(target[i]-target[i-1])*(d-source[i-1])/max(0.00001,source[i]-source[i-1])
      }
      return route.total
    }
    return route.path(in:mapped(frame.distance-frame.tailLength)...mapped(frame.distance))
      .offsetBy(dx:rect.midX,dy:rect.midY)
  }
}

struct OrbitMotionFrame {
  let progress: Double
  let failed: Bool
  let returns: Bool
  let distance: CGFloat
  let tailLength: CGFloat
  let tint: Double
  let resultOpacity: Double
  let sourceOpacity: Double
  let arrived: Bool
  let returning: Bool
  let returned: Bool
  static func ease(_ value: Double) -> Double {
    let t = min(1, max(0, value))
    return t * t * (3 - 2 * t)
  }
  private static func pacedHead(_ t:Double,_ values:[CGFloat])->CGFloat {
    let times=[0.0,0.18,0.56,0.94,1.0]
    func slope(_ i:Int)->CGFloat {
      guard i > 0 && i < 4 else { return 0 }
      let a=(values[i]-values[i-1])/(times[i]-times[i-1])
      let b=(values[i+1]-values[i])/(times[i+1]-times[i])
      return a*b > 0 ? 2*a*b/(a+b):0
    }
    let i=(0..<4).first { t <= times[$0+1] } ?? 3
    let dt=times[i+1]-times[i],u=min(1,max(0,(t-times[i])/dt)),u2=u*u,u3=u2*u
    return (2*u3-3*u2+1)*values[i]+(u3-2*u2+u)*dt*slope(i)+(-2*u3+3*u2)*values[i+1]+(u3-u2)*dt*slope(i+1)
  }
  init(progress: Double, failed: Bool, returns: Bool, angle: Double = 0) {
    self.progress = min(1, max(0, progress))
    self.failed = failed
    self.returns = returns
    let route = OrbitBrushRoute(failed: failed, angle: angle)
    let end = returns ? route.total : route.resultDrawn + 18
    let u=self.progress
    let terminal=9.5*DecisionSpin.runningVelocity*StatusFlight.duration/(end-route.departure)
    let paced=(3*u*u-2*u*u*u)+terminal*(u-3*u*u+2*u*u*u)
    let head = returns ? route.departure + (end - route.departure) * paced : Self.pacedHead(self.progress,[route.departure,route.sourceExit,route.arrival,route.resultDrawn,route.resultDrawn+18])
    distance = min(head, returns ? route.total : route.resultDrawn)
    let outbound = Self.ease((head - route.sourceExit) / (route.arrival - route.sourceExit))
    let inbound = Self.ease((head - route.resultDrawn + 8) / (route.returned - route.resultDrawn + 16))
    let tintStart = max(route.departure, route.sourceExit - 8)
    let outgoingTint = Self.ease((head - tintStart) / (route.arrival + 8 - tintStart))
    tint = returns && head > route.resultDrawn - 8 ? 1 - inbound : outgoingTint
    resultOpacity = Self.ease((head - route.arrival - 0.55 * (route.resultDrawn - route.arrival)) / (0.35 * (route.resultDrawn - route.arrival)))
    arrived = resultOpacity > 0
    returning = returns && head > route.resultDrawn
    returned = returns && head >= route.returned
    sourceOpacity = returns ? 1 : 1 - outbound
    if head < route.arrival { tailLength = route.departure + (18 - route.departure) * outbound }
    else if !returns && head > route.resultDrawn { tailLength = max(0, 18 - (head - route.resultDrawn)) }
    else if head > route.returned {
      let t = (head - route.returned) / (route.total - route.returned)
      tailLength = 18 + (route.departure - 18) * (3*t*t-2*t*t*t)
    } else { tailLength = 18 }
  }
}

/// An arc-length trail: the head draws forward and the tail follows on the same route.
struct OrbitBrushRoute {
  private(set) var points: [CGPoint] = []
  private(set) var lengths: [CGFloat] = []
  private(set) var departure: CGFloat = 0
  private(set) var sourceExit: CGFloat = 0
  private(set) var arrival: CGFloat = 0
  private(set) var resultDrawn: CGFloat = 0
  private(set) var returned: CGFloat = 0
  var total: CGFloat { lengths.last ?? 0 }

  init(failed: Bool, angle: Double, gap: CGFloat = 28) {
    let r: CGFloat = 9.5
    let direction: CGFloat = failed ? 1 : -1
    let y = direction * gap
    arc(center: .zero, from: angle, sweep: 1.4 * .pi, radius: r)
    departure = total
    let exitAngle = failed ? Double.pi / 2 : -Double.pi / 2
    let sourceHead = angle + 1.4 * .pi
    let extra = (exitAngle - sourceHead).truncatingRemainder(dividingBy: 2 * .pi)
    arc(center: .zero, from: sourceHead, sweep: extra < 0 ? extra + 2 * .pi : extra, radius: r)
    sourceExit = total
    let start = points.last!
    curve(from: start, c1: CGPoint(x: start.x - 4 * sin(exitAngle), y: start.y + 4 * cos(exitAngle)),
          c2: CGPoint(x: -r, y: y + 10), to: CGPoint(x: -r, y: y))
    arrival = total
    arc(center: CGPoint(x: 0, y: y), from: .pi, sweep: 2 * .pi, radius: r)
    resultDrawn = total
    let finalAngle = angle + StatusFlight.duration * 2 * .pi / 3
    let end = CGPoint(x: r * cos(exitAngle), y: r * sin(exitAngle))
    curve(from: points.last!, c1: CGPoint(x: -r, y: y - 10),
          c2: CGPoint(x: end.x + 4 * sin(exitAngle), y: end.y - 4 * cos(exitAngle)), to: end)
    returned = total
    let resume = (finalAngle - exitAngle).truncatingRemainder(dividingBy: 2 * .pi)
    arc(center: .zero, from: exitAngle, sweep: (resume < 0 ? resume + 2 * .pi : resume) + 1.4 * .pi, radius: r)
  }

  func range(for frame: OrbitMotionFrame) -> ClosedRange<CGFloat> {
    max(0, frame.distance - frame.tailLength)...frame.distance
  }

  func path(in range: ClosedRange<CGFloat>) -> Path {
    var path = Path()
    guard range.upperBound - range.lowerBound > 0.01 else { return path }
    var began = false
    for i in 1..<points.count {
      let a = lengths[i - 1], b = lengths[i]
      guard b > a, b >= range.lowerBound, a <= range.upperBound else { continue }
      let lo = max(a, range.lowerBound), hi = min(b, range.upperBound)
      func point(_ d: CGFloat) -> CGPoint {
        let t = (d - a) / (b - a)
        return CGPoint(x: points[i-1].x + (points[i].x-points[i-1].x)*t,
                       y: points[i-1].y + (points[i].y-points[i-1].y)*t)
      }
      if !began { path.move(to: point(lo)); began = true }
      path.addLine(to: point(hi))
    }
    return path
  }

  private mutating func append(_ point: CGPoint) {
    let distance = points.last.map { hypot(point.x - $0.x, point.y - $0.y) } ?? 0
    lengths.append(total + distance)
    points.append(point)
  }
  private mutating func arc(center: CGPoint, from: Double, sweep: Double, radius: CGFloat) {
    for i in 0...96 {
      let a = from + sweep * Double(i) / 96
      append(CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a)))
    }
  }
  private mutating func curve(from: CGPoint, c1: CGPoint, c2: CGPoint, to: CGPoint) {
    for i in 1...64 {
      let t = CGFloat(i) / 64, u = 1 - t
      append(CGPoint(x: u*u*u*from.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*to.x,
                     y: u*u*u*from.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*to.y))
    }
  }
}

struct OrbitStroke: Shape {
  let frame: OrbitMotionFrame
  let angle: Double
  var gap: CGFloat = 28
  func path(in rect: CGRect) -> Path {
    let route = OrbitBrushRoute(failed: frame.failed, angle: angle, gap:gap)
    let canonical=OrbitBrushRoute(failed:frame.failed,angle:angle)
    let source=[CGFloat(0),canonical.departure,canonical.sourceExit,canonical.arrival,canonical.resultDrawn,canonical.returned,canonical.total]
    let dest=[CGFloat(0),route.departure,route.sourceExit,route.arrival,route.resultDrawn,route.returned,route.total]
    func map(_ d:CGFloat)->CGFloat {
      for i in 1..<source.count where d <= source[i] {
        let w=(d-source[i-1])/max(0.00001,source[i]-source[i-1])
        return dest[i-1]+w*(dest[i]-dest[i-1])
      }
      return route.total
    }
    let range=canonical.range(for:frame)
    return route.path(in: map(range.lowerBound)...map(range.upperBound)).offsetBy(dx: rect.midX, dy: rect.midY)
  }
}

struct DecisionSpin {
  let began:Date
  let angle:Double
  let initialVelocity:Double
  let finalVelocity:Double
  var delay:Double = 0
  static let duration=0.62
  static let runningVelocity=2 * Double.pi/3
  func velocity(at now:Date)->Double {
    let u=min(1,max(0,(now.timeIntervalSince(began)-delay)/Self.duration))
    return initialVelocity+(finalVelocity-initialVelocity)*(3*u*u-2*u*u*u)
  }
  func position(at now:Date)->Double {
    let elapsed=max(0,now.timeIntervalSince(began)-delay),t=min(elapsed,Self.duration),u=t/Self.duration
    return angle+initialVelocity*t+(finalVelocity-initialVelocity)*Self.duration*(u*u*u-0.5*u*u*u*u)+finalVelocity*max(0,elapsed-Self.duration)
  }
}
struct DecisionMorph {
  let amount:Double
  private var q:Double { min(1,max(0,amount)) }
  private var p:Double { 1-q }
  static let resumeDuration=0.98
  private static let clearFraction=0.28/resumeDuration
  var draw:Double {
    let u=min(1,max(0,(p-Self.clearFraction)/(1-Self.clearFraction)))
    let terminal=DecisionSpin.runningVelocity*(Self.resumeDuration-0.28)/(2 * Double.pi*0.70)
    // Integrate a monotone smoothstep velocity: acceleration also reaches zero at handoff.
    return (2-terminal)*u+(2*terminal-2)*(u*u*u-0.5*u*u*u*u)
  }
  var fill:Double { 1-IdleInterpolation.smooth((p-0.02)/(Self.clearFraction-0.02)) }
  var flip:Double { 1-IdleInterpolation.smooth(p/Self.clearFraction) }
  var trim:Double { 0.70*draw }
}

struct DecisionClosing {
  static let duration=0.82
  let amount:Double
  var trim:Double { 0.70+0.30*IdleInterpolation.smooth(amount/0.5) }
  var fill:Double { IdleInterpolation.smooth((amount-0.50)/0.38) }
  var tint:Double { IdleInterpolation.smooth((amount-0.24)/0.55) }
  var flip:Double { IdleInterpolation.smooth((amount-0.62)/0.38) }
}

/// Center visible ink, excluding font side bearings and baseline line-box padding.
@MainActor enum CenteredStatusGlyph {
  private static var cache:[String:Path]=[:]
  static func path(_ text:String)->Path {
    if let cached=cache[text] { return cached }
    let base=NSFont.systemFont(ofSize:10,weight:.bold)
    let font=NSFont(descriptor:base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor,size:10) ?? base
    let ct=CTFontCreateWithName(font.fontName as CFString,10,nil)
    let chars=Array(text.utf16)
    var glyphs=[CGGlyph](repeating:0,count:chars.count)
    CTFontGetGlyphsForCharacters(ct,chars,&glyphs,chars.count)
    var advances=[CGSize](repeating:.zero,count:glyphs.count)
    CTFontGetAdvancesForGlyphs(ct,.horizontal,glyphs,&advances,glyphs.count)
    let combined=CGMutablePath();var x=0.0
    for (i,glyph) in glyphs.enumerated() {
      if let outline=CTFontCreatePathForGlyph(ct,glyph,nil) {
        combined.addPath(outline,transform:CGAffineTransform(translationX:x,y:0))
      }
      x+=advances[i].width
    }
    let bounds=combined.boundingBoxOfPath
    guard !bounds.isEmpty else { return Path() }
    let scale=min(1,12/bounds.width)
    let transform=CGAffineTransform(a:scale,b:0,c:0,d:-scale,tx:-bounds.midX*scale,ty:bounds.midY*scale)
    var result=Path();result.addPath(Path(combined),transform:transform)
    if text == "!" {
      // The long stem carries more ink than the dot: align optical mass, not just bounds.
      let ink=result.boundingRect,step=0.04
      var sumY=0.0,count=0.0
      for y in stride(from:ink.minY+step/2,to:ink.maxY,by:step) {
        for x in stride(from:ink.minX+step/2,to:ink.maxX,by:step) {
          if result.contains(CGPoint(x:x,y:y)) { sumY+=y;count+=1 }
        }
      }
      if count > 0 { result=result.applying(CGAffineTransform(translationX:0,y:-sumY/count)) }
    }
    cache[text]=result;return result
  }
}

/// Two halves hinge at the glyph's equator, like a split-flap calendar.
struct DecisionFlipGlyph:View {
  let number:Int
  let progress:Double
  let color:Color
  var body:some View {
    let numeral=CenteredStatusGlyph.path("\(number)")
    let mark=CenteredStatusGlyph.path("!")
    Canvas { context,size in
      func half(_ text:String,top:Bool,scale:Double,exposed:Double? = nil) {
        guard scale > 0.001 else { return }
        var c=context
        c.translateBy(x:size.width/2,y:size.height/2)
        if let exposed {
          let y=top ? -size.height/2:exposed
          let height=top ? size.height/2-exposed:size.height/2-exposed
          c.clip(to:Path(CGRect(x:-size.width/2,y:y,width:size.width,height:max(0,height))))
        }
        c.scaleBy(x:1,y:scale)
        c.clip(to:Path(CGRect(x:-size.width/2,y:top ? -size.height/2:0,width:size.width,height:size.height/2)))
        c.fill(text == "!" ? mark:numeral,with:.color(color))
      }
      if progress < 0.5 {
        let scale=max(0,cos(.pi*progress))
        half("!",top:true,scale:1,exposed:size.height/2*scale)
        half("\(number)",top:false,scale:1)
        half("\(number)",top:true,scale:scale)
      } else {
        let scale=max(0,cos(.pi*(1-progress)))
        half("!",top:true,scale:1)
        half("\(number)",top:false,scale:1,exposed:size.height/2*scale)
        half("!",top:false,scale:scale)
      }
    }.frame(width:19,height:19)
  }
}

struct DecisionDissolveGlyph:View {
  let number:Int
  let progress:Double
  let color:Color
  var body:some View {
    let numeral=CenteredStatusGlyph.path("\(number)"),mark=CenteredStatusGlyph.path("!")
    let t=min(1,max(0,progress))
    Canvas { context,size in
      context.translateBy(x:size.width/2,y:size.height/2)
      var old=context;old.opacity *= 1-t;old.fill(numeral,with:.color(color))
      var new=context;new.opacity *= t;new.fill(mark,with:.color(color))
    }.frame(width:19,height:19)
  }
}

/// Disappear before the two 19-point disks (plus stroke allowance) can touch.
struct StatusSeparation {
  static func opacity(weight:Double,distance:Double)->Double {
    weight*IdleInterpolation.smooth((distance-20)/8)
  }
}

struct WorkingDecisionGlyph:View {
  let amount:Double
  let number:Int
  let angle:Double
  var closing:Bool = false
  var body:some View {
    let m=DecisionMorph(amount:amount)
    let closed=DecisionClosing(amount:amount)
    let blue=NotchTokens.deepSeekBlue
    ZStack {
      if closing {
        let ink=Color(red:0.302+(0.949-0.302)*closed.tint,green:0.420+0.580*closed.tint,blue:0.996+(0.078-0.996)*closed.tint)
        Circle().fill(ink).scaleEffect(closed.fill)
        Circle().trim(from:0,to:closed.trim).stroke(ink,style:StrokeStyle(lineWidth:1.5,lineCap:.round)).rotationEffect(.radians(angle))
        DecisionDissolveGlyph(number:number,progress:closed.flip,color:Color(red:(0.302+(0.949-0.302)*closed.tint)*(1-closed.fill),green:(0.420+0.580*closed.tint)*(1-closed.fill),blue:(0.996+(0.078-0.996)*closed.tint)*(1-closed.fill)))
      } else {
      Circle().fill(NotchTokens.amber).opacity(m.fill)
      Circle().stroke(NotchTokens.amber,lineWidth:1.5).opacity(m.fill)
      Circle().trim(from:0,to:m.trim)
        .stroke(blue,style:StrokeStyle(lineWidth:1.5,lineCap:.round))
        .opacity(min(1,m.draw/0.03)).rotationEffect(.radians(angle))
      DecisionDissolveGlyph(number:number,progress:m.flip,color:Color(red:0.302*(1-m.fill),green:0.420*(1-m.fill),blue:0.996*(1-m.fill)))
      }
    }.frame(width:19,height:19)
  }
}

/// The robot's final point travels to the rim, becomes the pen, then resolves text.
struct StatusBirth {
  let progress:Double
  static let blueDrawDuration=(RobotDeparture.duration-0.666)*0.76
  static let bluePenVelocity=2 * Double.pi*0.70/blueDrawDuration
  var blueDraw:Double { min(1,max(0,(progress-0.24)/0.76)) }
  var travel:Double { IdleInterpolation.smooth(progress/0.24) }
  var draw:Double { IdleInterpolation.smooth((progress-0.24)/0.48) }
  var fill:Double { IdleInterpolation.smooth((progress-0.72)/0.18) }
  var text:Double { IdleInterpolation.smooth((progress-0.86)/0.14) }
}
struct StatusBirthGlyph:View {
  let progress:Double
  let decision:Bool
  let number:Int
  let angle:Double
  var body:some View {
    let m=StatusBirth(progress:progress)
    let ink=decision ? NotchTokens.amber:NotchTokens.deepSeekBlue
    let drawn=decision ? m.draw:m.blueDraw
    let length=(decision ? 1.0:0.70)*drawn
    ZStack {
      if decision { Circle().fill(ink).scaleEffect(m.fill) }
      Circle().trim(from:0,to:length)
        .stroke(ink,style:StrokeStyle(lineWidth:1.5,lineCap:.round))
        .rotationEffect(.radians(angle)).opacity(min(1,drawn/0.02))
      Circle().fill(ink).frame(width:1.5,height:1.5)
        .offset(x:cos(angle)*9.5*m.travel,y:sin(angle)*9.5*m.travel)
        .opacity(1-min(1,drawn/0.02))
      DecisionFlipGlyph(number:number,progress:decision ? 1:0,color:decision ? Color.black:ink)
        .opacity(decision ? m.text:m.blueDraw)
    }.frame(width:19,height:19)
  }
}

struct StatusOrbitView: View {
  @ObservedObject var model: BoardModel
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  var reduceMotionOverride: Bool? = nil
  /// Fixed presentation time for deterministic native frame capture.
  var renderDate: Date? = nil
  var workReveal:Double = 1
  private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

  private var layout: OrbitLayout { model.orbitLayout }
  private var showTop: Bool { layout.top > 0.0001 }
  private var showBottom: Bool { layout.bottom > 0.0001 }
  private var showMiddle: Bool { layout.middle > 0.0001 }
  private var totalHeight: CGFloat { layout.height }
  private var originY: CGFloat { layout.middleY }
  private var bottomY: CGFloat { layout.bottomY }

  private func clearance(_ weight:Double,_ y:Double,_ present:Bool)->Double {
    guard !present else { return weight }
    var neighbors:[Double]=[]
    if model.busyCount > 0 { neighbors.append(layout.middleY) }
    if model.completedUnreadCount > 0 { neighbors.append(10+28*layout.decision) }
    if !model.failedRows.isEmpty { neighbors.append(layout.bottomY) }
    if model.needsAction { neighbors.append(10) }
    guard let distance=neighbors.map({abs($0-y)}).min() else { return weight }
    return StatusSeparation.opacity(weight:weight,distance:distance)
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: model.visuallyDocked || reduceMotion || (model.busyCount == 0 && model.statusFlight == nil && !model.decisionSpinActive))) { context in
      let now = renderDate ?? context.date
      let flight = reduceMotion ? nil : model.statusFlight
      let progress = flight.map { now.timeIntervalSince($0.startedAt) / StatusFlight.duration } ?? 1
      let motion = flight.map { OrbitMotionFrame(progress: progress, failed: $0.failed, returns: $0.returnsToRunning, angle: $0.angle) }
      let angle = model.decisionAngle(at:now)
      let reply = reduceMotion ? nil:model.decisionReturn
      let replyProgress = reply?.progress(at:now) ?? 1
      let replyFrame = reply.map { DecisionReturnFrame(progress:replyProgress,angle:$0.angle) }
      let localReply = reply.map { !$0.travelling } ?? false
      let isolated = layout.top < 0.0001 && layout.bottom < 0.0001
      let morphing = localReply || (reply == nil && flight == nil && isolated && abs(layout.middle+layout.decision-1) < 0.001)
      ZStack(alignment: .topLeading) {
        if morphing {
          Group {
            if workReveal < 1 {
              StatusBirthGlyph(progress:workReveal,decision:model.needsAction,number:max(1,model.busyCount),angle:reduceMotion ? 0:angle)
            } else {
              WorkingDecisionGlyph(amount:localReply ? 1-replyProgress:layout.decision,number:max(1,max(model.busyCount,model.retainedBusyCount)),angle:reduceMotion ? 0:angle,closing:reply == nil && model.closingDecision)
            }
          }.position(x:15,y:10)
        }
        if layout.decision > 0.0001 && !morphing {
          ZStack {
            Circle().fill(NotchTokens.amber)
            DecisionFlipGlyph(number:1,progress:1,color:.black)
          }.frame(width:19,height:19)
            .scaleEffect(workReveal)
            .opacity(flight?.decision == true && flight?.destinationBefore == 0 ? (motion?.resultOpacity ?? 1):1)
            .opacity(reply?.travelling == true ? (replyFrame?.fill ?? 1):clearance(layout.decision,10,model.needsAction))
            .position(x:15,y:10)
        }
        if showTop {
          let count = flight?.outcome == .success && motion?.arrived == false ? flight!.destinationBefore : max(model.completedUnreadCount,model.retainedSuccessCount)
          statusDisk(count: count, color: NotchTokens.greenComplete, opacity: flight?.outcome == .success && flight?.destinationBefore == 0 ? (motion?.resultOpacity ?? 1) : 1)
            .position(x: 15, y: 10+28*layout.decision)
            .opacity(clearance(layout.top,10+28*layout.decision,model.completedUnreadCount > 0))
        }
        if showMiddle && !morphing {
          let count = flight != nil && motion?.returned == false ? flight!.busyBefore : model.orbitBusyCount
          ZStack {
            Circle().fill(Color.black).frame(width: 15, height: 15)
              .opacity(flight?.returnsToRunning == false ? (motion?.sourceOpacity ?? 1):1)
            if flight == nil && model.busyCount > 0 && (reply == nil || reply!.busyBefore > 0) {
              Circle().trim(from: 0, to: 0.70)
                .stroke(NotchTokens.deepSeekBlue, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.radians(reduceMotion ? 0 : angle))
                .opacity(replyFrame?.baseRingOpacity ?? 1)
            }
            if let reply, let replyFrame {
              DecisionFlipGlyph(number:reply.busyBefore,progress:0,color:NotchTokens.deepSeekBlue)
                .opacity(reply.busyBefore > 0 ? 1-replyFrame.countMix:0)
              DecisionFlipGlyph(number:model.busyCount,progress:0,color:NotchTokens.deepSeekBlue)
                .opacity(replyFrame.countMix)
            } else {
              DecisionFlipGlyph(number:count,progress:0,color:NotchTokens.deepSeekBlue)
                .opacity(count > 0 ? (motion?.sourceOpacity ?? 1) : 0)
            }
          }
          .frame(width: 19, height: 19)
          .scaleEffect(workReveal).opacity(layout.middle)
          .position(x: 15, y: originY)
        }
        if showBottom {
          let count = flight?.failed == true && motion?.arrived == false ? flight!.destinationBefore : max(model.failedRows.count,model.retainedFailureCount)
          statusDisk(count: count, color: NotchTokens.redFail, opacity: flight?.failed == true && flight?.destinationBefore == 0 ? (motion?.resultOpacity ?? 1) : 1)
            .position(x: 15, y: bottomY)
            .opacity(clearance(layout.bottom,layout.bottomY,!model.failedRows.isEmpty))
        }
        if let reply, let frame=replyFrame, reply.travelling {
          let yellow=StatusOutcome.decision.rgb
          let ink=Color(red:0.302+(yellow.0-0.302)*frame.tint,
                        green:0.420+(yellow.1-0.420)*frame.tint,
                        blue:0.996+(yellow.2-0.996)*frame.tint)
          DecisionReturnStroke(frame:frame,angle:reply.angle,gap:max(0,originY-10))
            .stroke(ink,style:StrokeStyle(lineWidth:1.5,lineCap:.round))
            .frame(width:30,height:20).position(x:15,y:originY)
            .opacity(frame.strokeOpacity).allowsHitTesting(false).zIndex(-1)
        }
        if let flight, let motion {
          let target = flight.outcome.rgb
          let color = Color(red: 0.302 + (target.0 - 0.302) * motion.tint,
                            green: 0.420 + (target.1 - 0.420) * motion.tint,
                            blue: 0.996 + (target.2 - 0.996) * motion.tint)
          // Colour belongs to the visible trail: its tail stays the result colour
          // as the head returns towards the source rim, even behind the solid disk.
          let resultColor = flight.outcome.color
          let direction: CGFloat = flight.failed ? 1 : -1
          let returnInk = LinearGradient(stops: [
            .init(color: resultColor, location: 0),
            .init(color: resultColor, location: 0.52),
            .init(color: NotchTokens.deepSeekBlue, location: 1),
          ], startPoint: UnitPoint(x: 0.5, y: 0.5 + direction * 28 / 20),
             endPoint: UnitPoint(x: 0.5, y: 0.5 + direction * 9.5 / 20))
          let ink = motion.returning ? AnyShapeStyle(returnInk) : AnyShapeStyle(color)
          OrbitStroke(frame: motion, angle: flight.angle, gap:flight.decision ? max(0,originY-10):28*(flight.failed ? layout.middle : layout.top))
            .stroke(ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: 30, height: 20)
            .position(x: 15, y: originY)
            .allowsHitTesting(false)
            .zIndex(-1)
        }
      }
      .frame(width: 30, height: totalHeight)
    }

    .accessibilityElement(children: .ignore)
    .accessibilityLabel("运行中 \(model.busyCount)，完成 \(model.completedUnreadCount)，失败 \(model.failedRows.count)，等待决定 \(model.needsAction ? 1:0)")
  }

  private func statusDisk(count: Int, color: Color, opacity: Double) -> some View {
    ZStack {
      Circle().fill(color)
      DecisionFlipGlyph(number:count,progress:0,color:color == NotchTokens.greenComplete ? Color.black:Color.white)
    }
    .frame(width: 19, height: 19)
    .opacity(count > 0 ? opacity : 0)
  }
}
