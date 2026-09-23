import AppKit
import SwiftUI

@main enum EdgeDockProbe {
  @MainActor static func main() {
    NSApplication.shared.setActivationPolicy(.accessory)
    var failures = 0
    func check(_ ok: Bool, _ label: String) { if !ok { failures += 1; print("FAIL \(label)") } }
    func settle(_ d: EdgeDockModel) { for _ in 0..<480 { d.advance(by: 1.0/120) } }
    func make() -> EdgeDockModel {
      let d = EdgeDockModel(); d.automaticTicks = false; d.reduceMotionOverride = false
      d.updateRest(CGSize(width: 38, height: 44)); return d
    }
    func point(_ pose: EdgeDockPose, _ f: CGPoint) -> CGPoint {
      CGPoint(x: pose.body.minX + pose.width*f.x, y: pose.body.minY + pose.height*f.y)
    }
    for distance in [0.0,12,64,128,160,240,500,10000] {
      let raw=CGSize(width:distance*0.6,height:distance*0.8), p=EdgeDockDragLimit.project(raw)
      check(hypot(p.width,p.height) <= 240+1e-9, "drag stays within the radial soft limit")
      check(abs(p.width*0.8-p.height*0.6)<1e-9, "soft limit preserves diagonal direction")
      if distance <= 128 { check(p == raw, "ordinary travel remains exactly one to one") }
      let v=CGSize(width:80,height:-45), dt=1e-5
      let q=EdgeDockDragLimit.project(CGSize(width:raw.width+v.width*dt,height:raw.height+v.height*dt))
      let speed=EdgeDockDragLimit.velocity(v,at:raw)
      check(abs((q.width-p.width)/dt-speed.width)<0.002 && abs((q.height-p.height)/dt-speed.height)<0.002,
        "release speed is the derivative of the same resistance map")
    }
    let limit=EdgeDockDragLimit.self, h=1e-3
    check(abs((limit.distance(128+h)-limit.distance(128))/h-1)<1e-7,
      "resistance starts without a velocity corner")
    check(limit.distance(240) < limit.distance(360) && limit.distance(360) < 240,
      "the boundary progressively resists rather than stopping abruptly")
    var lastTip: CGFloat = 1
    for length in [0.0,24,64,128,192,240] {
      let body=EdgeDockPose(inward:length).body, t=EdgeDockTension(body:body,anchorX:0)
      check(t.tipScale <= lastTip && t.tipScale >= 0.44, "longer stretch gets thinner with a material thickness floor")
      lastTip=t.tipScale
    }
    for (x,y) in [(0.0,0.0),(150,0),(0,180),(160,100),(160,-100),(-12,180)] {
      let pose=EdgeDockPose(inward:x,down:y), body=pose.body, anchor=max(0,body.maxX)
      let t=EdgeDockTension(body:body,anchorX:anchor)
      for p in [CGPoint(x:anchor,y:0),CGPoint(x:anchor,y:44),CGPoint(x:body.midX,y:body.midY)] {
        let q=t.point(p)
        check(hypot(q.x-p.x,q.y-p.y)<1e-9, "fixed attachment and grabbed body center remain attached")
      }
      let center=CGPoint(x:body.midX,y:body.midY)
      for p in [CGPoint(x:body.minX,y:body.minY),CGPoint(x:body.maxX,y:body.minY),
                CGPoint(x:body.minX,y:body.maxY),CGPoint(x:body.maxX,y:body.maxY)] {
        let q=t.point(p)
        let localNative=CGPoint(x:p.x-center.x,y:center.y-p.y).applying(t.nativeBodyDeformation)
        check(hypot(q.x-center.x-localNative.x,q.y-center.y+localNative.y)<1e-8,
          "native content has exactly the same deformation as the grabbed end")
      }
      var previousThickness: CGFloat = 60
      for step in 0...30 {
        let s=t.start+t.span*Double(step)/20
        let center=CGPoint(x:t.origin.x+t.axis.dx*s,y:t.origin.y+t.axis.dy*s)
        let a=t.point(CGPoint(x:center.x-t.normal.dx*30,y:center.y-t.normal.dy*30))
        let b=t.point(CGPoint(x:center.x+t.normal.dx*30,y:center.y+t.normal.dy*30))
        let thickness=(b.x-a.x)*t.normal.dx+(b.y-a.y)*t.normal.dy
        check(thickness >= 60*0.44-1e-9 && thickness <= previousThickness+1e-9,
          "material continuously narrows toward the left end without a thick head")
        previousThickness=thickness
      }
    }
    var previousTipHeight: CGFloat = 44
    for length in [0.0,32,80,140,220] {
      let body=EdgeDockPose(inward:length).body, t=EdgeDockTension(body:body,anchorX:0)
      let top=t.point(CGPoint(x:body.midX,y:body.minY)), bottom=t.point(CGPoint(x:body.midX,y:body.maxY))
      let tipHeight=bottom.y-top.y
      check(tipHeight <= previousTipHeight && (length == 0 || tipHeight < 44),
        "the grabbed end itself gets thinner at every greater pull distance")
      if length == 220 { check(tipHeight < 23, "long pull visibly halves the actual left end thickness") }
      previousTipHeight=tipHeight
    }
    let far=make(); far.begin(size:far.restSize,at:0); far.drag(inward:800,down:600,at:0.2)
    check(abs(hypot(far.pose.inward,far.pose.down)-240)<0.001, "very long native pointer travel remains bounded")
    let farPose=far.pose
    far.end(at:0.2); far.advance(by:0.12)
    let catching=far.pose
    far.begin(size:far.restSize,at:0.4); far.drag(inward:0,down:0,at:0.4)
    check(far.pose == catching && catching != farPose, "regrabbing a resisted return has no pose jump")
    far.stop()
    // Closed-form physics must describe the same trajectory at every cadence,
    // including missed callbacks, rather than slowing down when dt is clamped.
    for damping in [0.6,0.9,1.0,1.4] {
      var single=EdgeSpring(value:140,velocity:777)
      single.step(to:-30,dt:0.73,damping:damping)
      for count in [22,44,88,175] {
        var split=EdgeSpring(value:140,velocity:777)
        for _ in 0..<count { split.step(to:-30,dt:0.73/Double(count),damping:damping) }
        check(abs(single.value-split.value)<1e-9 && abs(single.velocity-split.velocity)<1e-8,
          "spring is cadence independent at damping \(damping) and \(count) callbacks")
      }
      var paused=EdgeSpring(value:140,velocity:777)
      paused.step(to:-30,dt:3600,damping:damping)
      check(paused.value == -30 && paused.velocity == 0, "long pauses converge without overflow")
      var tiny=EdgeSpring(value:140,velocity:777)
      tiny.step(to:-30,dt:1e-7,damping:damping)
      check(abs((tiny.value-140)/1e-7-777)<0.01, "analytic initial velocity is the throw velocity")
    }
    let sparse=make(), regular=make()
    for d in [sparse,regular] { d.begin(size:d.restSize,at:0); d.drag(inward:140,down:88,at:0.18); d.end() }
    sparse.advance(by:0.36)
    for _ in 0..<36 { regular.advance(by:0.01) }
    check(abs(sparse.pose.inward-regular.pose.inward)<1e-9 && abs(sparse.pose.down-regular.pose.down)<1e-9,
      "model catches up to real time after a delayed callback")
    let before=sparse.pose, tinyDT=1e-6
    regular.advance(by:tinyDT)
    let vx=(regular.pose.inward-before.inward)/tinyDT, vy=(regular.pose.down-before.down)/tinyDT
    sparse.setHidden(false); sparse.advance(by:tinyDT)
    check(abs((sparse.pose.inward-before.inward)/tinyDT-vx)<0.02 && abs((sparse.pose.down-before.down)/tinyDT-vy)<0.02,
      "target reversal inherits both analytic velocity components")
    sparse.advance(by:5); regular.advance(by:5)
    check(!sparse.settling && !regular.settling, "a long callback delay does not prolong flight")
    let cache=EdgeDockContourCache()
    for frame in 0..<160 {
      let pose=EdgeDockPose(width:frame<80 ? 38:420,height:frame<80 ? 44:260,
        inward:150-Double(frame)*1.2,down:90*sin(Double(frame)/20))
      let cached=EdgeDockGeometry(pose:pose,cache:cache), plain=EdgeDockGeometry(pose:pose)
      check(cached.path.cgPath == plain.path.cgPath, "cached contour is exactly equivalent to the uncached algorithm")
    }
    check(cache.count <= 32 && cache.misses < 50, "contour reuse is bounded across original and expanded shells")
    for height in 45...244 {
      _ = EdgeDockGeometry(pose:EdgeDockPose(height:CGFloat(height),inward:70,down:20),cache:cache)
    }
    check(cache.count == 32 && cache.misses > 200, "continuous task-size changes evict old contours instead of growing the cache")
    let sampled=make()
    sampled.begin(size:sampled.restSize,at:0); sampled.drag(inward:140,down:88,at:0.18); sampled.end()
    let dense=sampled.flightSamples(), compact=sampled.flightTimeline()
    check(compact.count < dense.count && compact.first?.pose == dense.first && compact.last?.pose == dense.last,
      "compact trajectory reduces payload and retains exact start/end")
    var held=0, maxError=0.0
    for (i,p) in dense.enumerated() {
      let t=Double(i)/120
      while held+1 < compact.count && compact[held+1].time <= t+1e-12 { held += 1 }
      let q=compact[held].pose
      maxError=max(maxError,hypot(p.inward-q.inward,p.down-q.down))
      check(hypot(p.inward-q.inward,p.down-q.down) <= 0.025+1e-9 && abs(p.conceal-q.conceal) <= 1.0/1024+1e-9,
        "every held sample remains inside the translation/opacity error budget")
    }
    print("ALGORITHM dense=\(dense.count) compact=\(compact.count) maxHeldTranslationErrorPt=\(maxError)")
    sampled.stop()
    for (dx,dy) in [(120.0,0.0),(0,100),(0,-100),(100,80),(100,-80),(-12,0),(-12,80),(-12,-80)] {
      let d = make(), f = CGPoint(x:0.3,y:0.7), before = point(make().pose, CGPoint(x:0.3,y:0.7))
      d.begin(size:d.restSize,at:0)
      d.drag(inward:dx,down:dy,at:0.2)
      let after = point(d.pose,f)
      check(abs(after.x-(before.x-dx)) < 0.001 && abs(after.y-(before.y+dy)) < 0.001, "cursor lock in direction \(dx),\(dy)")
      let release = d.pose
      d.end(at:0.2)
      check(d.pose == release, "release begins at current presentation")
      d.advance(by:1.0/240)
      check(hypot(d.pose.inward-release.inward,d.pose.down-release.down) < 14, "first release frame is continuous in every direction")
      settle(d)
      check(hypot(dx,dy)>24 ? d.pose == .tucked(size:d.contentSize) : !d.hidden, "every direction settles at its committed endpoint")
    }
    let dock = make()
    dock.begin(size:dock.restSize,at:0); dock.drag(inward:120,down:85,at:0.1)
    let release = dock.pose
    dock.drag(inward:120,down:85,at:0.105); dock.end(at:0.105)
    check(dock.pose == release, "stationary mouse-up does not jump")
    let forecast = dock.flightSamples(interval:1.0/240)
    check(forecast.first == release && forecast.last == dock.targetPose, "compositor trajectory starts at release and ends at the exact cap")
    dock.advance(by:1.0/240)
    check(dock.pose == forecast[1], "compositor trajectory uses the live spring solver and release velocity")
    check(dock.pose.inward > release.inward && dock.pose.down > release.down, "release retains both components of throw velocity")
    var rebound = false
    for _ in 0..<240 { dock.advance(by:1.0/120); rebound = rebound || dock.pose.down < -1 }
    check(rebound, "spring crosses home and visibly rebounds")
    settle(dock); check(dock.pose == .tucked(size:dock.contentSize), "exact hidden endpoint")
    let hiddenGeometry = dock.geometry
    check(hiddenGeometry.radius == 16 && hiddenGeometry.bounds.size == CGSize(width:8,height:44), "hidden view is an 8 point slice with the original height and corners")
    check(dock.pose.size == CGSize(width:38,height:44), "hiding never resizes the original shell")
    dock.hover(true); settle(dock)
    check(dock.pose == .tucked(size:dock.contentSize,peeking:true) && dock.contentOpacity == 0, "hover only translates the original cap")
    for exposed in [8.0,10.0,14.0] {
      let p = EdgeDockPose(inward:exposed-38,conceal:1), g = EdgeDockGeometry(pose:EdgeDockPose(inward:exposed-38,conceal:1))
      let original = UnevenRoundedRectangle(topLeadingRadius:16,bottomLeadingRadius:16,
                                           bottomTrailingRadius:0,topTrailingRadius:0,style:.continuous).path(in:p.body)
      var equal = true
      for x in stride(from:-exposed+0.125,to:0,by:0.25) {
        for y in stride(from:0.125,to:44,by:0.25) {
          let pixel = CGPoint(x:x,y:y)
          equal = equal && (g.path.contains(pixel) == original.contains(pixel))
        }
      }
      check(equal, "every visible pixel matches the translated original at exposure \(exposed)")
    }
    for (x,y) in [(0.0,0.0),(150,0),(0,120),(140,85),(130,-95),(-12,80)] {
      let g = EdgeDockGeometry(pose:EdgeDockPose(inward:x,down:y))
      var starts = 0, closes = 0, segments = 0
      g.path.forEach { element in
        segments += 1
        if case .move = element { starts += 1 }
        if case .closeSubpath = element { closes += 1 }
      }
      check(starts == 1 && closes == 1, "one continuous shell, with no separate tail at \(x),\(y)")
      check(segments <= 180, "contour upload stays bounded without over-sampling rounded corners")
      check(g.path.contains(CGPoint(x:g.body.midX,y:g.body.midY)), "held content stays inside the rubber")
      if x >= 0 {
        check([8.0,22,36].allSatisfy { g.path.contains(CGPoint(x:-0.25,y:$0)) }, "attachment retains the shell's full height")
      }
    }
    dock.hover(false); settle(dock)
    let concealed = dock.pose
    dock.updateRest(CGSize(width:38,height:112))
    check(dock.pose == concealed, "background task updates do not reshape the hidden cap")
    dock.updateRest(CGSize(width:38,height:44))
    let fraction = CGPoint(x:0.4,y:0.2), grabbed = point(dock.pose,CGPoint(x:0.4,y:0.2))
    dock.begin(size:dock.pose.size,at:2); dock.drag(inward:40,down:60,at:2.2)
    let followed = point(dock.pose,fraction)
    check(abs(followed.x-grabbed.x+40)<0.001 && abs(followed.y-grabbed.y-60)<0.001, "pulling out the original cap preserves cursor grip")
    dock.end(at:2.2); settle(dock)
    check(!dock.hidden && dock.pose.size == dock.restSize, "restore reaches latest normal dimensions")
    for ticks in [2,12,28,50] {
      dock.setHidden(true)
      for _ in 0..<ticks { dock.advance(by:1.0/120) }
      let live = dock.pose
      dock.begin(size:live.size,at:5)
      check(dock.pose == live, "mid-flight grab has no pose jump")
      dock.drag(inward:60,down:-50,at:5.2); dock.end(at:5.2); settle(dock)
      check(!dock.hidden && dock.pose.size == dock.restSize, "reverse a flight in two dimensions")
    }
    dock.setHidden(true); settle(dock); dock.setHidden(false); dock.advance(by:0.04)
    let beforeRetarget = dock.pose
    dock.updateRest(CGSize(width:38,height:112))
    check(dock.pose == beforeRetarget, "task updates retarget without jump")
    settle(dock); check(dock.pose.size == dock.restSize, "latest task height wins")
    dock.begin(size:dock.restSize,at:7); dock.drag(inward:100,down:70,at:7.2); dock.end(at:7.2)
    check(dock.flightSamples().allSatisfy { $0.size == dock.contentSize }, "a completed size transition cannot leak velocity into a later fixed-size throw")
    settle(dock)
    dock.reduceMotionOverride = true; dock.setHidden(true)
    check(!dock.settling && dock.pose == .tucked(size:dock.contentSize), "reduced motion immediately reaches the original cap")
    dock.setHidden(false); check(!dock.engaged && dock.pose.size == dock.restSize, "reduced motion restore")

    let native = make(), panel = NotchPanel(size:CGSize(width:38,height:44))
    panel.setFrameOrigin(NSPoint(x:-10000,y:-10000))
    let host = NotchHostingView(rootView:EdgeDockSurface(dock:native,content:Color.black))
    host.sizingOptions = []; panel.embedHost(host)
    let controller = EdgeDockController(dock:native,panel:panel,hosting:host)
    controller.updateRest(CGSize(width:420,height:320))
    RunLoop.main.run(until:Date().addingTimeInterval(0.05))
    native.begin(size:panel.frame.size,at:10); native.drag(inward:70,down:50,at:10.2)
    let locked = panel.frame
    RunLoop.main.run(until:Date().addingTimeInterval(0.5))
    check(abs(panel.frame.width-locked.width)<0.1 && abs(panel.frame.height-locked.height)<0.1, "old native expansion cannot overwrite drag")
    native.end()
    check(panel.frame == locked, "release uses the canvas reserved during dragging without a mouse-up resize")
    let springFrame = panel.frame, sharedMask = panel.dockContourLayer
    for _ in 0..<480 {
      native.advance(by:1.0/120)
      if native.settling {
        check(panel.frame == springFrame, "native backing size stays fixed during the spring")
        check(panel.dockContourLayer === sharedMask, "every spring frame reuses one native contour")
        check(native.presentationBounds?.contains(native.geometry.bounds) == true, "reserved canvas contains the entire moving contour")
        if let viewport = native.presentationBounds, let layer = host.layer, let root = panel.contentView?.layer {
          let body = native.pose.body
          let actual = layer.convert(layer.bounds,to:root)
          let tension=native.geometry.tension
          let corners=[CGPoint(x:body.minX,y:body.minY),CGPoint(x:body.maxX,y:body.minY),
                       CGPoint(x:body.minX,y:body.maxY),CGPoint(x:body.maxX,y:body.maxY)].map { p in
            let q=tension.point(p)
            return CGPoint(x:q.x-viewport.minX,y:viewport.maxY-q.y)
          }
          let expected=CGRect(x:corners.map(\.x).min()!,y:corners.map(\.y).min()!,
            width:corners.map(\.x).max()!-corners.map(\.x).min()!,height:corners.map(\.y).max()!-corners.map(\.y).min()!)
          check(abs(actual.minX-expected.minX)<0.01 && abs(actual.minY-expected.minY)<0.01 && abs(actual.width-expected.width)<0.01 && abs(actual.height-expected.height)<0.01,
                "native content and narrowing end use the same deformation without SwiftUI relayout: actual=\(actual) expected=\(expected) anchor=\(layer.anchorPoint)")
        }
      }
    }
    check(panel.frame.size == CGSize(width:8,height:native.contentSize.height), "native hidden hit rectangle matches the exposed original slice")
    check(panel.contentView?.layer?.cornerRadius == 0, "native material does not reclip the original contour")
    if #available(macOS 26.0, *), let surface = panel.contentView as? NotchGlassSurface {
      check(surface.glass.cornerRadius == 0, "glass clipping also yields to the original contour")
    }
    // Re-pin directly in screen coordinates, preserving the hidden crop.
    let requestedAnchor=CGPoint(x:-9500,y:-9000)
    let hiddenPose=native.pose
    controller.pin(to:requestedAnchor)
    check(abs(panel.frame.maxX-requestedAnchor.x)<0.01 && abs(panel.frame.maxY-requestedAnchor.y)<0.01,
          "screen reposition keeps a hidden cap exactly attached to the requested edge")
    check(native.pose == hiddenPose, "re-pinning does not reinterpret the hidden crop as a full-size body")
    let screen=CGRect(x:100,y:0,width:1200,height:900)
    for reserved in [0.0,60,120] {
      let visible=CGRect(x:100,y:0,width:1200-reserved,height:876)
      let anchor=NotchScreenLayout(availableHeight:visible.height).anchor(screen:screen,visible:visible)
      check(anchor.x == screen.maxX && anchor.y == visible.maxY-100,
            "right-side macOS Dock never becomes the Notch screen edge")
    }

    let attentionModel=BoardModel(); attentionModel.previewMode=true
    controller.observeAttention(in:attentionModel)
    native.onHidden = { attentionModel.visuallyDocked = $0 }
    native.setHidden(true,animated:false)
    var snapshotTime=1000.0
    func snapshot(_ rows:[NotchRow]) {
      snapshotTime += 1
      attentionModel.applySnapshot(NotchSnapshot(ok:true,generatedAt:snapshotTime,origin:"offline",rows:rows))
      RunLoop.main.run(until:Date().addingTimeInterval(0.01))
    }
    let busy=NotchRow(id:"attention",title:"Local",child:false,busy:true,unread:false)
    let done=NotchRow(id:"attention",title:"Local",child:false,busy:false,unread:true,
      lastTurn:NotchLastTurn(at:1,kind:"complete",failed:false))
    let failed=NotchRow(id:"attention",title:"Local",child:false,busy:false,unread:true,
      lastTurn:NotchLastTurn(at:2,kind:"error",failed:true))
    let approval=NotchRow(id:"attention",title:"Local",child:false,busy:true,unread:false,
      approval:NotchApproval(id:"approve-1",toolName:"local-test"))
    let question=NotchRow(id:"attention",title:"Local",child:false,busy:true,unread:false,
      ask:NotchAsk(id:"ask-1",questions:[]))
    let concealedQuestion=BoardModel()
    concealedQuestion.visuallyDocked=true
    concealedQuestion.applySnapshot(NotchSnapshot(ok:true,generatedAt:1,origin:"offline",rows:[question]))
    check(!concealedQuestion.expanded, "a hidden decision reveals its compact indicator before any question panel")
    let quietFrame=panel.frame
    snapshot([busy])
    for size in [CGSize(width:38,height:44),CGSize(width:42,height:100),CGSize(width:420,height:240)] {
      controller.updateRest(size)
      check(native.hidden && native.pose == hiddenPose && panel.frame == quietFrame,
            "ordinary task and size updates leave the hidden cap attached and unchanged")
    }
    snapshot([])
    check(native.hidden, "clearing a running task without an unread result does not wake the Notch")
    for (name,row) in [("completion",done),("error",failed),("approval",approval),("question",question)] {
      native.setHidden(true,animated:false)
      let before=native.pose
      snapshot([row])
      check(!native.hidden && native.settling && native.pose == before,
            "new \(name) starts a continuous complete reveal from the hidden pose")
      controller.updateRest(CGSize(width:38,height:44))
      settle(native)
      check(!native.engaged && native.pose == EdgeDockPose() && abs(panel.frame.maxX-requestedAnchor.x)<0.01,
            "\(name) settles at the complete original edge position")
      native.setHidden(true,animated:false)
      snapshot([row]); snapshot([row])
      check(native.hidden && !native.settling, "repeated \(name) polls respect manual re-hiding")
    }
    var secondQuestion=question; secondQuestion.ask?.id="ask-2"
    snapshot([secondQuestion]); settle(native)
    check(!native.hidden, "a new request with the same session and count still attracts attention")
    native.setHidden(true,animated:false)
    let revision=attentionModel.attentionRevision
    attentionModel.applySnapshot(NotchSnapshot(ok:true,generatedAt:snapshotTime-20,origin:"offline",rows:[failed]))
    RunLoop.main.run(until:Date().addingTimeInterval(0.01))
    check(native.hidden && attentionModel.attentionRevision == revision, "stale snapshots cannot wake a hidden Notch")
    snapshot([])
    native.begin(size:native.pose.size,at:20); native.drag(inward:70,down:35,at:20.1)
    let attentionHeldPose=native.pose
    snapshot([done])
    check(native.dragging && native.pose == attentionHeldPose, "attention does not steal a drag or move the held point")
    native.end(at:20.1); settle(native)
    check(!native.hidden && !native.engaged, "attention during a drag reveals after release")
    snapshot([])
    native.setHidden(true); native.advance(by:0.06)
    let retracting=native.pose
    snapshot([failed])
    check(!native.hidden && native.pose == retracting, "attention reverses an active tuck without a pose jump")
    settle(native)
    check(abs(panel.frame.maxX-requestedAnchor.x)<0.01, "interrupted tuck finishes on the real edge")
    native.reduceMotionOverride=true
    native.setHidden(true,animated:false)
    snapshot([approval])
    check(!native.hidden && !native.engaged && !native.settling,
          "reduced motion reveals directly at the final pose: hidden=\(native.hidden) engaged=\(native.engaged) settling=\(native.settling) revision=\(attentionModel.attentionRevision)")
    native.stop(); panel.close()

    let betweenFrames = make()
    betweenFrames.setHidden(true); betweenFrames.advance(by:0.10)
    let displayed = EdgeDockPose(inward:-9,down:3,conceal:0.45)
    betweenFrames.presentedPose = { displayed }
    betweenFrames.begin(size:betweenFrames.restSize,at:12)
    check(betweenFrames.pose == displayed, "interrupt reads the compositor pose instead of the last callback pose")
    betweenFrames.drag(inward:8,down:-4,at:12.1)
    check(betweenFrames.pose.inward == displayed.inward+8 && betweenFrames.pose.down == displayed.down-4,
          "regrab preserves the pointer offset from the visible moving shell")
    betweenFrames.stop()

    let folder = ProcessInfo.processInfo.environment["NOTCH_EDGE_OUTPUT"] ?? NSTemporaryDirectory()
    try! FileManager.default.createDirectory(atPath:folder,withIntermediateDirectories:true)
    func render(_ pose:EdgeDockPose,_ name:String) {
      let g = EdgeDockGeometry(pose:pose)
      let view = ZStack(alignment:.topLeading) {
        Color(red:0.94,green:0.94,blue:0.95)
        Rectangle().fill(Color.black.opacity(0.12)).frame(width:1,height:360).offset(x:360)
        g.path.applying(CGAffineTransform(translationX:360,y:140)).fill(Color.black)
          .mask(Rectangle().frame(width:360,height:360).frame(width:400,height:360,alignment:.leading))
      }.frame(width:400,height:360)
      let host = NSHostingView(rootView:view); host.frame = NSRect(x:0,y:0,width:400,height:360)
      let panel = NSPanel(contentRect:host.frame,styleMask:[.borderless],backing:.buffered,defer:false); panel.contentView = host
      host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
      let rep = host.bitmapImageRepForCachingDisplay(in:host.bounds)!
      host.cacheDisplay(in:host.bounds,to:rep)
      try! rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:folder).appendingPathComponent(name+".png"))
      panel.close()
    }
    let originalSize = CGSize(width:38,height:44)
    for (name,pose) in [("hidden",EdgeDockPose.tucked(size:originalSize)),("peek",.tucked(size:originalSize,peeking:true)),("left",EdgeDockPose(inward:150)),("down",EdgeDockPose(down:120)),("diagonal",EdgeDockPose(inward:140,down:85)),("up",EdgeDockPose(inward:130,down:-95)),("original",EdgeDockPose())] { render(pose,name) }
    for length in [32,80,140,220] { render(EdgeDockPose(inward:CGFloat(length)),"stretch-\(length)") }
    let movie = make()
    movie.begin(size:movie.restSize,at:0); movie.drag(inward:140,down:90,at:0.18); movie.end(at:0.18)
    var samples = [[String:Double]]()
    for frame in 0..<60 {
      let p = movie.pose
      check(p.size == originalSize, "retraction preserves shell dimensions on frame \(frame)")
      check(movie.geometry.bounds.width >= 6, "retraction keeps a visible cap on frame \(frame)")
      samples.append(["t":Double(frame)/60,"x":Double(p.inward),"y":Double(p.down),"width":Double(p.width),"height":Double(p.height)])
      render(p,String(format:"return-%03d",frame)); movie.advance(by:1.0/60)
    }
    try! JSONSerialization.data(withJSONObject:samples,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:folder).appendingPathComponent("trajectory.json"))
    movie.stop(); dock.stop()
    print("CHECKED 2D cursor lock, 2D velocity, single rubber contour, exact original crop, rebound, interruption, native bounds and reduced motion")
    print("FAILURES=\(failures)"); exit(failures == 0 ? 0:1)
  }
}
