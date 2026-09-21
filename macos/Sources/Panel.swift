import AppKit
import SwiftUI

struct NotchElasticFrame {
  let outline: CGPath
  let bodyClip: CGPath
  let translation: CGPoint
  let opacity: Double
}

enum NotchMaterial {
  static var usesLiquidGlass: Bool {
    if #available(macOS 26.0, *) {
      return ProcessInfo.processInfo.environment["DSH_NOTCH_MATERIAL"] != "hud"
    }
    return false
  }
}

enum NotchGeometryAnimation {
  static let animation = Animation.spring(duration: 0.4, bounce: 0.08)
  static let duration: TimeInterval = 0.4
  static func progress(_ t: Double) -> Double {
    let x = min(1, max(0, t))
    return x*x*x*(x*(6*x-15)+10)
  }
}

final class NotchPanel: NSPanel {
  var allowsMainWindow = false
  var cancelDock: (() -> Void)?
  private let motionMask = CAShapeLayer()
  var dockContourLayer: CALayer { motionMask }
  private weak var motionBacking: NSView?
  private weak var motionHosting: NSView?
  private var motionActive = false
  private let motionBodyMask = CAShapeLayer()
  private var motionBodyShape: CGRect?
  override func cancelOperation(_ sender: Any?) { cancelDock?() }

  func elasticMask(_ path: CGPath?) {
    CATransaction.begin(); CATransaction.setDisableActions(true)
    let active = path != nil
    let directContour: Bool
    if #available(macOS 26.0, *) { directContour = contentView is NotchGlassSurface }
    else { directContour = false }
    if active != motionActive {
      contentView?.layer?.cornerRadius = active ? 0 : 16
      if #available(macOS 26.0, *), let surface = contentView as? NotchGlassSurface {
        surface.glass.cornerRadius = active ? 0 : 16
        surface.setMotionActive(active)
      }
      if let layer = motionBacking?.layer {
        let alpha: Float = active ? 1 : 0
        let fade = CABasicAnimation(keyPath:"opacity")
        fade.fromValue = layer.presentation()?.opacity ?? layer.opacity; fade.toValue = alpha
        fade.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || (active && directContour) ? 0 : 0.10
        layer.opacity = alpha; layer.add(fade,forKey:"material-settle")
      }
      motionActive = active
    }
    if let path {
      motionMask.frame = contentView?.bounds ?? .zero
      motionMask.contentsScale = backingScaleFactor
      motionMask.path = path
      if directContour {
        // A filled contour needs no offscreen alpha-mask pass over the glass
        // hierarchy. The content has its own small, stable rounded-body mask.
        motionBacking?.layer?.backgroundColor = NSColor.clear.cgColor
        if motionMask.superlayer == nil { motionBacking?.layer?.addSublayer(motionMask) }
      } else if contentView?.layer?.mask !== motionMask { contentView?.layer?.mask = motionMask }
    } else {
      contentView?.layer?.mask = nil
      if directContour, let bounds = contentView?.bounds {
        motionMask.frame = bounds
        motionMask.path = UnevenRoundedRectangle(topLeadingRadius:16,bottomLeadingRadius:16,
          bottomTrailingRadius:0,topTrailingRadius:0,style:.continuous).path(in:bounds).cgPath
      }
    }
    CATransaction.commit()
  }
  func positionMotionContent(_ frame: CGRect?, opacity: Double, trailingRadius: CGFloat = 0) {
    guard let hosting = motionHosting else { return }
    if #available(macOS 26.0, *), let surface = contentView as? NotchGlassSurface {
      surface.motionContentFrame = frame
    }
    hosting.autoresizingMask = frame == nil ? [.width,.height] : []
    let next = frame ?? contentView?.bounds ?? .zero
    if hosting.frame.size != next.size { hosting.setFrameSize(next.size) }
    if hosting.frame.origin != .zero { hosting.setFrameOrigin(.zero) }
    // NSHostingView.setFrameOrigin invalidates SwiftUI layout even when its
    // size stays constant. Composite the existing content in the same layer
    // transaction as the contour instead of laying it out at every position.
    hosting.layer?.setAffineTransform(CGAffineTransform(translationX:next.minX,y:next.minY))
    hosting.layer?.opacity = Float(opacity)
    if frame != nil {
      let shape = CGRect(x:trailingRadius,y:0,width:next.width,height:next.height)
      if motionBodyShape != shape {
        let bounds = CGRect(origin:.zero,size:next.size)
        let path = UnevenRoundedRectangle(topLeadingRadius:16,bottomLeadingRadius:16,
          bottomTrailingRadius:trailingRadius,topTrailingRadius:trailingRadius,style:.continuous).path(in:bounds)
        var flip = CGAffineTransform(a:1,b:0,c:0,d:-1,tx:0,ty:bounds.height)
        motionBodyMask.frame = bounds; motionBodyMask.contentsScale = backingScaleFactor
        motionBodyMask.path = path.cgPath.copy(using:&flip); motionBodyShape = shape
      }
      if hosting.layer?.mask !== motionBodyMask { hosting.layer?.mask = motionBodyMask }
    } else { hosting.layer?.mask = nil; motionBodyShape = nil }
  }
  func startElasticFlight(frames: [NotchElasticFrame], interval: Double, began: Double) {
    guard let content = motionHosting?.layer, frames.count > 1 else { return }
    let duration = Double(frames.count-1)*interval
    let times = frames.indices.map { NSNumber(value:Double($0)/Double(frames.count-1)) }
    func animate(_ layer: CALayer, _ key: String, _ values: [Any]) {
      let animation = CAKeyframeAnimation(keyPath:key)
      animation.values = values; animation.keyTimes = times
      // The contour's vertex topology changes as it stretches. Discrete 120 Hz
      // samples keep outline, content and clipping on the exact same pose.
      animation.calculationMode = .discrete
      animation.duration = duration; animation.beginTime = layer.convertTime(began,from:nil)
      animation.fillMode = .forwards; animation.isRemovedOnCompletion = false
      layer.add(animation,forKey:"elastic-flight-\(key)")
    }
    animate(motionMask,"path",frames.map(\.outline))
    animate(content,"transform",frames.map { NSValue(caTransform3D:CATransform3DMakeTranslation($0.translation.x,$0.translation.y,0)) })
    animate(content,"opacity",frames.map { NSNumber(value:$0.opacity) })
    animate(motionBodyMask,"path",frames.map(\.bodyClip))
  }
  func stopElasticFlight() {
    motionMask.removeAnimation(forKey:"elastic-flight-path")
    motionBodyMask.removeAnimation(forKey:"elastic-flight-path")
    motionHosting?.layer?.removeAnimation(forKey:"elastic-flight-transform")
    motionHosting?.layer?.removeAnimation(forKey:"elastic-flight-opacity")
  }
  private var resizeTimer: Timer?
  private var resizeTarget: NSSize?
  private var resizeGeneration = 0

  func cancelResize() {
    if resizeTarget != nil {
      // The AppKit animator outlives the fallback timer. Retarget its frame
      // with zero duration before handing geometry to a direct drag.
      let current = frame
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0
        self.animator().setFrame(current, display: true)
      }
    }
    resizeTimer?.invalidate()
    resizeTimer = nil
    resizeTarget = nil
    resizeGeneration += 1
  }

  /// Animate one native rectangle, preserving its top-right edge at every frame.
  func resizeAnchored(to size: NSSize, animated: Bool = true) {
    guard resizeTarget != size else { return }
    cancelResize()
    let generation = resizeGeneration
    resizeTarget = size
    let start = frame
    let end = NSRect(x: start.maxX - size.width, y: start.maxY - size.height, width: size.width, height: size.height)
    guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      setFrame(end, display: true)
      return
    }
    if #available(macOS 15.0, *) {
      NSAnimationContext.animate(NotchGeometryAnimation.animation) {
        self.animator().setFrame(end, display: true)
      }
      return
    }
    let began = ProcessInfo.processInfo.systemUptime
    resizeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.resizeGeneration == generation else { return }
        let t = min(1, (ProcessInfo.processInfo.systemUptime - began) / NotchGeometryAnimation.duration)
        let progress = NotchGeometryAnimation.progress(t)
        let width = start.width + (size.width - start.width) * progress
        let height = start.height + (size.height - start.height) * progress
        self.setFrame(NSRect(x: start.maxX - width, y: start.maxY - height, width: width, height: height), display: true)
        if t >= 1 { self.resizeTimer?.invalidate(); self.resizeTimer = nil }
      }
    }
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { allowsMainWindow }

  // An accessory panel has no active app Edit menu to route Command keys.
  // Handle only standard editing commands, and only for our focused editor.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard isKeyWindow, let editor = firstResponder as? NSTextView else {
      return super.performKeyEquivalent(with: event)
    }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else {
      return super.performKeyEquivalent(with: event)
    }
    let key = event.charactersIgnoringModifiers?.lowercased()
    if flags.contains(.shift) {
      if key == "z", editor.isEditable, let undo = editor.undoManager, undo.canRedo {
        undo.redo()
        return true
      }
      return super.performKeyEquivalent(with: event)
    }
    switch key {
    case "a": editor.selectAll(nil)
    case "c": editor.copy(nil)
    case "x" where editor.isEditable: editor.cut(nil)
    case "v" where editor.isEditable: editor.paste(nil)
    case "z" where editor.isEditable:
      guard let undo = editor.undoManager, undo.canUndo else {
        return super.performKeyEquivalent(with: event)
      }
      undo.undo()
    default: return super.performKeyEquivalent(with: event)
    }
    return true
  }

  convenience init(size: NSSize) {
    self.init(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    level = .statusBar
    collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    isOpaque = false
    backgroundColor = .clear
    appearance = NSAppearance(named: .darkAqua)
    hasShadow = false
    isMovable = false
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = true
    isReleasedWhenClosed = false
  }

  /// Keep the material outside SwiftUI's hosting layer so it can sample the
  /// window backdrop. A sibling content view keeps controls undistorted.
  func embedHost(_ hosting: NSView) {
    motionHosting = hosting
    if #available(macOS 26.0, *), NotchMaterial.usesLiquidGlass {
      contentView = NotchGlassSurface(hosting: hosting, frame: contentView?.bounds ?? NSRect(origin: .zero, size: frame.size))
      installMotionBacking(below:hosting)
      return
    }
    let effect = NSVisualEffectView(frame: contentView?.bounds ?? NSRect(origin: .zero, size: frame.size))
    effect.material = .hudWindow
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.isEmphasized = true
    effect.autoresizingMask = [.width, .height]
    effect.wantsLayer = true
    effect.layer?.masksToBounds = true
    effect.layer?.cornerRadius = 16
    effect.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
    effect.appearance = NSAppearance(named: .darkAqua)
    contentView = effect
    hosting.autoresizingMask = [.width, .height]
    hosting.frame = effect.bounds
    hosting.wantsLayer = true
    hosting.layer?.isOpaque = false
    hosting.layer?.backgroundColor = NSColor.clear.cgColor
    effect.addSubview(hosting)
    installMotionBacking(below:hosting)
  }

  private func installMotionBacking(below hosting: NSView) {
    guard let parent = hosting.superview else { return }
    let backing = NotchMotionBacking(frame:parent.bounds)
    backing.autoresizingMask = [.width,.height]
    backing.wantsLayer = true
    backing.layer?.backgroundColor = NSColor.black.cgColor
    backing.layer?.opacity = 0
    parent.addSubview(backing,positioned:.below,relativeTo:hosting)
    motionBacking = backing
  }
}

private final class NotchMotionBacking: NSView {
  override var isOpaque: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@available(macOS 26.0, *)
final class NotchGlassSurface: NSView {
  let glass = NSGlassEffectView()
  private let content = NSView()
  private let hosting: NSView
  private let radius: CGFloat = 16
  var motionContentFrame: CGRect?
  func setMotionActive(_ active: Bool) {
    if !active { glass.isHidden = false; return }
    // Rubber is opaque. Do not render a backdrop over the large reserved canvas.
    glass.isHidden = true
  }

  init(hosting: NSView, frame: NSRect) {
    self.hosting = hosting
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = true
    layer?.cornerRadius = radius
    layer?.cornerCurve = .continuous
    layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
    appearance = NSAppearance(named: .darkAqua)
    glass.style = .regular
    glass.cornerRadius = radius
    glass.tintColor = NSColor.black.withAlphaComponent(0.18)
    if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
    addSubview(glass)
    addSubview(content)
    hosting.wantsLayer = true
    hosting.layer?.isOpaque = false
    hosting.layer?.backgroundColor = NSColor.clear.cgColor
    content.addSubview(hosting)
    layout()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var isOpaque: Bool { false }

  override func layout() {
    super.layout()
    // Extend the native right-hand rounded end beyond the clipping boundary.
    // The visible body stays flush with the display edge even while resizing.
    glass.frame = NSRect(x: 0, y: 0, width: bounds.width + radius, height: bounds.height)
    content.frame = bounds
    let frame = motionContentFrame ?? bounds
    hosting.frame = CGRect(origin:.zero,size:frame.size)
    hosting.layer?.setAffineTransform(CGAffineTransform(translationX:frame.minX,y:frame.minY))
  }
}

final class NotchHostingView<Content: View>: NSHostingView<Content> {
  override var isOpaque: Bool { false }

  // The panel is intentionally nonactivating. A click must reach SwiftUI
  // controls immediately, even while another app is the active application.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct NotchScreenLayout {
  let edgeInset: CGFloat
  let maximumHeight: CGFloat

  init(availableHeight: CGFloat, preferredInset: CGFloat = 100) {
    let height = max(1, availableHeight)
    edgeInset = min(preferredInset, max(0, (height - 1) / 2))
    maximumHeight = height - 2 * edgeInset
  }
}
