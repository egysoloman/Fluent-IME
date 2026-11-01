import AppKit
import FluentKit

/// A snapshot stops being valid when its viewport changes; settle on the live content.
private final class IMEMotionObservation {
    private var geometryObservers: [NSObjectProtocol] = []
    private var motionObserver: NSObjectProtocol?
    init(view: NSView, cancel: @escaping () -> Void) {
        let frame = view.frame, bounds = view.bounds
        for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
            geometryObservers.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak view] _ in
                guard let view, view.frame != frame || view.bounds != bounds else { return }
                cancel()
            })
        }
        if let window = view.window {
            geometryObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in cancel() })
        }
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { _ in
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { cancel() }
        }
    }
    deinit {
        geometryObservers.forEach(NotificationCenter.default.removeObserver)
        if let motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(motionObserver) }
    }
}

/// Shared native page choreography, driven by WinUI-macOS motion tokens.
/// Snapshots are visual-only layers; hit testing and accessibility always use the new page.
final class IMEPageMotion {
    struct Snapshot { let image: CGImage; let bounds: CGRect }
    private var outgoing: CALayer?
    private weak var incoming: CALayer?
    private var generation: UInt64 = 0
    private var observation: IMEMotionObservation?
    func capture(_ viewport: NSView) -> Snapshot? {
        guard viewport.window?.isVisible == true,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              viewport.bounds.width > 0, viewport.bounds.height > 0 else { return nil }
        viewport.wantsLayer = true
        viewport.layoutSubtreeIfNeeded(); viewport.displayIfNeeded(); CATransaction.flush()
        let scale = viewport.window?.backingScaleFactor ?? 1
        guard let layer = viewport.layer,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(ceil(viewport.bounds.width * scale)), pixelsHigh: Int(ceil(viewport.bounds.height * scale)),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext else { return nil }
        context.scaleBy(x: scale, y: scale)
        if viewport.isFlipped {
            context.translateBy(x: 0, y: viewport.bounds.height); context.scaleBy(x: 1, y: -1)
        }
        // A rapid reversal must start from the visible composite, including the outgoing page
        // and partially completed entrance. cacheDisplay captures the new model page instead.
        (layer.presentation() ?? layer).render(in: context)
        guard let image = bitmap.cgImage else { return nil }
        return Snapshot(image: image, bounds: viewport.bounds)
    }
    func play(_ snapshot: Snapshot?, in viewport: NSView, content: NSView, backward: Bool, navigation: Bool = false) {
        cancel()
        let current = generation
        content.wantsLayer = true
        content.layer?.removeAnimation(forKey: "FluentIME.Page.Entrance")
        guard let snapshot, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        viewport.wantsLayer = true
        guard let host = viewport.layer, let incoming = content.layer else { return }
        self.incoming = incoming
        let old = CALayer(); old.contents = snapshot.image
        // Navigation may add/remove the scroll bar before playback. Keep the captured pixels
        // at their original size and clip the edge instead of stretching or suppressing motion.
        old.frame = CGRect(origin: viewport.bounds.origin, size: snapshot.bounds.size)
        old.contentsGravity = .resize; old.zPosition = 10; host.addSublayer(old); outgoing = old
        let motion = navigation ? FluentMotion.navigationPageSlideEntrance : FluentMotion.controlFast
        let exit = navigation ? FluentMotion.navigationPageExit : FluentMotion.controlFaster
        let distance: CGFloat = navigation ? 40 : 24
        let direction: CGFloat = backward ? -1 : 1
        func animation(_ from: CGFloat, _ to: CGFloat, opacity: [Float], token: FluentMotionToken) -> CAAnimationGroup {
            let slide = CABasicAnimation(keyPath: "transform.translation.x"); slide.fromValue = from; slide.toValue = to
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = opacity[0]; fade.toValue = opacity[1]
            let group = CAAnimationGroup(); group.animations = [slide, fade]
            group.duration = token.duration; group.timingFunction = token.curve.timingFunction
            group.beginTime = CACurrentMediaTime() + token.delay
            group.fillMode = .both; group.isRemovedOnCompletion = false
            return group
        }
        incoming.add(animation(direction * distance, 0, opacity: [0, 1], token: motion), forKey: "FluentIME.Page.Entrance")
        old.add(animation(0, -direction * distance / 2, opacity: [1, 0], token: exit), forKey: "FluentIME.Page.Exit")
        observation = IMEMotionObservation(view: viewport) { [weak self] in self?.cancel() }
        DispatchQueue.main.asyncAfter(deadline: .now() + motion.delay + motion.duration) { [weak self] in
            guard let self, self.generation == current else { return }
            self.cancel()
        }
    }
    func cancel() {
        generation &+= 1
        outgoing?.removeFromSuperlayer(); outgoing = nil
        incoming?.removeAnimation(forKey: "FluentIME.Page.Entrance"); incoming = nil
        observation = nil
    }
    deinit { cancel() }
}

/// Animates only the leading title-bar controls. Search and window controls stay fixed.
final class IMETitleBarMotion {
    struct Snapshot {
        let titleX: CGFloat
        let backImage: CGImage?
        let backFrame: CGRect
        let backOpacity: Float
    }
    private var outgoing: CALayer?
    private var outgoingImage: CGImage?
    private weak var animatedTitle: CALayer?
    private weak var animatedBack: CALayer?
    private var observation: IMEMotionObservation?
    private var generation: UInt64 = 0
    private let animationKey = "FluentIME.TitleBar.Visibility"

    private func item(_ name: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == "FluentKit.TitleBar." + name { return view }
        for child in view.subviews { if let found = item(name, in: child) { return found } }
        return nil
    }

    func capture(_ host: NSView) -> Snapshot? {
        guard host.window?.isVisible == true,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let title = item("Title", in: host), let back = item("Back", in: host) else { return nil }
        host.layoutSubtreeIfNeeded()
        var image: CGImage?
        var backFrame = back.convert(back.bounds, to: host)
        var backOpacity: Float = 0
        if !back.isHidden, let bitmap = back.bitmapImageRepForCachingDisplay(in: back.bounds) {
            back.cacheDisplay(in: back.bounds, to: bitmap); image = bitmap.cgImage
            let presentation = back.layer?.presentation()
            backFrame.origin.x += presentation?.transform.m41 ?? 0
            backOpacity = presentation?.opacity ?? 1
        } else if let outgoing, let outgoingImage {
            // During a rapid return to a detail page the real back button is already hidden,
            // but its outgoing image is still visible. Resume from that image's current state.
            let presentation = outgoing.presentation() ?? outgoing
            image = outgoingImage; backFrame = presentation.frame; backOpacity = presentation.opacity
        }
        let offset = title.layer?.presentation()?.transform.m41 ?? 0
        return Snapshot(titleX: title.convert(title.bounds, to: host).minX + offset,
                        backImage: image, backFrame: backFrame, backOpacity: backOpacity)
    }

    func play(_ snapshot: Snapshot, in host: NSView, showingBack: Bool) {
        cancel()
        let current = generation
        guard let title = item("Title", in: host), let back = item("Back", in: host) else { return }
        title.wantsLayer = true; back.wantsLayer = true; host.wantsLayer = true
        title.layer?.removeAnimation(forKey: animationKey); back.layer?.removeAnimation(forKey: animationKey)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        animatedTitle = title.layer; animatedBack = back.layer
        let motion = FluentMotion.controlFast
        let titleSlide = CABasicAnimation(keyPath: "transform.translation.x")
        titleSlide.fromValue = snapshot.titleX - title.convert(title.bounds, to: host).minX
        titleSlide.toValue = 0; titleSlide.duration = motion.duration
        titleSlide.timingFunction = motion.curve.timingFunction
        title.layer?.add(titleSlide, forKey: animationKey)

        func animate(_ layer: CALayer, from: CGFloat, to: CGFloat, opacity: [Float], token: FluentMotionToken) {
            let slide = CABasicAnimation(keyPath: "transform.translation.x"); slide.fromValue = from; slide.toValue = to
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = opacity[0]; fade.toValue = opacity[1]
            let group = CAAnimationGroup(); group.animations = [slide, fade]
            group.duration = token.duration; group.timingFunction = token.curve.timingFunction
            group.fillMode = .both; group.isRemovedOnCompletion = false
            layer.add(group, forKey: animationKey)
        }
        if showingBack, let layer = back.layer {
            let from = snapshot.backImage == nil ? -6 : snapshot.backFrame.minX - back.convert(back.bounds, to: host).minX
            animate(layer, from: from, to: 0, opacity: [snapshot.backOpacity, 1], token: motion)
        } else if let image = snapshot.backImage {
            // Keep the real button hidden immediately; this outgoing image has no hit target.
            let layer = CALayer(); layer.contents = image; layer.frame = snapshot.backFrame
            layer.contentsGravity = .resize; layer.zPosition = 10
            host.layer?.addSublayer(layer); outgoing = layer; outgoingImage = image
            animate(layer, from: 0, to: -6, opacity: [snapshot.backOpacity, 0], token: FluentMotion.controlFaster)
        }
        observation = IMEMotionObservation(view: host) { [weak self] in self?.cancel() }
        DispatchQueue.main.asyncAfter(deadline: .now() + motion.duration) { [weak self] in
            guard let self, self.generation == current else { return }
            self.cancel()
        }
    }
    func cancel() {
        generation &+= 1
        outgoing?.removeFromSuperlayer(); outgoing = nil; outgoingImage = nil
        animatedTitle?.removeAnimation(forKey: animationKey); animatedTitle = nil
        animatedBack?.removeAnimation(forKey: animationKey); animatedBack = nil
        observation = nil
    }
    deinit { cancel() }
}
