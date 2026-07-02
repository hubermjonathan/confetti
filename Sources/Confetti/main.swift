import AppKit
import QuartzCore
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Confetti overlay window

final class ConfettiWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ConfettiOverlay {
    private var window: ConfettiWindow?
    private var isFiring = false

    private static let colors: [NSColor] = [
        .systemPink, .systemOrange, .systemYellow,
        .systemGreen, .systemBlue, .systemPurple, .systemTeal
    ]
    private static let gravity: CGFloat = 1400         // heavier fall
    private static let flightTime: CGFloat = 1.4       // shorter → keeps initial velo modest despite big g
    private static let apexLift: CGFloat = 0.42        // aim well above center → steeper angle
    private static let aimFraction: CGFloat = 0.55     // aim toward 55% of way to center (lowers vx → slower exit)
    private static let particlesPerCannonRef = 160     // reference count at 2560x1440 (halved from 320)
    private static let referencePixels: CGFloat = 2560 * 1440
    private static let subBurstCount = 12              // 12 sub-bursts of ~27 particles each
    private static let subBurstGap: CFTimeInterval = 0.033 // every-other frame @ 60fps — 0.017 collided with vsync commit
    private static let launchJitter: CFTimeInterval = 0.05 // per-particle jitter within its sub-burst
    private static let spreadAngle: CGFloat = .pi / 6  // ±30° cone (a bit wider)
    private static let sizeRange: ClosedRange<CGFloat> = 28...44
    private static let lifetime: CFTimeInterval = 2.2       // flightTime + short tail; heavier g clears screen faster
    private static let dragK: CGFloat = 0.8                 // horizontal drag coefficient
    private static let trajectorySteps: Int = 10            // keyframe samples (cubic interp keeps smooth)
    private static let swayAmpFrac: ClosedRange<CGFloat> = 0.002 ... 0.01 // A ∈ [0.2%, 1%] of screen width
    private static let swayFreqHz:  ClosedRange<CGFloat> = 0.6 ... 1.4    // slower ω in Hz

    enum Shape: CaseIterable { case rect, triangle, circle }
    private static let allShapes: [Shape] = Shape.allCases   // hoisted (avoid rebuild per-particle)

    // Preallocate the overlay window + tint cache at app launch so the first hotkey
    // press doesn't pay window/backing-store setup or CGImage draw cost. Do NOT
    // order the window in here — a fullscreen transparent .screenSaver window that
    // stays ordered-in defeats direct scan-out system-wide (ProMotion downshift,
    // fullscreen-app composite hit) even when confetti isn't firing. fire() orders
    // in on demand, teardown orderOuts.
    func prewarm() {
        _ = ensureWindow()
        for color in Self.colors {
            for shape in Self.allShapes {
                _ = Self.tintedImage(shape: shape, color: color)
            }
        }
    }

    private func ensureWindow() -> ConfettiWindow {
        if let w = window { return w }
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let frame = screen.frame
        let w = ConfettiWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .screenSaver
        w.ignoresMouseEvents = true
        // Dropped .fullScreenAuxiliary: pulls the overlay into other apps' native-
        // fullscreen composites (video/games/Keynote), tanking their direct scan-out.
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.isReleasedWhenClosed = false

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let layer = CALayer()
        // Perspective set once on container — kids inherit via sublayerTransform.
        var perspective = CATransform3DIdentity
        perspective.m34 = -1.0 / 500.0
        layer.sublayerTransform = perspective
        view.layer = layer
        w.contentView = view
        window = w
        particleContentsScale = screen.backingScaleFactor
        return w
    }

    func fire() {
        if isFiring { return }
        isFiring = true

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let frame = screen.frame
        let w = ensureWindow()

        w.setFrame(frame, display: false)
        w.alphaValue = 1
        w.orderFrontRegardless()               // only ordered in during fire; orderOut on teardown

        guard let host = w.contentView?.layer else {
            isFiring = false
            return
        }

        // Spawn exactly at bottom corners
        let leftPos  = CGPoint(x: host.bounds.minX, y: host.bounds.minY)
        let rightPos = CGPoint(x: host.bounds.maxX, y: host.bounds.minY)

        // Per-sub-burst aim sweep: start high, drop to previous-baseline (never below).
        // Cap absolute apex y so small screens (built-in retina) don't shoot off the top.
        // Arc peak y ≈ vy²/(2g) above cannon; with our flightTime the peak is roughly
        // 1.1× the aim-target height. So keep target y under 0.75·H to leave ~10% headroom.
        let hHeight = host.bounds.height
        let maxTargetY = hHeight * 0.75
        let apexHighFrac: CGFloat = Self.apexLift + 0.18

        func shots(subBurstIdx: Int) -> (Shot, Shot) {
            let n = max(1, Self.subBurstCount - 1)
            let frac = CGFloat(subBurstIdx) / CGFloat(n)
            let a = apexHighFrac + (Self.apexLift - apexHighFrac) * frac
            let rawTargetY = host.bounds.midY + hHeight * a
            let clampedY = min(rawTargetY, maxTargetY)
            let aimPt = CGPoint(x: host.bounds.midX, y: clampedY)
            let l = ballisticShot(from: leftPos,  to: CGPoint(
                x: leftPos.x  + (aimPt.x - leftPos.x)  * Self.aimFraction,
                y: leftPos.y  + (aimPt.y - leftPos.y)  * Self.aimFraction))
            let r = ballisticShot(from: rightPos, to: CGPoint(
                x: rightPos.x + (aimPt.x - rightPos.x) * Self.aimFraction,
                y: rightPos.y + (aimPt.y - rightPos.y) * Self.aimFraction))
            return (l, r)
        }
        // Container layer per press so teardown is one removeFromSuperlayer.
        // Inherits perspective from host's sublayerTransform.
        let container = CALayer()
        container.frame = host.bounds
        host.addSublayer(container)

        // Scale particle count by screen pixel area (√ so it grows/shrinks gently).
        // Ref: 2560×1440 → 510. 5120×2880 → ~720. 1440×900 → ~305.
        let pixels = host.bounds.width * host.bounds.height
        let scale = sqrt(pixels / Self.referencePixels)
        let particlesPerCannon = max(80, Int(CGFloat(Self.particlesPerCannonRef) * scale))

        // Every sub-burst is async — even the first. fire() is called from the
        // Carbon InstallEventHandler C callback which must return before the OS
        // dispatches further input; doing ~60 layer allocations + 60 CGPath builds
        // synchronously stalled input dispatch. All bursts hop off the callback.
        let per = particlesPerCannon / Self.subBurstCount
        for i in 0..<Self.subBurstCount {
            let delay = CFTimeInterval(i) * Self.subBurstGap
            let (l, r) = shots(subBurstIdx: i)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak container] in
                guard let self, let container else { return }
                self.spawnBurst(at: leftPos,  shot: l, count: per, into: container)
                self.spawnBurst(at: rightPos, shot: r, count: per, into: container)
            }
        }

        // Teardown container after animations complete; order the window OUT
        // (not just alpha=0) so the compositor drops it from the z-order and
        // direct scan-out is available to every other app while idle. Unlock
        // isFiring here too — the previous 1s early-unlock let re-fires stack
        // an entire second layer set on top of the still-attached old one
        // (both keyframe animations are isRemovedOnCompletion=false).
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lifetime + 0.5) { [weak self, weak container] in
            container?.removeFromSuperlayer()
            if let w = self?.window,
               w.contentView?.layer?.sublayers?.isEmpty ?? true {
                w.alphaValue = 0
                w.orderOut(nil)
            }
            self?.isFiring = false
        }
    }

    struct Shot { let angle: CGFloat; let speed: CGFloat }

    // Solve for initial vx, vy so particle reaches `to` at t=T under gravity g
    // and horizontal drag k (exponential decay of horizontal velocity).
    // Horizontal: x(t) = x0 + (vx/k)(1 − e^(−kT))
    // Vertical:   y(t) = y0 + vy·T − ½ g T²   (no vertical drag; keeps arc predictable)
    private func ballisticShot(from: CGPoint, to: CGPoint) -> Shot {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let g = Self.gravity
        let T = Self.flightTime
        let k = Self.dragK
        let decay = 1 - exp(-k * T)
        let vx = dx * k / decay
        let vy = (dy + 0.5 * g * T * T) / T
        return Shot(angle: atan2(vy, vx), speed: sqrt(vx * vx + vy * vy))
    }

    // Fast xorshift-style RNG. arc4random via CGFloat.random is thread-safe locked +
    // syscall-ish — expensive at ~15 calls/particle × 1000 particles.
    struct FastRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
    private var rng = FastRNG(state: 0xC0FFEE)

    private func rand(in range: ClosedRange<CGFloat>) -> CGFloat {
        CGFloat.random(in: range, using: &rng)
    }

    private func spawnBurst(at pos: CGPoint, shot: Shot, count: Int, into container: CALayer) {
        let host = container.bounds
        let g = Self.gravity
        let T = CGFloat(Self.lifetime)
        let k = Self.dragK
        let steps = Self.trajectorySteps
        let screenW = host.width

        let now = CACurrentMediaTime()

        // Precompute time-varying scalars once per burst (all particles share them).
        // Removes ~11 exp() and 11 mult per particle from the hot loop.
        let dt = T / CGFloat(steps)
        var tArr = [CGFloat](repeating: 0, count: steps + 1)
        var xFactor = [CGFloat](repeating: 0, count: steps + 1)   // (1 - exp(-k·t)) / k
        var yQuad = [CGFloat](repeating: 0, count: steps + 1)     // -0.5 · g · t²
        for i in 0...steps {
            let t = CGFloat(i) * dt
            tArr[i] = t
            xFactor[i] = (1 - exp(-k * t)) / k
            yQuad[i] = -0.5 * g * t * t
        }

        // No explicit CATransaction: addSublayer does not trigger implicit actions
        // (position/opacity are set before insertion), and forcing 2 commits per
        // sub-burst × 12 sub-bursts = 24 IPC round-trips to WindowServer per fire.
        // Runloop's implicit transaction coalesces both cannons per wake into one.
        for i in 0..<count {
            // Per-particle randomized launch within cone + wide speed scatter.
            // Every 6th particle: bias angle steeper + fatter speed → paints top-middle.
            let steepBias = (i % 6 == 0)
            let angleJitter = rand(in: -Self.spreadAngle...Self.spreadAngle)
            let extraLift: CGFloat = steepBias ? .pi * 0.10 : 0    // ~18° more vertical
            var angle = shot.angle + angleJitter + extraLift
            // Clamp: never rotate past vertical toward the outward wall.
            // Cannon's original aim is inward+up; if jitter+lift pushes past 90° from
            // horizontal (toward the near wall), reflect back. Keeps a ~5° safety margin.
            let inwardSign: CGFloat = cos(shot.angle) >= 0 ? 1 : -1
            let maxAngleFromHoriz: CGFloat = .pi / 2 - .pi / 36            // 85°
            let minAngleFromHoriz: CGFloat = .pi / 12                       // 15° above horiz
            if inwardSign > 0 {
                angle = min(max(angle, minAngleFromHoriz), maxAngleFromHoriz)
            } else {
                angle = min(max(angle, .pi - maxAngleFromHoriz), .pi - minAngleFromHoriz)
            }
            // Floor 0.55: mid between old 0.4 (too many stalled at cannon)
            // and 0.75 (overshot center).
            let speedRange: ClosedRange<CGFloat> = steepBias ? (1.15 ... 1.55) : (0.55 ... 1.3)
            let speed = shot.speed * rand(in: speedRange)
            let vx = cos(angle) * speed
            let vy = sin(angle) * speed

            // Small per-particle jitter within this sub-burst so shell isn't perfectly synced,
            // but coherent enough to look like a shot leaving the cannon.
            let launchDelay = CFTimeInterval(rand(in: 0 ... CGFloat(Self.launchJitter)))

            let baseSize = rand(in: Self.sizeRange)
            let color = Self.colors.randomElement(using: &rng)!
            let shape = Self.allShapes.randomElement(using: &rng)!

            // Per-shape scale: rects render larger overall; triangles slightly smaller;
            // circles unchanged. Multiplier applies to the layer bounds, not the tile.
            let shapeScale: CGFloat
            switch shape {
            case .rect:     shapeScale = 1.35
            case .triangle: shapeScale = 0.85
            case .circle:   shapeScale = 1.0
            }
            let size = baseSize * shapeScale

            let particle = makeParticleLayer(shape: shape, color: color, size: size)
            particle.position = pos
            particle.opacity = 0                  // hidden until launched

            // Sway direction: random 2D unit vector (not tied to flight direction).
            // With flight direction tied swap, adjacent particles sway in-phase perpendicular to
            // same axis → visible cone. Random axis per particle scrambles that.
            let swayDir = rand(in: 0 ... (2 * .pi))
            let perpX = cos(swayDir)
            let perpY = sin(swayDir)

            let swayAmp   = screenW * rand(in: Self.swayAmpFrac)
            let swayOmega = 2 * .pi * rand(in: Self.swayFreqHz)   // rad/s
            let swayPhase = rand(in: 0 ... (2 * .pi))

            // Position keyframe as CGPath — no NSValue boxing.
            // Uses precomputed xFactor/yQuad arrays (no exp/mul in loop).
            let path = CGMutablePath()
            for i in 0...steps {
                let t = tArr[i]
                let ballisticX = pos.x + vx * xFactor[i]
                let ballisticY = pos.y + vy * t + yQuad[i]
                let s = swayAmp * sin(swayOmega * t + swayPhase)
                let x = ballisticX + perpX * s
                let y = ballisticY + perpY * s
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else      { path.addLine(to: CGPoint(x: x, y: y)) }
            }

            let startAt = now + launchDelay

            let posAnim = CAKeyframeAnimation(keyPath: "position")
            posAnim.path = path
            posAnim.duration = CFTimeInterval(T)
            posAnim.beginTime = startAt
            posAnim.calculationMode = .linear   // path already smooth; skip cubic cost
            posAnim.fillMode = .forwards
            posAnim.isRemovedOnCompletion = false

            // 3D tumble: 3 cheap linear rotations (grouped w/ opacity in one CAAnimationGroup).
            let rotX = CABasicAnimation(keyPath: "transform.rotation.x")
            rotX.fromValue = 0
            rotX.toValue = CGFloat.random(in: -6 * .pi ... 6 * .pi, using: &rng)

            let rotY = CABasicAnimation(keyPath: "transform.rotation.y")
            rotY.fromValue = 0
            rotY.toValue = CGFloat.random(in: -8 * .pi ... 8 * .pi, using: &rng)

            let rotZ = CABasicAnimation(keyPath: "transform.rotation.z")
            rotZ.fromValue = 0
            rotZ.toValue = CGFloat.random(in: -4 * .pi ... 4 * .pi, using: &rng)

            // Reveal + fade as keyframe on same opacity path
            let fadeDur: CFTimeInterval = 0.6
            let fadeStartFrac = (CFTimeInterval(T) - fadeDur) / CFTimeInterval(T)
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0.0, 1.0, 1.0, 0.0]
            opacity.keyTimes = [0.0, 0.001, NSNumber(value: fadeStartFrac), 1.0]

            let group = CAAnimationGroup()
            group.animations = [rotX, rotY, rotZ, opacity]
            group.duration = CFTimeInterval(T)
            group.beginTime = startAt
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false

            particle.add(posAnim, forKey: "pos")
            particle.add(group,   forKey: "grp")
            container.addSublayer(particle)
        }
    }

    // Cached at first ensureWindow(); avoids per-particle NSScreen.main lookup.
    private var particleContentsScale: CGFloat = 2.0

    private func makeParticleLayer(shape: Shape, color: NSColor, size: CGFloat) -> CALayer {
        let layer = CALayer()
        // Perspective inherited from container's sublayerTransform; no per-particle m34.
        layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.contents = Self.tintedImage(shape: shape, color: color)
        layer.contentsGravity = .resizeAspect
        // Match backing store so CA doesn't upscale the 32×32 CGImage per frame.
        layer.contentsScale = particleContentsScale
        return layer
    }

    // MARK: Shape drawing (colored, transparent bg)

    private static var tintCache: [String: CGImage] = [:]

    private static func tintedImage(shape: Shape, color: NSColor) -> CGImage {
        let key = "\(shape)-\(color.hashValue)"
        if let hit = tintCache[key] { return hit }

        let size = 32
        // sRGB (not deviceRGB): matches CA's default composite space on wide-gamut
        // panels; avoids per-frame ColorSync conversion on every particle.
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
        let rgb = color.usingColorSpace(.deviceRGB) ?? .white
        ctx.setFillColor(CGColor(red: rgb.redComponent, green: rgb.greenComponent,
                                 blue: rgb.blueComponent, alpha: 1))
        let inset: CGFloat = 3
        let s = CGFloat(size)
        switch shape {
        case .rect:
            // Long paper-strip rect: full tile width, 34% height → ~3:1 aspect.
            ctx.fill(CGRect(x: 0, y: s * 0.33, width: s, height: s * 0.34))
        case .triangle:
            // Slightly smaller triangle: ~75% of tile, centered.
            let t = s * 0.75
            let ox = (s - t) / 2
            let oy = (s - t) / 2
            ctx.beginPath()
            ctx.move(to: CGPoint(x: ox, y: oy))
            ctx.addLine(to: CGPoint(x: ox + t, y: oy))
            ctx.addLine(to: CGPoint(x: ox + t / 2, y: oy + t))
            ctx.closePath()
            ctx.fillPath()
        case .circle:
            // Smaller dot — 60% of tile, centered.
            let d = s * 0.60
            ctx.fillEllipse(in: CGRect(x: (s - d) / 2, y: (s - d) / 2,
                                       width: d, height: d))
        }
        let img = ctx.makeImage()!
        tintCache[key] = img
        return img
    }
}

// MARK: - Global hotkey (Carbon)

final class GlobalHotkey {
    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var handler: (() -> Void)?

    // Default: ⌃⌥⌘ C
    func register(keyCode: UInt32 = UInt32(kVK_ANSI_C),
                  modifiers: UInt32 = UInt32(controlKey | optionKey | cmdKey),
                  handler: @escaping () -> Void) {
        self.handler = handler

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData = userData, let event = event else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let me = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
            me.handler?()
            return noErr
        }, 1, &spec, selfPtr, &eventHandler)
        if installStatus != noErr {
            NSLog("Confetti: InstallEventHandler failed (OSStatus %d) — hotkey inactive", installStatus)
            return
        }

        let hkID = EventHotKeyID(signature: OSType(0x43464554 /* 'CFET' */), id: 1)
        let registerStatus = RegisterEventHotKey(keyCode, modifiers, hkID,
                                                 GetApplicationEventTarget(), 0, &hotKeyRef)
        if registerStatus != noErr {
            NSLog("Confetti: RegisterEventHotKey failed (OSStatus %d) — likely conflict with another app; use menu to fire", registerStatus)
        }
    }

    deinit {
        if let h = hotKeyRef { UnregisterEventHotKey(h) }
        if let e = eventHandler { RemoveEventHandler(e) }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let overlay = ConfettiOverlay()
    private let hotkey = GlobalHotkey()

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Pre-create overlay window so first hotkey press doesn't pay WindowServer setup cost.
        overlay.prewarm()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "🎉"
            button.toolTip = "Confetti — ⌃⌥⌘C to fire"
        }

        let menu = NSMenu()
        let fire = NSMenuItem(title: "Fire Confetti",
                              action: #selector(fireFromMenu),
                              keyEquivalent: "c")
        fire.keyEquivalentModifierMask = [.control, .option, .command]
        menu.addItem(fire)
        menu.addItem(.separator())
        let launch = NSMenuItem(title: "Launch at Login",
                                action: #selector(toggleLaunchAtLogin),
                                keyEquivalent: "")
        launch.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(launch)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        statusItem.menu = menu

        hotkey.register { [weak self] in self?.overlay.fire() }
    }

    @objc private func fireFromMenu() {
        overlay.fire()
    }

    // MARK: Launch at login (SMAppService, macOS 13+)

    private var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if launchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            sender.state = launchAtLoginEnabled ? .on : .off
        } catch {
            let alert = NSAlert()
            alert.messageText = "Launch at Login failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
