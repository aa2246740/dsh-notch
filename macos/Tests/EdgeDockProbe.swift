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
          let expected = CGRect(x:body.minX-viewport.minX,y:viewport.maxY-body.maxY,width:body.width,height:body.height)
          check(abs(actual.minX-expected.minX)<0.01 && abs(actual.minY-expected.minY)<0.01 && abs(actual.width-expected.width)<0.01 && abs(actual.height-expected.height)<0.01,
                "native content and contour use the same pose without per-frame SwiftUI layout")
        }
      }
    }
    check(panel.frame.size == CGSize(width:8,height:native.contentSize.height), "native hidden hit rectangle matches the exposed original slice")
    check(panel.contentView?.layer?.cornerRadius == 0, "native material does not reclip the original contour")
    if #available(macOS 26.0, *), let surface = panel.contentView as? NotchGlassSurface {
      check(surface.glass.cornerRadius == 0, "glass clipping also yields to the original contour")
    }
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
