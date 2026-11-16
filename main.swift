// TrackEdge: slide along the left/right trackpad edges to change brightness/volume.
// Menu bar app (no Dock icon). Own implementation; uses private MultitouchSupport
// and DisplayServices frameworks, so macOS updates may break it.

import Cocoa
import CoreAudio
import ServiceManagement

enum Target { case volume, brightness }

// MARK: - Settings

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard
    init() {
        d.register(defaults: [
            "enabled": true, "swapSides": false, "haptics": true, "freeze": true,
            "quickMute": true, "mediaStrip": true, "edgeGlow": true, "reverseSwipe": false, "activeArea": 1.0, "sensitivity": 1.5, "edgeWidth": 0.06,
        ])
    }
    var enabled: Bool { get { d.bool(forKey: "enabled") } set { d.set(newValue, forKey: "enabled") } }
    var swapSides: Bool { get { d.bool(forKey: "swapSides") } set { d.set(newValue, forKey: "swapSides") } }
    var haptics: Bool { get { d.bool(forKey: "haptics") } set { d.set(newValue, forKey: "haptics") } }
    var freeze: Bool { get { d.bool(forKey: "freeze") } set { d.set(newValue, forKey: "freeze") } }
    var quickMute: Bool { get { d.bool(forKey: "quickMute") } set { d.set(newValue, forKey: "quickMute") } }
    var edgeGlow: Bool { get { d.bool(forKey: "edgeGlow") } set { d.set(newValue, forKey: "edgeGlow") } }
    var mediaStrip: Bool { get { d.bool(forKey: "mediaStrip") } set { d.set(newValue, forKey: "mediaStrip") } }
    var reverseSwipe: Bool { get { d.bool(forKey: "reverseSwipe") } set { d.set(newValue, forKey: "reverseSwipe") } }
    var activeArea: Double { get { d.double(forKey: "activeArea") } set { d.set(newValue, forKey: "activeArea") } }
    var sensitivity: Double { get { d.double(forKey: "sensitivity") } set { d.set(newValue, forKey: "sensitivity") } }
    var edgeWidth: Double { get { d.double(forKey: "edgeWidth") } set { d.set(newValue, forKey: "edgeWidth") } }
}

// MARK: - Volume (CoreAudio)

enum Audio {
    private static let volumeSelector: AudioObjectPropertySelector = 0x766D7663 // 'vmvc' virtual main volume

    private static func deviceID() -> AudioObjectID {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
        return id
    }

    private static func addr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel,
                                   mScope: kAudioObjectPropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func volume() -> Float {
        var a = addr(volumeSelector)
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectGetPropertyData(deviceID(), &a, 0, nil, &size, &v)
        return v
    }

    static func setVolume(_ v: Float) {
        var a = addr(volumeSelector)
        var value = Float32(v)
        AudioObjectSetPropertyData(deviceID(), &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    static func isMuted() -> Bool {
        var a = addr(kAudioDevicePropertyMute)
        var m: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID(), &a, 0, nil, &size, &m)
        return m != 0
    }

    static func setMuted(_ muted: Bool) {
        var a = addr(kAudioDevicePropertyMute)
        var m: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(deviceID(), &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
    }
}

// MARK: - Brightness (private DisplayServices)

enum Brightness {
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32

    private static let lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)

    private static let getFn: GetFn? = {
        guard let l = Brightness.lib, let s = dlsym(l, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(s, to: GetFn.self)
    }()
    private static let setFn: SetFn? = {
        guard let l = Brightness.lib, let s = dlsym(l, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(s, to: SetFn.self)
    }()

    private static func display() -> CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? CGMainDisplayID()
    }

    static func get() -> Float {
        var v: Float = 0.5
        _ = getFn?(display(), &v)
        return v
    }

    static func set(_ v: Float) {
        _ = setFn?(display(), v)
    }
}

// MARK: - HUD

final class BarView: NSView {
    var level: Float = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let segments = 16
        let gap: CGFloat = 2
        let w = (bounds.width - gap * CGFloat(segments - 1)) / CGFloat(segments)
        let filled = Int((level * Float(segments)).rounded())
        for i in 0..<segments {
            let r = NSRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: bounds.height)
            (i < filled ? NSColor.white : NSColor.white.withAlphaComponent(0.25)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

final class HUD {
    static let shared = HUD()
    private let panel: NSPanel
    private let icon = NSImageView()
    private let bar = BarView()
    private var hideWork: DispatchWorkItem?
    private let size = NSSize(width: 190, height: 190)

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 22
        fx.layer?.masksToBounds = true

        icon.frame = NSRect(x: 45, y: 70, width: 100, height: 90)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .white
        bar.frame = NSRect(x: 20, y: 30, width: 150, height: 9)

        fx.addSubview(icon)
        fx.addSubview(bar)
        panel.contentView = fx
    }

    private func symbol(_ target: Target, _ level: Float) -> String {
        switch target {
        case .brightness: return "sun.max.fill"
        case .volume:
            if level <= 0.001 { return "speaker.slash.fill" }
            if level < 0.34 { return "speaker.wave.1.fill" }
            if level < 0.67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        }
    }

    func show(_ target: Target, level: Float) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 70, weight: .regular)
        icon.image = NSImage(systemSymbolName: symbol(target, level), accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        bar.level = level

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        if let f = screen?.frame {
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 110))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                self.panel.animator().alphaValue = 0
            }, completionHandler: {
                if self.panel.alphaValue == 0 { self.panel.orderOut(nil) }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}

// MARK: - Edge glow (living light along the screen edge, follows your finger)

final class GlowView: NSView {
    var onRight = true
    var color: NSColor = .systemTeal
    var level: CGFloat = 0
    var fingerY: CGFloat = 0
    var velocity: CGFloat = 0
    var intensity: CGFloat = 0
    var phase: Double = 0

    override var isOpaque: Bool { false }

    private func cg(_ c: NSColor, _ alpha: CGFloat) -> CGColor {
        let r = c.usingColorSpace(.sRGB) ?? .white
        return CGColor(red: r.redComponent, green: r.greenComponent, blue: r.blueComponent, alpha: max(0, min(1, alpha)))
    }

    // Soft elliptical light source sitting on the screen edge.
    private func blob(_ ctx: CGContext, cy: CGFloat, rx: CGFloat, ry: CGFloat, color c: NSColor, alpha: CGFloat) {
        guard alpha > 0.003, ry > 1, rx > 1 else { return }
        let ex: CGFloat = onRight ? bounds.width : 0
        let colors = [cg(c, alpha), cg(c, alpha * 0.4), cg(c, alpha * 0.1), cg(c, 0)] as CFArray
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let grad = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.35, 0.7, 1]) else { return }
        ctx.saveGState()
        ctx.translateBy(x: ex, y: cy)
        ctx.scaleBy(x: 1, y: ry / rx)
        ctx.drawRadialGradient(grad, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: rx, options: [])
        ctx.restoreGState()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = bounds.width, h = bounds.height
        let breathe = 1 + 0.08 * CGFloat(sin(phase * 5.0))
        let shimmer = CGFloat(sin(phase * 2.3)) * 14
        let I = intensity * breathe
        let stretch = 1 + min(abs(velocity) * 0.0009, 1.3)   // streaks when you move fast
        let light = color.blended(withFraction: 0.55, of: .white) ?? .white

        // Ambient column: a soft wash from the bottom up to the current level.
        let colH = max(140, h * level)
        blob(ctx, cy: colH / 2, rx: w * 0.8, ry: colH / 2 + 110, color: color, alpha: 0.30 * I)

        // Halo around the finger.
        blob(ctx, cy: fingerY + shimmer, rx: w * 1.0, ry: 190 * stretch, color: color, alpha: 0.60 * I)

        // Bright core.
        blob(ctx, cy: fingerY, rx: w * 0.42, ry: 75 * stretch, color: light, alpha: 0.80 * I)
    }
}

final class EdgeGlow {
    static let shared = EdgeGlow()
    private let panel: NSPanel
    private let view = GlowView()
    private let width: CGFloat = 240
    private var timer: Timer?
    private let lock = NSLock()

    // Written from the trackpad thread, read on the main thread.
    private var fedY: Float = 0
    private var fedLevel: Float = 0
    private var fedActive = false

    // Animation state (main thread only).
    private var smoothY: CGFloat = 0
    private var smoothLevel: CGFloat = 0
    private var velocity: CGFloat = 0
    private var intensity: CGFloat = 0
    private var phase: Double = 0
    private var height: CGFloat = 800
    private var ending = false
    private var endTime: CFTimeInterval = 0

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 800),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = view
    }

    /// Thread-safe: called every trackpad frame.
    func feed(y: Float, level: Float, active: Bool) {
        lock.lock()
        fedY = y; fedLevel = level; fedActive = active
        lock.unlock()
    }

    func begin(right: Bool, target: Target, level: Float, y: Float, active: Bool) {
        ending = false
        view.onRight = right
        view.color = (target == .volume) ? .systemTeal : .systemYellow

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        if let f = screen?.frame {
            height = f.height
            panel.setFrame(NSRect(x: right ? f.maxX - width : f.minX, y: f.minY, width: width, height: f.height),
                           display: true)
        }
        feed(y: y, level: level, active: active)
        smoothY = CGFloat(y) * height
        smoothLevel = CGFloat(level)
        velocity = 0
        if !panel.isVisible { intensity = 0 }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    func end() {
        ending = true
        endTime = CACurrentMediaTime() + 0.25
    }

    private func tick() {
        lock.lock()
        let y = CGFloat(fedY), lvl = CGFloat(fedLevel), active = fedActive
        lock.unlock()

        let dt: CGFloat = 1.0 / 60.0
        var goal: CGFloat = active ? 1.0 : 0.5
        if ending && CACurrentMediaTime() >= endTime { goal = 0 }
        intensity += (goal - intensity) * (goal == 0 ? 0.10 : 0.20)

        let prev = smoothY
        smoothY += (y * height - smoothY) * 0.25
        velocity = velocity * 0.7 + ((smoothY - prev) / dt) * 0.3
        smoothLevel += (lvl - smoothLevel) * 0.2
        phase += Double(dt)

        view.intensity = intensity
        view.fingerY = smoothY
        view.level = smoothLevel
        view.velocity = velocity
        view.phase = phase
        view.needsDisplay = true

        if ending && goal == 0 && intensity < 0.01 {
            timer?.invalidate()
            timer = nil
            panel.orderOut(nil)
        }
    }
}

// MARK: - Multitouch (private MultitouchSupport)

struct MTPoint { var x: Float; var y: Float }
struct MTVector { var position: MTPoint; var velocity: MTPoint }
struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var pathIndex: Int32
    var state: Int32
    var fingerID: Int32
    var handID: Int32
    var normalizedVector: MTVector
    var zTotal: Float
    var field9: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absoluteVector: MTVector
    var field14: Int32
    var field15: Int32
    var zDensity: Float
}

typealias MTContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
private typealias MTCreateListFn = @convention(c) () -> Unmanaged<CFArray>?
private typealias MTRegisterFn = @convention(c) (UnsafeMutableRawPointer, MTContactCallback) -> Void
private typealias MTStartFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
private typealias MTStopFn = @convention(c) (UnsafeMutableRawPointer) -> Void
private typealias MTDimsFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32

private let contactCallback: MTContactCallback = { _, touches, count, timestamp, _ in
    Engine.shared.handle(touches, count: Int(count), time: timestamp)
    return 0
}

final class Multitouch {
    static let shared = Multitouch()
    private var lib: UnsafeMutableRawPointer?
    private var list: CFArray?
    private var devices: [UnsafeMutableRawPointer] = []

    func start() {
        stop()
        if lib == nil {
            lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
        }
        guard let lib = lib,
              let sCreate = dlsym(lib, "MTDeviceCreateList"),
              let sRegister = dlsym(lib, "MTRegisterContactFrameCallback"),
              let sStart = dlsym(lib, "MTDeviceStart") else {
            NSLog("TrackEdge: could not load MultitouchSupport")
            return
        }
        let create = unsafeBitCast(sCreate, to: MTCreateListFn.self)
        let register = unsafeBitCast(sRegister, to: MTRegisterFn.self)
        let startDev = unsafeBitCast(sStart, to: MTStartFn.self)
        let dims: MTDimsFn? = dlsym(lib, "MTDeviceGetSensorSurfaceDimensions").map { unsafeBitCast($0, to: MTDimsFn.self) }

        guard let arr = create()?.takeRetainedValue() else { return }
        list = arr
        for i in 0..<CFArrayGetCount(arr) {
            guard let raw = CFArrayGetValueAtIndex(arr, i) else { continue }
            let dev = UnsafeMutableRawPointer(mutating: raw)
            // Skip non-trackpad surfaces (e.g. Magic Mouse is narrow and tall).
            if let dims = dims {
                var w: Int32 = 0, h: Int32 = 0
                _ = dims(dev, &w, &h)
                if w > 0 && h > 0 && w < h { continue }
            }
            register(dev, contactCallback)
            startDev(dev, 0)
            devices.append(dev)
        }
    }

    func stop() {
        if let lib = lib, let sStop = dlsym(lib, "MTDeviceStop") {
            let stopDev = unsafeBitCast(sStop, to: MTStopFn.self)
            for d in devices { stopDev(d) }
        }
        devices.removeAll()
        list = nil
    }
}

// MARK: - Cursor lock (drops pointer-motion events while sliding)

private let cursorTapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = CursorLock.tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if CursorLock.frozen {
        // Safety net: never hold the pointer for more than a few seconds.
        if CACurrentMediaTime() - CursorLock.since > 4 { CursorLock.frozen = false }
        else { return nil }
    }
    return Unmanaged.passUnretained(event)
}

enum CursorLock {
    static var tap: CFMachPort?
    static var frozen = false
    static var since: CFTimeInterval = 0

    static func install() {
        CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        var mask: CGEventMask = 0
        for t in types { mask |= (1 << CGEventMask(t.rawValue)) }
        guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: cursorTapCallback, userInfo: nil) else {
            NSLog("TrackEdge: could not create event tap (grant Accessibility). Falling back to cursor warping.")
            return
        }
        tap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    static func freeze() { since = CACurrentMediaTime(); frozen = true }
    static func release() { frozen = false }
}

// MARK: - Media keys

enum MediaKey {
    static let play: Int32 = 16
    static let next: Int32 = 17
    static let previous: Int32 = 18

    static func send(_ key: Int32) {
        func post(down: Bool) {
            let state: Int32 = down ? 0xA : 0xB
            let flags = NSEvent.ModifierFlags(rawValue: UInt(state << 8))
            let data1 = Int((key << 16) | (state << 8))
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                               timestamp: 0, windowNumber: 0, context: nil,
                               subtype: 8, data1: data1, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
        post(down: true)
        post(down: false)
    }
}

// MARK: - Gesture engine

final class Engine {
    static let shared = Engine()

    private enum Mode { case idle, pending, sliding, swiped, ignored }
    private var mode: Mode = .idle
    private var target: Target?
    private var mediaCandidate = false
    private var cursorFrozen = false
    private var glowShown = false
    private var glowRight = true
    private var glowLevel: Float = 0
    private var savedCursor = CGPoint.zero
    private var startX: Float = 0
    private var startY: Float = 0
    private var lastY: Float = 0
    private var startTime: Double = 0
    private var maxTravel: Float = 0
    private var level: Float = 0
    private var lastApplied: Float = -1
    private var lastStep = -1
    private var unmutePending = false
    private var lastCornerTap: Double = -10
    private var lastStripTap: Double = -10

    func handle(_ raw: UnsafeMutableRawPointer?, count: Int, time: Double) {
        let s = Settings.shared
        var fingers: [MTTouch] = []
        if s.enabled, let raw = raw, count > 0 {
            let touches = raw.assumingMemoryBound(to: MTTouch.self)
            for i in 0..<count {
                let st = touches[i].state
                if st == 3 || st == 4 { fingers.append(touches[i]) } // making / touching
            }
        }

        // Fallback if the event tap is unavailable: pin the pointer every frame.
        if cursorFrozen && !fingers.isEmpty && CursorLock.tap == nil {
            CGWarpMouseCursorPosition(savedCursor)
        }

        // All fingers lifted
        if fingers.isEmpty {
            if mode == .pending, maxTravel < 0.03, time - startTime < 0.3 {
                if s.quickMute, startX >= 0.85, startY >= 0.8 { cornerTap(time) }
                else if mediaCandidate { stripTap(time) }
            }
            releaseCursor()
            endGlow()
            mode = .idle
            target = nil
            mediaCandidate = false
            return
        }

        // More than one finger: not an edge gesture
        if fingers.count > 1 {
            releaseCursor()
            endGlow()
            target = nil
            mode = .ignored
            return
        }

        let x = fingers[0].normalizedVector.position.x
        let y = fingers[0].normalizedVector.position.y

        switch mode {
        case .idle:
            let edge = Float(s.edgeWidth)
            var tgt: Target?
            if y <= Float(s.activeArea) {
                if x >= 1 - edge { tgt = s.swapSides ? .brightness : .volume }
                else if x <= edge { tgt = s.swapSides ? .volume : .brightness }
            }
            let corner = s.quickMute && x >= 0.85 && y >= 0.8
            let media = s.mediaStrip && tgt == nil && y <= 0.12 && x > edge && x < 1 - edge
            if tgt != nil || corner || media {
                mode = .pending
                target = tgt
                mediaCandidate = media
                startX = x; startY = y; startTime = time; maxTravel = 0
                savedCursor = CGEvent(source: nil)?.location ?? .zero
                // Freeze right away so the pointer never moves while sliding on an edge.
                if tgt != nil && s.freeze { freezeCursor() }
                glowRight = x > 0.5
                if let t = tgt, s.edgeGlow, !corner {
                    let l = (t == .volume) ? Audio.volume() : Brightness.get()
                    startGlow(t, level: l, y: y, active: false)
                }
            } else {
                mode = .ignored
            }

        case .pending:
            let dx = x - startX, dy = y - startY
            maxTravel = max(maxTravel, (dx * dx + dy * dy).squareRoot())
            let elapsed = time - startTime
            if glowShown { EdgeGlow.shared.feed(y: y, level: glowLevel, active: false) }

            if mediaCandidate {
                if abs(dx) > 0.12, abs(dx) > abs(dy) * 2, elapsed < 0.45 {
                    let forward = (dx > 0) != s.reverseSwipe
                    mediaSwipe(forward)
                    if s.freeze {
                        freezeCursor()
                        CGWarpMouseCursorPosition(savedCursor) // undo the little drift
                    }
                    mode = .swiped
                } else if abs(dy) > 0.08 || (elapsed > 0.45 && maxTravel > 0.03) {
                    mode = .ignored
                }
                return
            }

            if let t = target, abs(dy) > 0.025, abs(dy) > abs(dx) * 1.5 {
                beginSlide(t, y: y)
                mode = .sliding
            } else if maxTravel > 0.06 {
                releaseCursor()
                endGlow()
                mode = .ignored // sideways swipe etc.: leave it alone
            }

        case .sliding:
            let dy = y - lastY
            lastY = y
            if dy == 0 { return }
            let precise = CGEventSource.flagsState(.combinedSessionState).contains([.maskShift, .maskAlternate])
            let gain = Float(s.sensitivity) * (precise ? 0.25 : 1.0)
            level = min(1, max(0, level + dy * gain))
            if glowShown { EdgeGlow.shared.feed(y: y, level: level, active: true) }
            apply()

        case .swiped, .ignored:
            break
        }
    }

    // MARK: Glow

    private func startGlow(_ t: Target, level l: Float, y: Float, active: Bool) {
        glowShown = true
        glowLevel = l
        let right = glowRight
        DispatchQueue.main.async { EdgeGlow.shared.begin(right: right, target: t, level: l, y: y, active: active) }
    }

    private func endGlow() {
        if glowShown {
            glowShown = false
            DispatchQueue.main.async { EdgeGlow.shared.end() }
        }
    }

    // MARK: Cursor

    private func freezeCursor() {
        if !cursorFrozen {
            CursorLock.freeze()
            CGAssociateMouseAndMouseCursorPosition(0)
            cursorFrozen = true
        }
    }

    func releaseCursor() {
        if cursorFrozen {
            CursorLock.release()
            CGAssociateMouseAndMouseCursorPosition(1)
            cursorFrozen = false
        }
    }

    // MARK: Slide

    private func beginSlide(_ t: Target, y: Float) {
        target = t
        lastY = y
        lastApplied = -1
        switch t {
        case .volume:
            level = Audio.volume()
            unmutePending = Audio.isMuted()
        case .brightness:
            level = Brightness.get()
            unmutePending = false
        }
        lastStep = Int((level * 16).rounded())
        if Settings.shared.freeze { freezeCursor() }
        if Settings.shared.edgeGlow {
            if glowShown {
                EdgeGlow.shared.feed(y: y, level: level, active: true)
            } else {
                startGlow(t, level: level, y: y, active: true)
            }
        }
    }

    private func apply() {
        guard let t = target else { return }
        let atLimit = level <= 0 || level >= 1
        if abs(level - lastApplied) < 0.004 && !(atLimit && level != lastApplied) { return }
        lastApplied = level
        let lvl = level

        switch t {
        case .volume:
            if unmutePending && lvl > 0 { Audio.setMuted(false); unmutePending = false }
            Audio.setVolume(lvl)
        case .brightness:
            Brightness.set(lvl)
        }

        let step = Int((lvl * 16).rounded())
        let tick = step != lastStep
        lastStep = step
        let haptics = Settings.shared.haptics
        DispatchQueue.main.async {
            HUD.shared.show(t, level: lvl)
            if tick && haptics {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
        }
    }

    // MARK: Taps and media

    private func cornerTap(_ now: Double) {
        if now - lastCornerTap < 0.45 {
            lastCornerTap = -10
            let m = !Audio.isMuted()
            Audio.setMuted(m)
            let v: Float = m ? 0 : Audio.volume()
            let haptics = Settings.shared.haptics
            DispatchQueue.main.async {
                HUD.shared.show(.volume, level: v)
                if haptics { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
            }
        } else {
            lastCornerTap = now
        }
    }

    private func stripTap(_ now: Double) {
        if now - lastStripTap < 0.45 {
            lastStripTap = -10
            let haptics = Settings.shared.haptics
            DispatchQueue.main.async {
                MediaKey.send(MediaKey.play)
                if haptics { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
            }
        } else {
            lastStripTap = now
        }
    }

    private func mediaSwipe(_ forward: Bool) {
        let haptics = Settings.shared.haptics
        DispatchQueue.main.async {
            MediaKey.send(forward ? MediaKey.next : MediaKey.previous)
            if haptics { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
        }
    }
}

// MARK: - Menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "TrackEdge")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        CursorLock.install()
        Multitouch.shared.start()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(restartTouch),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        CursorLock.release()
        CGAssociateMouseAndMouseCursorPosition(1)
        Multitouch.shared.stop()
    }

    @objc private func restartTouch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Multitouch.shared.start() }
    }

    // Menu

    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, on: Bool = false, value: Double? = nil) {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        if let v = value { item.representedObject = v }
        menu.addItem(item)
    }

    private func submenu(_ menu: NSMenu, _ title: String, current: Double, options: [(String, Double)], action: Selector) {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (name, v) in options {
            add(sub, name, action, on: abs(current - v) < 0.001, value: v)
        }
        parent.submenu = sub
        menu.addItem(parent)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = Settings.shared
        add(menu, "Enabled", #selector(toggleEnabled), on: s.enabled)
        menu.addItem(.separator())
        add(menu, "Swap Sides (brightness on right)", #selector(toggleSwap), on: s.swapSides)
        add(menu, "Haptic Feedback", #selector(toggleHaptics), on: s.haptics)
        add(menu, "Freeze Cursor While Sliding", #selector(toggleFreeze), on: s.freeze)
        add(menu, "Quick Mute (double-tap top-right corner)", #selector(toggleQuickMute), on: s.quickMute)
        add(menu, "Edge Glow", #selector(toggleGlow), on: s.edgeGlow)
        add(menu, "Media Strip (swipe bottom edge, double-tap to play/pause)", #selector(toggleMedia), on: s.mediaStrip)
        add(menu, "Reverse Media Swipe", #selector(toggleReverse), on: s.reverseSwipe)
        menu.addItem(.separator())
        submenu(menu, "Active Area", current: s.activeArea,
                options: [("Full edge", 1.0), ("Bottom ¾", 0.75), ("Bottom half", 0.5), ("Bottom quarter", 0.25)],
                action: #selector(setArea(_:)))
        submenu(menu, "Sensitivity", current: s.sensitivity,
                options: [("Low", 1.0), ("Medium", 1.5), ("High", 2.2)],
                action: #selector(setSensitivity(_:)))
        submenu(menu, "Edge Width", current: s.edgeWidth,
                options: [("Narrow", 0.04), ("Default", 0.06), ("Wide", 0.09), ("Wider", 0.12)],
                action: #selector(setEdge(_:)))
        menu.addItem(.separator())
        add(menu, "Open at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        add(menu, "Quit TrackEdge", #selector(quit))
    }

    @objc private func toggleEnabled() { Settings.shared.enabled.toggle() }
    @objc private func toggleSwap() { Settings.shared.swapSides.toggle() }
    @objc private func toggleHaptics() { Settings.shared.haptics.toggle() }
    @objc private func toggleFreeze() { Settings.shared.freeze.toggle() }
    @objc private func toggleQuickMute() { Settings.shared.quickMute.toggle() }
    @objc private func toggleGlow() { Settings.shared.edgeGlow.toggle() }
    @objc private func toggleMedia() { Settings.shared.mediaStrip.toggle() }
    @objc private func toggleReverse() { Settings.shared.reverseSwipe.toggle() }
    @objc private func setArea(_ s: NSMenuItem) { if let v = s.representedObject as? Double { Settings.shared.activeArea = v } }
    @objc private func setSensitivity(_ s: NSMenuItem) { if let v = s.representedObject as? Double { Settings.shared.sensitivity = v } }
    @objc private func setEdge(_ s: NSMenuItem) { if let v = s.representedObject as? Double { Settings.shared.edgeWidth = v } }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            NSSound.beep()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
