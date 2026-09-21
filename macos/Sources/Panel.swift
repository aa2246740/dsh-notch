import AppKit
import SwiftUI

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
  override func cancelOperation(_ sender: Any?) { cancelDock?() }

  func elasticMask(_ path: CGPath?) {
    CATransaction.begin(); CATransaction.setDisableActions(true)
    contentView?.layer?.cornerRadius = path == nil ? 16 : 0
    if #available(macOS 26.0, *), let surface = contentView as? NotchGlassSurface {
      surface.glass.cornerRadius = path == nil ? 16 : 0
    }
    if let path {
      let mask = CAShapeLayer(); mask.path = path
      contentView?.layer?.mask = mask
    } else { contentView?.layer?.mask = nil }
    CATransaction.commit()
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
  /// window backdrop. Its contentView contains sharp, undistorted controls.
  func embedHost(_ hosting: NSView) {
    if #available(macOS 26.0, *), NotchMaterial.usesLiquidGlass {
      contentView = NotchGlassSurface(hosting: hosting, frame: contentView?.bounds ?? NSRect(origin: .zero, size: frame.size))
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
  }
}

@available(macOS 26.0, *)
final class NotchGlassSurface: NSView {
  let glass = NSGlassEffectView()
  private let content = NSView()
  private let hosting: NSView
  private let radius: CGFloat = 16

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
    glass.contentView = content
    addSubview(glass)
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
    content.frame = glass.bounds
    hosting.frame = bounds
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
