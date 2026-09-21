import AppKit
import SwiftUI

@main enum PresentationProbe {
  @MainActor static func main() {
    NSApplication.shared.setActivationPolicy(.accessory)
    let folder=URL(fileURLWithPath:ProcessInfo.processInfo.environment["NOTCH_PRESENTATION_OUTPUT"] ?? NSTemporaryDirectory())
    try! FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    var failures=0
    func check(_ ok:Bool,_ label:String) { if !ok { failures += 1;print("FAIL \(label)") } }
    let director=IdleDirector();director.automaticActions=false
    let presence=IdlePresence()
    for residue in [6.661338147750939e-16,0.02,0.5,0.99] {
      presence.visibility=residue;presence.entering=true;presence.transitioning=true
      presence.set(false,director:director)
      presence.finishTransition(director:director)
      check(presence.visibility==0 && !presence.entering && !presence.transitioning,"interrupted entry settles at exact invisible endpoint")
      check(!presence.showsRobot(whenIdle:false),"settled status cannot be covered by a robot canvas")
      presence.set(true,director:director)
      presence.finishTransition(director:director)
      check(presence.visibility==1 && presence.entering && !presence.transitioning,"reverse back to idle settles exactly")
    }
    presence.stop();director.stop()
    let blue=NotchRow(id:"fixture",title:"Offline",child:false,busy:true,unread:false)
    let green=NotchRow(id:"fixture",title:"Offline",child:false,busy:false,unread:true)
    let model=BoardModel();model.previewMode=true
    func snap(_ time:Double,_ rows:[NotchRow])->NotchSnapshot {NotchSnapshot(ok:true,generatedAt:time,origin:"offline",rows:rows)}
    model.applySnapshot(snap(100,[blue]));model.tickOrbitLayout(at:Date().addingTimeInterval(3))
    model.applySnapshot(snap(300,[green]))
    let flight=model.statusFlight!.id
    model.applySnapshot(snap(200,[blue]));model.applySnapshot(snap(250,[]))
    check(model.busyCount==0 && model.completedUnreadCount==1 && model.statusFlight?.id==flight,"late HTTP responses cannot reverse a completed task or restart its flight")
    model.finishStatusFlight(id:flight);model.tickOrbitLayout(at:Date().addingTimeInterval(3))
    check(model.orbitLayout==OrbitLayout(top:1),"completed state has only one green slot")

    func render<V:View>(_ view:V,_ name:String) {
      let hosting=NSHostingView(rootView:view)
      hosting.frame=NSRect(x:0,y:0,width:180,height:200)
      let panel=NSPanel(contentRect:hosting.frame,styleMask:[.borderless],backing:.buffered,defer:false)
      panel.contentView=hosting
      hosting.layoutSubtreeIfNeeded();hosting.displayIfNeeded()
      let rep=hosting.bitmapImageRepForCachingDisplay(in:hosting.bounds)!
      hosting.cacheDisplay(in:hosting.bounds,to:rep)
      try! rep.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent(name+".png"))
      panel.close()
    }
    let neutral=IdleLibrary.shared.clip("blink")!.frames.first!
    let sampled=IdleClip(fps:1,duration:1,frames:[neutral])
    render(ZStack {
      StatusOrbitView(model:model,reduceMotionOverride:true,renderDate:Date())
      // Exact old residual state: the hidden robot still paints a green disk.
      IdleRobotCanvas(clip:sampled,elapsed:0,visibility:6.661338147750939e-16,entering:true,entryColor:0x34c759)
        .frame(width:30,height:42)
    }.scaleEffect(4).frame(width:180,height:200).background(Color.black),"residual-before")
    render(StatusOrbitView(model:model,reduceMotionOverride:true,renderDate:Date())
      .scaleEffect(4).frame(width:180,height:200).background(Color.black),"settled-after")

    // Replay the observed old empty/result oscillation, then stop on a result.
    for index in 0..<40 {
      model.applySnapshot(snap(Double(400+index),index.isMultiple(of:2) ? []:[green]))
      model.tickOrbitLayout(at:Date().addingTimeInterval(3))
    }
    model.recoverExpiredPresentation(at:Date().addingTimeInterval(4))
    check(model.orbitLayout==OrbitLayout(top:1) && model.completedUnreadCount==1 && model.statusFlight==nil,"replayed interruptions settle without stale rings or duplicate slots")
    print("CHECKED reversed idle transitions, exact endpoints, stale responses and 40-state replay")
    print("FAILURES=\(failures)");exit(failures==0 ? 0:1)
  }
}
