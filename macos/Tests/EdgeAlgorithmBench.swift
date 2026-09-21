import AppKit
import SwiftUI

@main enum EdgeAlgorithmBench {
  static func main() throws {
    let viewport = CGRect(x:-900,y:-500,width:900,height:1200)
    // Fixed inputs independent of the solver being benchmarked.
    let poses: [EdgeDockPose] = (0..<4).flatMap { scene in
      (0..<120).map { frame in
        let t = Double(frame)/120
        let x = 170 * exp(-13.5*t) * (cos(6.5383484153*t)+2.5*sin(6.5383484153*t))-30
        let y = 88 * exp(-9*t) * (cos(12*t)+1.3*sin(12*t))
        return EdgeDockPose(width:scene == 2 ? 420:38,height:scene == 2 ? 260:44,
          inward:scene == 1 ? -x-30:x,down:scene == 3 ? -y:y,conceal:min(1,t*4))
      }
    }
    var sink = 0.0
    func measure(_ work: () -> Void) -> [Double] {
      work() // warm framework initialization before measurement
      return (0..<9).map { _ in
        let start = CACurrentMediaTime(); work()
        return (CACurrentMediaTime()-start)*1000
      }
    }
    let spring = measure {
      #if CACHED_CONTOUR
      let xMatrix=EdgeSpringTransition(dt:1.0/120,damping:0.9), yMatrix=EdgeSpringTransition(dt:1.0/120)
      #endif
      for _ in 0..<1000 {
        var x = EdgeSpring(value:140,velocity:777), y = EdgeSpring(value:88,velocity:489)
        for _ in 0..<120 {
          #if CACHED_CONTOUR
          x.step(to:-30,using:xMatrix); y.step(to:0,using:yMatrix)
          #else
          x.step(to:-30,dt:1.0/120,damping:0.9); y.step(to:0,dt:1.0/120)
          #endif
        }
        sink += Double(x.value+y.velocity)
      }
    }
    let geometry = measure {
      for _ in 0..<10 {
        #if CACHED_CONTOUR
        let cache = EdgeDockContourCache()
        #endif
        for pose in poses {
          #if CACHED_CONTOUR
          let f = NotchElasticFrame(pose:pose,viewport:viewport,cache:cache)
          #else
          let f = NotchElasticFrame(pose:pose,viewport:viewport)
          #endif
          sink += Double(f.outline.boundingBoxOfPath.width+f.bodyClip.boundingBoxOfPath.height)+f.opacity
        }
      }
    }
    func report(_ values:[Double], units:Double) -> [String:Any] {
      let sorted=values.sorted()
      return ["runsMs":values,"medianMs":sorted[4],"maxMs":sorted[8],"microsecondsPerUnit":sorted[4]*1000/units]
    }
    let data:[String:Any] = ["solver240kSteps":report(spring,units:240000),
      "geometry4800Frames":report(geometry,units:4800),"checksum":sink]
    print(String(data:try JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
  }
}
