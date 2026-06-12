import AppKit

// MARK: - Sensitivity

/// How eagerly the mouse-circle gesture triggers a screenshot.
enum AnnotationSensitivity: String, CaseIterable, Identifiable, Codable {
    case low, medium, high
    var id: String { rawValue }
    var title: String {
        switch self {
        case .low: return "Low (deliberate circles)"
        case .medium: return "Medium"
        case .high: return "High (easy to trigger)"
        }
    }
    /// Minimum total path length (points) the cursor must travel.
    var minPathLength: CGFloat {
        switch self {
        case .low: return 900
        case .medium: return 600
        case .high: return 380
        }
    }
}

// MARK: - Screen capture + annotated render

/// Captures the screen and draws the user's circling motion onto it. Requires
/// Screen Recording permission (the whole point is to screenshot the screen).
enum AnnotationCapture {
    static func hasScreenPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestScreenPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
            ?? CGMainDisplayID()
    }

    /// Capture the display `displayID` and draw the recent mouse `path` (global
    /// points, AppKit bottom-left origin) as a translucent red scribble inside a
    /// soft circle. `screenFrame`/`scale` are the display's AppKit frame and
    /// backing scale (passed in so this can run off the main thread). Returns PNG
    /// data, or nil if capture failed (e.g. permission missing).
    static func annotatedPNG(displayID: CGDirectDisplayID, screenFrame frame: CGRect, scale: CGFloat, path: [CGPoint], showPath: Bool = false) -> Data? {
        guard let (ctx, _, _) = captureContext(displayID) else { return nil }

        let pts = path.map { CGPoint(x: ($0.x - frame.minX) * scale, y: ($0.y - frame.minY) * scale) }

        if pts.count > 1 {
            // Trim the lead-in "approach" stroke so it doesn't leave a stray line
            // or inflate the highlight (see gesturePoints).
            let gesture = gesturePoints(pts)
            let xs = gesture.map(\.x), ys = gesture.map(\.y)
            let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
            let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
            let w = maxX - minX, h = maxY - minY
            let padX = max(26 * scale, w * 0.14)
            let padY = max(26 * scale, h * 0.14)
            let rect = CGRect(x: minX - padX, y: minY - padY, width: w + padX * 2, height: h + padY * 2)

            // Match the highlight shape to the gesture: a rounded box when the user
            // drew a square (the path reaches the bbox corners), otherwise an
            // ellipse for circles/scribbles. Translucent so the screen shows through.
            let highlight: CGPath
            if looksLikeSquare(gesture, minX: minX, minY: minY, width: w, height: h) {
                let radius = min(rect.width, rect.height) * 0.10
                highlight = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            } else {
                highlight = CGPath(ellipseIn: rect, transform: nil)
            }
            ctx.addPath(highlight)
            ctx.setFillColor(NSColor.systemRed.withAlphaComponent(0.07).cgColor)
            ctx.fillPath()
            ctx.addPath(highlight)
            ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(max(3, 4 * scale))
            ctx.strokePath()

            // Optionally draw the raw mouse path too (off by default — the shape
            // highlight alone is cleaner). Translucent so it never hides content.
            if showPath {
                ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.4).cgColor)
                ctx.setLineWidth(max(3.5, 4.5 * scale))
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.beginPath()
                ctx.move(to: gesture[0])
                for p in gesture.dropFirst() { ctx.addLine(to: p) }
                ctx.strokePath()
            }
        }

        return pngData(ctx)
    }

    /// Capture `displayID` and draw a translucent red circle centered on
    /// `cursorPoint` (global AppKit coords) — manual point-and-shoot capture, for
    /// when the user presses the capture key instead of circling.
    static func annotatedPNG(displayID: CGDirectDisplayID, screenFrame frame: CGRect, scale: CGFloat, cursorPoint: CGPoint, radius: CGFloat = 78) -> Data? {
        guard let (ctx, _, _) = captureContext(displayID) else { return nil }
        let cx = (cursorPoint.x - frame.minX) * scale
        let cy = (cursorPoint.y - frame.minY) * scale
        let r = radius * scale
        let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
        ctx.setFillColor(NSColor.systemRed.withAlphaComponent(0.07).cgColor)
        ctx.fillEllipse(in: rect)
        ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(max(3, 4 * scale))
        ctx.strokeEllipse(in: rect)
        return pngData(ctx)
    }

    /// Screenshot `displayID` into a fresh bottom-left CGContext (AppKit coords,
    /// no Y flip needed) ready to draw on. Returns nil if capture failed.
    private static func captureContext(_ displayID: CGDirectDisplayID) -> (ctx: CGContext, width: Int, height: Int)? {
        guard let shot = CGDisplayCreateImage(displayID) else { return nil }
        let w = shot.width, h = shot.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(shot, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (ctx, w, h)
    }

    private static func pngData(_ ctx: CGContext) -> Data? {
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }

    /// Drops the lead-in "approach" stroke — the contiguous start of the path
    /// that lands outside the region the gesture actually occupies. That region
    /// is estimated from the bounding box of the latter (gesture-dominated) part
    /// of the path, since the approach is always at the very start. Robust for
    /// circles and squares, big or small, and won't over-trim a clean gesture.
    private static func gesturePoints(_ pts: [CGPoint]) -> [CGPoint] {
        guard pts.count > 8 else { return pts }
        let tail = Array(pts.suffix(max(4, Int(Double(pts.count) * 0.6))))
        let txs = tail.map(\.x), tys = tail.map(\.y)
        var minX = txs.min() ?? 0, maxX = txs.max() ?? 0
        var minY = tys.min() ?? 0, maxY = tys.max() ?? 0
        let ex = (maxX - minX) * 0.12 + 1, ey = (maxY - minY) * 0.12 + 1
        minX -= ex; maxX += ex; minY -= ey; maxY += ey
        var start = 0
        while start < pts.count - 1 {
            let p = pts[start]
            if p.x >= minX, p.x <= maxX, p.y >= minY, p.y <= maxY { break }
            start += 1
        }
        let trimmed = Array(pts[start...])
        return trimmed.count >= 4 ? trimmed : pts
    }

    /// Did the gesture reach the corners of its bounding box (a square) rather
    /// than staying mid-edge (a circle)? A square parks points in the tight
    /// corner zones; a circle's diagonal only reaches ~85% out, so a tight 12%
    /// zone separates them cleanly.
    private static func looksLikeSquare(_ pts: [CGPoint], minX: CGFloat, minY: CGFloat, width w: CGFloat, height h: CGFloat) -> Bool {
        guard w > 1, h > 1, pts.count >= 8 else { return false }
        var corner = 0
        for p in pts {
            let nx = (p.x - minX) / w, ny = (p.y - minY) / h
            if (nx < 0.12 || nx > 0.88) && (ny < 0.12 || ny > 0.88) { corner += 1 }
        }
        return Double(corner) / Double(pts.count) > 0.08
    }
}

// MARK: - Mouse-gesture monitor

/// Watches global mouse movement and fires when the user "circles" or scribbles
/// the cursor over a spot — lots of movement packed into a small area. Used to
/// trigger an annotated screenshot during a SuperNotation session.
final class MouseGestureMonitor {
    /// Called on the main thread with the points of the gesture (global, AppKit
    /// coords) and the screen they occurred on.
    var onCircle: (([CGPoint], NSScreen) -> Void)?
    var sensitivity: AnnotationSensitivity = .medium

    private struct Sample { let point: CGPoint; let time: CFTimeInterval }
    private var samples: [Sample] = []
    private var lastTrigger: CFTimeInterval = 0
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private let window: CFTimeInterval = 2.2      // last 2.2s of motion — room for slower, bigger circles
    private let cooldown: CFTimeInterval = 2.5    // min gap between captures

    func start() {
        stop()
        samples.removeAll()
        lastTrigger = CACurrentMediaTime()  // brief warm-up so an opening flick can't fire
        let types: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: types) { [weak self] _ in
            self?.record()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: types) { [weak self] event in
            self?.record()
            return event
        }
    }

    func stop() {
        if let g = globalMonitor { NSEvent.removeMonitor(g); globalMonitor = nil }
        if let l = localMonitor { NSEvent.removeMonitor(l); localMonitor = nil }
        samples.removeAll()
    }

    private func record() {
        let now = CACurrentMediaTime()
        samples.append(Sample(point: NSEvent.mouseLocation, time: now))
        samples.removeAll { now - $0.time > window }
        evaluate(now: now)
    }

    private func evaluate(now: CFTimeInterval) {
        guard now - lastTrigger > cooldown else { return }
        guard samples.count >= 10 else { return }

        let pts = samples.map(\.point)
        let span = now - (samples.first?.time ?? now)
        guard span > 0.3 else { return }

        var pathLength: CGFloat = 0
        for i in 1..<pts.count {
            pathLength += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)
        }

        let xs = pts.map(\.x), ys = pts.map(\.y)
        let bboxW = (xs.max() ?? 0) - (xs.min() ?? 0)
        let bboxH = (ys.max() ?? 0) - (ys.min() ?? 0)
        let diagonal = hypot(bboxW, bboxH)

        // A circle/scribble/square = lots of travel (pathLength) packed into a
        // bounded area. A straight swipe has pathLength ≈ diagonal, so the ratio
        // test rejects it while still allowing big loops and squares. (Circle
        // ratio ≈ π, square ≈ 2.8; a straight drag ≈ 1.)
        guard diagonal > 25, diagonal < 1500 else { return }
        guard pathLength > sensitivity.minPathLength else { return }
        guard pathLength > diagonal * 2.0 else { return }

        lastTrigger = now
        let centroid = CGPoint(x: ((xs.min() ?? 0) + (xs.max() ?? 0)) / 2,
                               y: ((ys.min() ?? 0) + (ys.max() ?? 0)) / 2)
        let screen = NSScreen.screens.first { $0.frame.contains(centroid) } ?? NSScreen.main
        let captured = pts
        samples.removeAll()
        if let screen {
            onCircle?(captured, screen)
        }
    }
}
