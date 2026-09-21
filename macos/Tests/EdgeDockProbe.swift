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
      d.begin(size:d.restSize,grab:f,at:0)
      d.drag(inward:dx,down:dy,at:0.2)
      let after = point(d.pose,f)
      check(abs(after.x-(before.x-dx)) < 0.001 && abs(after.y-(before.y+dy)) < 0.001, "cursor lock in direction \(dx),\(dy)")
      let release = d.pose
      d.end(at:0.2)
      check(d.pose == release, "release begins at current presentation")
      d.advance(by:1.0/240)
      check(hypot(d.pose.inward-release.inward,d.pose.down-release.down) < 14, "first release frame is continuous in every direction")
      settle(d)
      check(hypot(dx,dy)>24 ? d.pose == .hidden : !d.hidden, "every direction settles at its committed endpoint")
    }
    let dock = make()
    dock.begin(size:dock.restSize,at:0); dock.drag(inward:120,down:85,at:0.1)
    let release = dock.pose
    dock.drag(inward:120,down:85,at:0.105); dock.end(at:0.105)
    check(dock.pose == release, "stationary mouse-up does not jump")
    dock.advance(by:1.0/240)
    check(dock.pose.inward > release.inward && dock.pose.down > release.down, "release retains both components of throw velocity")
    var rebound = false
    for _ in 0..<240 { dock.advance(by:1.0/120); rebound = rebound || dock.pose.down < -1 }
    check(rebound, "spring crosses home and visibly rebounds")
    settle(dock); check(dock.pose == .hidden, "exact hidden endpoint")
    let hiddenGeometry = dock.geometry
    check(hiddenGeometry.radius == 2 && hiddenGeometry.bounds.size == CGSize(width:6,height:28), "nub is a 6 by 28 rectangle with 2 point corners")
    check(hiddenGeometry.localPath.contains(CGPoint(x:0.5,y:4)) && hiddenGeometry.localPath.contains(CGPoint(x:0.5,y:24)), "straight leading side remains visible above and below center")
    dock.hover(true); settle(dock); check(dock.pose == .peek && dock.contentOpacity == 0, "hover only peeks")
    dock.hover(false); settle(dock)
    let fraction = CGPoint(x:0.4,y:0.2), grabbed = point(dock.pose,CGPoint(x:0.4,y:0.2))
    dock.begin(size:dock.pose.size,grab:fraction,at:2); dock.drag(inward:40,down:60,at:2.2)
    let followed = point(dock.pose,fraction)
    check(abs(followed.x-grabbed.x+40)<0.001 && abs(followed.y-grabbed.y-60)<0.001, "growing nub preserves cursor grip")
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
    dock.reduceMotionOverride = true; dock.setHidden(true)
    check(!dock.settling && dock.pose == .hidden, "reduced motion immediately reaches small rectangle")
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
    native.end(); settle(native)
    check(panel.frame.size == EdgeDockPose.hidden.size, "native hidden hit rectangle matches visible nub")
    check(panel.contentView?.layer?.cornerRadius == 0, "native material does not reclip nub into a semicircle")
    if #available(macOS 26.0, *), let surface = panel.contentView as? NotchGlassSurface {
      check(surface.glass.cornerRadius == 0, "glass content clipping also yields to the explicit small-corner mask")
    }
    native.stop(); panel.close()

    let folder = ProcessInfo.processInfo.environment["NOTCH_EDGE_OUTPUT"] ?? NSTemporaryDirectory()
    try! FileManager.default.createDirectory(atPath:folder,withIntermediateDirectories:true)
    func render(_ pose:EdgeDockPose,_ name:String) {
      let g = EdgeDockGeometry(pose:pose,attachmentY:22)
      let view = ZStack(alignment:.topLeading) {
        Color(red:0.94,green:0.94,blue:0.95)
        Rectangle().fill(Color.black.opacity(0.12)).frame(width:1,height:360).offset(x:360)
        g.path.applying(CGAffineTransform(translationX:360,y:140)).fill(Color.black)
      }.frame(width:400,height:360)
      let host = NSHostingView(rootView:view); host.frame = NSRect(x:0,y:0,width:400,height:360)
      let panel = NSPanel(contentRect:host.frame,styleMask:[.borderless],backing:.buffered,defer:false); panel.contentView = host
      host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
      let rep = host.bitmapImageRepForCachingDisplay(in:host.bounds)!
      host.cacheDisplay(in:host.bounds,to:rep)
      try! rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:folder).appendingPathComponent(name+".png"))
      panel.close()
    }
    for (name,pose) in [("hidden",EdgeDockPose.hidden),("peek",.peek),("left",EdgeDockPose(inward:150)),("down",EdgeDockPose(down:120)),("diagonal",EdgeDockPose(inward:140,down:85)),("up",EdgeDockPose(inward:130,down:-95))] { render(pose,name) }
    let movie = make()
    movie.begin(size:movie.restSize,at:0); movie.drag(inward:140,down:90,at:0.18); movie.end(at:0.18)
    var samples = [[String:Double]]()
    for frame in 0..<60 {
      let p = movie.pose
      samples.append(["t":Double(frame)/60,"x":Double(p.inward),"y":Double(p.down),"width":Double(p.width),"height":Double(p.height)])
      render(p,String(format:"return-%03d",frame)); movie.advance(by:1.0/60)
    }
    try! JSONSerialization.data(withJSONObject:samples,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:folder).appendingPathComponent("trajectory.json"))
    movie.stop(); dock.stop()
    print("CHECKED 2D cursor lock, 2D velocity, rounded rectangle, rebound, interruption, native bounds and reduced motion")
    print("FAILURES=\(failures)"); exit(failures == 0 ? 0:1)
  }
}
