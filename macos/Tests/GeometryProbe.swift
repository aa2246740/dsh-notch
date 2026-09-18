import AppKit
import SwiftUI
import Combine
@main enum GeometryProbe {
 @MainActor static func main() {
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)
  let model = BoardModel()
  model.maximumExpandedHeight = 460
  let panel = NotchPanel(size: NSSize(width: 32,height:90))
  let host = NotchHostingView(rootView: RootView(model:model,panelSize:CGSize(width:320,height:460),restSize:CGSize(width:32,height:110)))
  host.sizingOptions = []
  panel.embedHost(host)
  panel.setFrame(NSRect(x:400,y:400,width:32,height:90),display:true)
  panel.orderFrontRegardless()
  var subscriptions = Set<AnyCancellable>()
  Publishers.CombineLatest(model.$currentIslandWidth,model.$currentIslandHeight).receive(on:DispatchQueue.main).sink { w,h in
   panel.resizeAnchored(to: NSSize(width:w,height:h))
  }.store(in:&subscriptions)
  var failures=0
  func sample(_ tag:String) {
   host.layoutSubtreeIfNeeded()
   guard let rep=host.bitmapImageRepForCachingDisplay(in:host.bounds) else { return }
   host.cacheDisplay(in:host.bounds,to:rep)
   let y=rep.pixelsHigh/2
   var blacks=[Int]()
   for x in 0..<rep.pixelsWide {
    if let c=rep.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB),c.alphaComponent>0.9,c.redComponent<0.05,c.greenComponent<0.05,c.blueComponent<0.05 { blacks.append(x) }
   }
   let gap=rep.pixelsWide-1-(blacks.last ?? -1)
   if abs(panel.frame.maxX - 432) > 0.01 { failures += 1 }
   if NotchMaterial.usesLiquidGlass {
    // Native glass is translucent; black-pixel coverage isn't its boundary.
    // Check the real material, content viewport and clipped right cap instead.
    if #available(macOS 26.0, *), let surface=panel.contentView as? NotchGlassSurface {
     if abs(host.frame.width-surface.bounds.width)>1 || abs(host.frame.height-surface.bounds.height)>1 { failures += 1; print("GLASS_CONTENT_BOUNDS_MISMATCH") }
     if surface.glass.frame.maxX < surface.bounds.maxX+15 { failures += 1; print("GLASS_RIGHT_CAP_VISIBLE") }
     if surface.glass.style != .regular { failures += 1; print("GLASS_STYLE_CHANGED") }
    } else { failures += 1; print("NATIVE_GLASS_MISSING") }
   } else if gap>1 { failures += 1 }
   if let corner=rep.colorAt(x:0,y:2), corner.alphaComponent > 0.1 { failures += 1; print("LEFT_CORNER_CLIPPED") }
   print("\(tag) width=\(rep.pixelsWide) black=\(blacks.first ?? -1)...\(blacks.last ?? -1) rightGap=\(gap)")
  }
  Task { @MainActor in
   try? await Task.sleep(for:.milliseconds(300));sample("rest")
   for hover in [true,false,true,false] {
    model.isPillHovered=hover
    model.currentIslandWidth=hover ? 42:38
    model.currentIslandHeight=hover ? 66:68
    for i in 0..<10 {try? await Task.sleep(for:.milliseconds(20));sample("hover-\(hover)-\(i)")}
   }
   for hover in [true,false,true,false,true,false] {
    model.isPillHovered=hover
    try? await Task.sleep(for:.milliseconds(35));sample("rapid-hover")
   }
   for expanded in [true,false,true,false] {
    model.expanded=expanded
    for i in 0..<15 {try? await Task.sleep(for:.milliseconds(20));sample("expanded-\(expanded)-\(i)")}
   }
   for available in [100.0, 768.0, 1080.0, 1600.0] {
    let layout = NotchScreenLayout(availableHeight: available)
    if abs(layout.maximumHeight + 2 * layout.edgeInset - available) > 0.01 { failures += 1 }
    if layout.maximumHeight <= 0 { failures += 1 }
   }
   @MainActor func setQuestion(description: String) {
    let row: [String: Any] = ["id":"height-test", "title":"height test", "child":false, "busy":false, "unread":false, "ask":["id":"height-ask", "questions":[["id":"height-q", "question":"Height regression", "options":[["label":"Test option", "description":description]]]]]]
    model.rows = [try! JSONDecoder().decode(NotchRow.self, from: JSONSerialization.data(withJSONObject:row))]
   }
   model.maximumExpandedHeight = 900
   setQuestion(description: String(repeating: "Long content for measuring the expanded panel. ", count:100))
   model.expanded = true
   try? await Task.sleep(for:.milliseconds(500))
   sample("long-content-900")
   if abs(panel.frame.height - 900) > 1 { failures += 1; print("LONG_HEIGHT=\(panel.frame.height) EXPECTED=900") }
   model.maximumExpandedHeight = 560
   try? await Task.sleep(for:.milliseconds(500))
   sample("screen-resized-560")
   if abs(panel.frame.height - 560) > 1 { failures += 1; print("SCREEN_HEIGHT=\(panel.frame.height) EXPECTED=560") }
   model.maximumExpandedHeight = 900
   setQuestion(description:"Short content.")
   try? await Task.sleep(for:.milliseconds(500))
   sample("short-content")
   if panel.frame.height >= 460 { failures += 1; print("SHORT_HEIGHT=\(panel.frame.height) EXPECTED<460") }
   model.expanded=false
   model.isPillHovered=false
   for (busy,done,failed,expected) in [(1,0,0,44.0),(1,1,0,72.0),(1,0,1,72.0),(1,1,1,100.0),(0,1,0,44.0)] {
    var rows: [[String:Any]] = []
    if busy>0 { rows.append(["id":"busy", "title":"Busy", "child":false,"busy":true,"unread":false]) }
    if done>0 { rows.append(["id":"done", "title":"Done", "child":false,"busy":false,"unread":true]) }
    if failed>0 { rows.append(["id":"failed", "title":"Failed", "child":false,"busy":false,"unread":true,"lastTurn":["at":0,"kind":"error","failed":true]]) }
    // Exercise the production snapshot entry point so lamp layout advances too.
    model.applySnapshot(NotchSnapshot(ok:true,generatedAt:0,origin:"offline",rows:try! JSONDecoder().decode([NotchRow].self,from:JSONSerialization.data(withJSONObject:rows))))
    try? await Task.sleep(for:.milliseconds(1500))
    sample("lamps-\(busy)-\(done)-\(failed)")
    print("LAMP_HEIGHT=\(panel.frame.height) EXPECTED=\(expected)")
    if abs(panel.frame.height-expected)>1 { failures += 1 }
   }
   print("HEIGHT=\(panel.frame.height)")
   print("FAILURES=\(failures)")
   exit(failures == 0 ? 0 : 1)
  }
  app.run()
  withExtendedLifetime(subscriptions) {}
  exit(failures == 0 ? 0 : 1)
 }
}
