import AppKit
import SwiftUI

// MARK: - Animated Icon Theme

enum AnimatedIconTheme: String, CaseIterable, Identifiable {
    case fire
    case lightning
    case car

    var id: String { rawValue }

    var localizedName: LocalizedStringKey {
        switch self {
        case .fire: return "Fire"
        case .lightning: return "Lightning"
        case .car: return "Car"
        }
    }

    var frameCount: Int {
        switch self {
        case .fire: return 6
        case .lightning: return 4
        case .car: return 4
        }
    }

    func frame(_ index: Int) -> NSImage {
        let canvasSize = NSSize(width: 18, height: 18)
        let scale: CGFloat = 1.2
        let image = NSImage(size: canvasSize, flipped: true) { rect in
            let ctx = NSGraphicsContext.current!.cgContext
            let scaledW = rect.width * scale
            let scaledH = rect.height * scale
            let tx = (rect.width - scaledW) / 2
            let ty = (rect.height - scaledH) / 2
            ctx.translateBy(x: tx, y: ty)
            ctx.scaleBy(x: scale, y: scale)

            NSColor.black.setFill()
            NSColor.black.setStroke()

            switch self {
            case .fire: Self.drawFire(in: rect, frame: index % frameCount)
            case .lightning: Self.drawLightning(in: rect, frame: index % frameCount)
            case .car: Self.drawCar(in: rect, frame: index % frameCount)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Fire (6 frames) — Dynamic explosive flames

    private static func drawFire(in rect: NSRect, frame: Int) {
        let baseY = rect.maxY - 1
        let cx = rect.midX
        
        // Background large flame base - more aggressive pulsing
        let basePulse = [0.0, 2.0, 4.0, 3.0, 1.0, -1.0][frame]
        let basePath = NSBezierPath()
        basePath.move(to: NSPoint(x: cx - 7, y: baseY))
        basePath.curve(to: NSPoint(x: cx, y: baseY - 14 + basePulse),
                       controlPoint1: NSPoint(x: cx - 6, y: baseY - 6),
                       controlPoint2: NSPoint(x: cx - 4, y: baseY - 11))
        basePath.curve(to: NSPoint(x: cx + 7, y: baseY),
                       controlPoint1: NSPoint(x: cx + 4, y: baseY - 11),
                       controlPoint2: NSPoint(x: cx + 6, y: baseY - 6))
        basePath.close()
        basePath.fill()

        // 3 moving "licks" of fire - wider and more fluid
        let licks: [(x: CGFloat, h: CGFloat, w: CGFloat, off: Int)] = [
            (x: cx, h: 16, w: 5.0, off: 0),
            (x: cx - 4.5, h: 11, w: 4.0, off: 2),
            (x: cx + 4.5, h: 10, w: 3.5, off: 4)
        ]

        let sway = [-1.0, 0.6, 1.5, 0.6, -0.6, -1.5]
        
        for lick in licks {
            let f = (frame + lick.off) % 6
            let s = sway[f] * (lick.w / 2.5)
            let h = lick.h + (sway[(f+1)%6] * 2.0)
            
            let p = NSBezierPath()
            p.move(to: NSPoint(x: lick.x - lick.w, y: baseY))
            // S-curve for more dynamic movement
            p.curve(to: NSPoint(x: lick.x + s, y: baseY - h),
                    controlPoint1: NSPoint(x: lick.x - lick.w * 1.2, y: baseY - h * 0.4),
                    controlPoint2: NSPoint(x: lick.x - lick.w * 0.5 + s, y: baseY - h * 0.8))
            p.curve(to: NSPoint(x: lick.x + lick.w, y: baseY),
                    controlPoint1: NSPoint(x: lick.x + lick.w * 0.5 + s, y: baseY - h * 0.8),
                    controlPoint2: NSPoint(x: lick.x + lick.w * 1.2, y: baseY - h * 0.4))
            p.close()
            p.fill()
        }
    }

    // MARK: - Lightning (4 frames) — High-impact flashing

    private static func drawLightning(in rect: NSRect, frame: Int) {
        let cx = rect.midX
        let path = NSBezierPath()
        
        // Flashing background glow on some frames
        if frame % 2 == 0 {
            let glow = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            NSColor.black.withAlphaComponent(0.15).set()
            glow.fill()
            NSColor.black.set()
        }

        let bolt = NSBezierPath()
        bolt.lineCapStyle = .round
        bolt.lineJoinStyle = .round
        
        // Main bolt shape changes slightly per frame for "shiver" effect
        let shiftX = [0, 1.5, -1.0, 0.5][frame]
        
        bolt.move(to: NSPoint(x: cx + 3 + shiftX, y: rect.minY + 1))
        bolt.line(to: NSPoint(x: cx - 2 + shiftX, y: rect.midY - 1))
        bolt.line(to: NSPoint(x: cx + 2 + shiftX, y: rect.midY - 1))
        bolt.line(to: NSPoint(x: cx - 3 + shiftX, y: rect.maxY - 1))
        bolt.line(to: NSPoint(x: cx + 1 + shiftX, y: rect.midY + 1))
        bolt.line(to: NSPoint(x: cx - 2 + shiftX, y: rect.midY + 1))
        bolt.close()

        if frame % 3 == 0 {
            bolt.fill()
        } else {
            bolt.lineWidth = 2.0
            bolt.stroke()
        }
        
        // Random sparks
        let sparks = frame + 1
        for i in 0..<sparks {
            let angle = Double(i) * .pi / 2.0 + Double(frame) * 0.8
            let r: CGFloat = 6 + CGFloat(frame % 2)
            let sx = cx + CGFloat(cos(angle)) * r
            let sy = rect.midY + CGFloat(sin(angle)) * r
            let spark = NSBezierPath(ovalIn: NSRect(x: sx - 0.7, y: sy - 0.7, width: 1.4, height: 1.4))
            spark.fill()
        }
    }

    // MARK: - Car (4 frames) — Side profile view

    private static func drawCar(in rect: NSRect, frame: Int) {
        let groundY = rect.maxY - 4  // raised 2px total
        let left = rect.minX + 1
        let right = rect.maxX - 1
        let bodyW = right - left

        // Body bounce (road vibration)
        let bounce: [CGFloat] = [0, -0.3, 0, 0.3]
        let by = bounce[frame]

        // Lower body
        let body = NSBezierPath(
            roundedRect: NSRect(x: left, y: groundY - 6 + by, width: bodyW, height: 4),
            xRadius: 2,
            yRadius: 1.5
        )
        body.fill()

        // Hood (front slopes down)
        let hood = NSBezierPath()
        hood.move(to: NSPoint(x: right - 2, y: groundY - 6 + by))
        hood.line(to: NSPoint(x: right, y: groundY - 4 + by))
        hood.line(to: NSPoint(x: right - 4, y: groundY - 6 + by))
        hood.close()
        hood.fill()

        // Cabin (trapezoid, set back)
        let cabin = NSBezierPath()
        cabin.move(to: NSPoint(x: left + 3, y: groundY - 6 + by))
        cabin.line(to: NSPoint(x: left + 5, y: groundY - 10 + by))
        cabin.line(to: NSPoint(x: right - 5, y: groundY - 10 + by))
        cabin.line(to: NSPoint(x: right - 3, y: groundY - 6 + by))
        cabin.close()
        cabin.fill()

        // Window divider
        NSColor.white.setStroke()
        let divider = NSBezierPath()
        divider.lineWidth = 0.8
        divider.move(to: NSPoint(x: rect.midX, y: groundY - 6.5 + by))
        divider.line(to: NSPoint(x: rect.midX, y: groundY - 9.5 + by))
        divider.stroke()
        NSColor.black.setStroke()

        // Front wheel
        let fWheelX = right - 4
        let rWheelX = left + 4
        let wheelR: CGFloat = 2.2
        let wheelY = groundY - 1.5

        for wx in [fWheelX, rWheelX] {
            // Tire
            let tire = NSBezierPath(
                ovalIn: NSRect(x: wx - wheelR, y: wheelY - wheelR, width: wheelR * 2, height: wheelR * 2)
            )
            tire.fill()

            // Hub (white center)
            NSColor.white.setFill()
            let hub = NSBezierPath(
                ovalIn: NSRect(x: wx - 0.8, y: wheelY - 0.8, width: 1.6, height: 1.6)
            )
            hub.fill()

            // Spokes
            let spokeAngle = Double(frame) * .pi / 2.0
            let spoke = NSBezierPath()
            spoke.lineWidth = 0.6
            for s in 0..<3 {
                let a = spokeAngle + Double(s) * 2.0 * .pi / 3.0
                let dx = cos(a) * Double(wheelR - 0.6)
                let dy = sin(a) * Double(wheelR - 0.6)
                spoke.move(to: NSPoint(x: wx, y: wheelY))
                spoke.line(to: NSPoint(x: wx + CGFloat(dx), y: wheelY + CGFloat(dy)))
            }
            spoke.stroke()
            NSColor.black.setFill()
        }

        // Headlight
        let headlight = NSBezierPath(
            ovalIn: NSRect(x: right - 2, y: groundY - 5 + by, width: 1.5, height: 1.5)
        )
        NSColor.white.setFill()
        headlight.fill()
        NSColor.black.setFill()

        // Exhaust puffs (behind car, animated)
        let puffs: [(dx: CGFloat, dy: CGFloat, size: CGFloat)] = [
            (dx: -1, dy: -3, size: 1.2),
            (dx: -2.5, dy: -3.5, size: 1.8),
            (dx: -1.5, dy: -2.5, size: 1.0),
            (dx: -3, dy: -4, size: 2.0),
        ]
        let p = puffs[frame]
        let puff1 = NSBezierPath(
            ovalIn: NSRect(
                x: left + p.dx - p.size / 2,
                y: groundY + p.dy - p.size / 2 + by,
                width: p.size,
                height: p.size
            )
        )
        puff1.fill()

        // Second puff (trailing)
        if frame >= 1 {
            let prev = puffs[(frame + 3) % 4]
            let puff2 = NSBezierPath(
                ovalIn: NSRect(
                    x: left + prev.dx - 2 - prev.size * 0.3,
                    y: groundY + prev.dy - 1 - prev.size * 0.3 + by,
                    width: prev.size * 0.6,
                    height: prev.size * 0.6
                )
            )
            puff2.fill()
        }

        // Speed lines (behind the car)
        let linePath = NSBezierPath()
        linePath.lineWidth = 0.8
        linePath.lineCapStyle = .round
        let lineOffsets: [(y: CGFloat, len: CGFloat)] = [
            (y: groundY - 4 + by, len: 3),
            (y: groundY - 6 + by, len: 2),
            (y: groundY - 8 + by, len: 2.5),
        ]
        let lineShift = CGFloat(frame) * 0.8
        for line in lineOffsets {
            linePath.move(to: NSPoint(x: left - lineShift, y: line.y))
            linePath.line(to: NSPoint(x: left - lineShift - line.len, y: line.y))
        }
        linePath.stroke()
    }
}

// MARK: - Animation Controller

@MainActor
final class MenuBarAnimationController {
    private var timer: Timer?
    private var currentFrame = 0
    private var theme: AnimatedIconTheme
    private var onFrame: ((NSImage) -> Void)?

    private var utilization: Double = 0

    init(theme: AnimatedIconTheme) {
        self.theme = theme
    }

    func start(onFrame: @escaping (NSImage) -> Void) {
        self.onFrame = onFrame
        currentFrame = 0
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onFrame = nil
    }

    func updateUtilization(_ value: Double) {
        utilization = value
        if timer != nil {
            scheduleTimer()
        }
    }

    func updateTheme(_ newTheme: AnimatedIconTheme) {
        theme = newTheme
        currentFrame = 0
        if timer != nil {
            scheduleTimer()
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()

        // Speed: 0% → 0.3s, 100% → 0.06s (faster overall)
        let interval = max(0.06, 0.3 - (utilization / 100.0) * 0.24)

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let image = self.theme.frame(self.currentFrame)
                self.onFrame?(image)
                self.currentFrame = (self.currentFrame + 1) % self.theme.frameCount
            }
        }
    }
}
