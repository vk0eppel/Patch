import Cocoa
import FlutterMacOS
import window_manager

class MainFlutterWindow: NSWindow {
  private var flashOverlay: FlashOverlayWindow?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let overlay = FlashOverlayWindow()
    flashOverlay = overlay

    let flashChannel = FlutterMethodChannel(
      name: "com.patch.app/flash_overlay",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    flashChannel.setMethodCallHandler { [weak self, weak overlay] call, result in
      guard call.method == "pulse" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let args = call.arguments as? [String: Any],
        let argb = args["argb"] as? Int,
        let pulseCount = args["pulseCount"] as? Int
      else {
        result(FlutterError(code: "bad_args", message: "Expected argb/pulseCount", details: nil))
        return
      }
      overlay?.pulse(argb: argb, pulseCount: pulseCount, near: self)
      result(nil)
    }

    super.awakeFromNib()
  }

  // Keep the window hidden until window_manager applies the saved geometry and
  // calls show() — prevents a visible jump from default size/position to saved.
  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}

/// Borderless, click-through, always-on-top window that pulses the whole
/// screen alongside the in-app Flash pulse (#80) — so a Flash is visible even
/// when Patch isn't the focused app, including over a fullscreen app in
/// another Space. Fully transparent and ordered off-screen while idle, so it
/// never appears as a blank window in the window switcher or a screenshot;
/// it's only ever shown, briefly, while actively pulsing.
private class FlashOverlayWindow: NSWindow {
  private let flashView = FlashOverlayView()
  private var generation = 0

  init() {
    super.init(
      contentRect: .zero,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false)

    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    ignoresMouseEvents = true
    isReleasedWhenClosed = false
    isExcludedFromWindowsMenu = true
    level = .screenSaver
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    contentView = flashView
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  /// Re-resolves the target display from [hostWindow] on every call — per
  /// #80's requirement that the overlay always covers the screen Patch
  /// currently occupies, never one cached from an earlier Flash — then
  /// (re)starts the pulse sequence. Bumping `generation` cancels any sequence
  /// already in flight, mirroring the Dart `_FlashLayer`'s `_pulseGen` guard
  /// so rapid repeated flashes restart cleanly instead of overlapping.
  func pulse(argb: Int, pulseCount: Int, near hostWindow: NSWindow?) {
    guard let screen = hostWindow?.screen ?? NSScreen.main else { return }
    setFrame(screen.frame, display: false)

    flashView.tintColor = NSColor(
      red: CGFloat((argb >> 16) & 0xFF) / 255.0,
      green: CGFloat((argb >> 8) & 0xFF) / 255.0,
      blue: CGFloat(argb & 0xFF) / 255.0,
      alpha: 1.0)

    let count = max(3, min(7, pulseCount))
    generation += 1
    orderFrontRegardless()
    runPulse(remaining: count, generation: generation)
  }

  private func runPulse(remaining: Int, generation: Int) {
    guard generation == self.generation, remaining > 0 else {
      if generation == self.generation {
        flashView.lit = false
        orderOut(nil)
      }
      return
    }
    flashView.lit = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      guard let self, generation == self.generation else { return }
      self.flashView.lit = false
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
        guard let self else { return }
        self.runPulse(remaining: remaining - 1, generation: generation)
      }
    }
  }
}

/// Draws a ~15% tint fill plus a solid colored border while [lit]; fully
/// transparent otherwise (idle state — see `FlashOverlayWindow` doc comment).
private class FlashOverlayView: NSView {
  var tintColor: NSColor = .clear {
    didSet { needsDisplay = true }
  }
  var lit: Bool = false {
    didSet { needsDisplay = true }
  }

  override var isOpaque: Bool { false }

  override func draw(_ dirtyRect: NSRect) {
    guard lit else { return }

    tintColor.withAlphaComponent(0.15).setFill()
    NSBezierPath(rect: bounds).fill()

    let borderWidth: CGFloat = 8
    let borderPath = NSBezierPath(rect: bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2))
    borderPath.lineWidth = borderWidth
    tintColor.setStroke()
    borderPath.stroke()
  }
}
