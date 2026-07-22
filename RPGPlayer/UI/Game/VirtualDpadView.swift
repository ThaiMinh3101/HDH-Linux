// RPGPlayer/UI/Game/VirtualDpadView.swift
//
// On-screen virtual D-pad and action buttons for landscape games.
// Hidden automatically when a physical gamepad is connected.
//
// Architecture:
//   VirtualDpadView     — SwiftUI View; reads GamepadManager.isGamepadConnected
//                         to show/hide; hosts VirtualDpadHostView via UIViewRepresentable.
//   VirtualDpadHostView — UIView subclass; uses raw UITouch tracking for
//                         minimum latency; writes to GamepadManager.shared.touchInput.
//
// Layout (landscape, Q1 approved):
//   Bottom-left:  Digital D-pad cross (four triangular touch zones)
//   Bottom-right: A (confirm) and B (cancel) round buttons
//   Top-center:   START and SELECT pill buttons

import SwiftUI
import UIKit
import Combine

// MARK: - SwiftUI wrapper

struct VirtualDpadView: View {

    @ObservedObject private var gamepad = GamepadManager.shared

    var body: some View {
        Group {
            if !gamepad.isGamepadConnected {
                VirtualDpadRepresentable()
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: gamepad.isGamepadConnected)
            }
        }
    }
}

// MARK: - UIViewRepresentable

private struct VirtualDpadRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> VirtualDpadHostView {
        let v = VirtualDpadHostView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = true
        // Allow simultaneous multi-touch (D-pad + buttons at same time)
        v.isMultipleTouchEnabled = true
        return v
    }
    func updateUIView(_ uiView: VirtualDpadHostView, context: Context) {}
}

// MARK: - VirtualDpadHostView

/// UIView that renders the on-screen controls and translates raw touches into
/// InputState updates written to GamepadManager.shared.touchInput.
///
/// Touch zones (all in landscape coordinate space):
///   D-pad   — bottom-left area, angle from center determines direction
///   A/B     — bottom-right area, two circles
///   Start   — top-center, small pill button
///   Select  — top-center, small pill button (to the left of Start)
final class VirtualDpadHostView: UIView {

    // MARK: - Layout constants (points)
    private enum Layout {
        static let dpadRadius:    CGFloat = 52   // Outer radius of entire D-pad
        static let dpadDeadZone:  CGFloat = 14   // Ignore touches within this radius from center
        static let buttonRadius:  CGFloat = 28   // A / B button radius
        static let buttonSpacing: CGFloat = 14   // Gap between A and B
        static let edgePadding:   CGFloat = 24   // Margin from screen edges
        static let menuHeight:    CGFloat = 28
        static let menuWidth:     CGFloat = 64
        static let menuSpacing:   CGFloat = 12
        static let alpha:         CGFloat = 0.50 // Overall control opacity
    }

    // MARK: - Colors
    private let dpadColor      = UIColor(white: 1, alpha: 0.18)
    private let dpadBorderColor = UIColor(white: 1, alpha: 0.35)
    private let buttonAColor   = UIColor(red: 0.25, green: 0.72, blue: 0.35, alpha: 0.55)
    private let buttonBColor   = UIColor(red: 0.90, green: 0.28, blue: 0.28, alpha: 0.55)
    private let menuColor      = UIColor(white: 1, alpha: 0.22)
    private let labelColor     = UIColor.white

    // MARK: - Computed centers (recalculated on layout)
    private var dpadCenter  = CGPoint.zero
    private var centerA     = CGPoint.zero
    private var centerB     = CGPoint.zero
    private var centerStart  = CGPoint.zero
    private var centerSelect = CGPoint.zero

    // MARK: - Active touch tracking
    // Each UITouch is assigned to a "zone" when it begins; the zone is fixed
    // for that touch until it ends, so dragging out of zone doesn't cause glitches.
    private enum Zone { case dpad, buttonA, buttonB, start, select }
    private var touchZones = [UITouch: Zone]()

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        calculateCenters()
        setNeedsDisplay()
    }

    private func calculateCenters() {
        let w = bounds.width
        let h = bounds.height
        let p = Layout.edgePadding

        // D-pad: bottom-left
        dpadCenter = CGPoint(x: p + Layout.dpadRadius, y: h - p - Layout.dpadRadius)

        // B (cancel) button: bottom-right, slightly inward
        let br = Layout.buttonRadius
        let bs = Layout.buttonSpacing
        let bx = w - p - br
        let by = h - p - br
        centerB = CGPoint(x: bx, y: by)
        centerA = CGPoint(x: bx - bs - br * 2, y: by - br - bs / 2)

        // START and SELECT: top-center
        let menuY:  CGFloat = p + Layout.menuHeight / 2
        let totalW: CGFloat = Layout.menuWidth * 2 + Layout.menuSpacing
        let menuX:  CGFloat = (w - totalW) / 2
        centerSelect = CGPoint(x: menuX + Layout.menuWidth / 2,          y: menuY)
        centerStart  = CGPoint(x: menuX + Layout.menuWidth + Layout.menuSpacing + Layout.menuWidth / 2, y: menuY)
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        ctx.setAlpha(Layout.alpha)

        drawDpad(ctx)
        drawRoundButton(ctx, center: centerA, radius: Layout.buttonRadius,
                        color: buttonAColor, label: "A")
        drawRoundButton(ctx, center: centerB, radius: Layout.buttonRadius,
                        color: buttonBColor, label: "B")
        drawMenuButton(ctx, center: centerSelect, label: "SELECT")
        drawMenuButton(ctx, center: centerStart,  label: "START")

        ctx.restoreGState()
    }

    private func drawDpad(_ ctx: CGContext) {
        let c  = dpadCenter
        let r  = Layout.dpadRadius
        let arm: CGFloat = r * 0.42   // Width of each arm

        // Draw a cross shape
        let crossRect = CGRect(x: c.x - arm, y: c.y - r, width: arm * 2, height: r * 2)
        let crossRect2 = CGRect(x: c.x - r, y: c.y - arm, width: r * 2, height: arm * 2)

        ctx.setFillColor(dpadColor.cgColor)
        ctx.fill(crossRect)
        ctx.fill(crossRect2)

        // Arrow indicators (simple filled triangles)
        ctx.setFillColor(UIColor(white: 1, alpha: 0.6).cgColor)
        let arrowSize: CGFloat = 10
        let arrowInset: CGFloat = r * 0.55

        // Up arrow
        drawTriangle(ctx, tip: CGPoint(x: c.x, y: c.y - arrowInset),
                     base1: CGPoint(x: c.x - arrowSize/2, y: c.y - arrowInset + arrowSize),
                     base2: CGPoint(x: c.x + arrowSize/2, y: c.y - arrowInset + arrowSize))
        // Down arrow
        drawTriangle(ctx, tip: CGPoint(x: c.x, y: c.y + arrowInset),
                     base1: CGPoint(x: c.x - arrowSize/2, y: c.y + arrowInset - arrowSize),
                     base2: CGPoint(x: c.x + arrowSize/2, y: c.y + arrowInset - arrowSize))
        // Left arrow
        drawTriangle(ctx, tip: CGPoint(x: c.x - arrowInset, y: c.y),
                     base1: CGPoint(x: c.x - arrowInset + arrowSize, y: c.y - arrowSize/2),
                     base2: CGPoint(x: c.x - arrowInset + arrowSize, y: c.y + arrowSize/2))
        // Right arrow
        drawTriangle(ctx, tip: CGPoint(x: c.x + arrowInset, y: c.y),
                     base1: CGPoint(x: c.x + arrowInset - arrowSize, y: c.y - arrowSize/2),
                     base2: CGPoint(x: c.x + arrowInset - arrowSize, y: c.y + arrowSize/2))
    }

    private func drawTriangle(_ ctx: CGContext, tip: CGPoint, base1: CGPoint, base2: CGPoint) {
        ctx.beginPath()
        ctx.move(to: tip)
        ctx.addLine(to: base1)
        ctx.addLine(to: base2)
        ctx.closePath()
        ctx.fillPath()
    }

    private func drawRoundButton(_ ctx: CGContext, center: CGPoint, radius: CGFloat,
                                  color: UIColor, label: String) {
        let r = CGRect(x: center.x - radius, y: center.y - radius,
                       width: radius * 2, height: radius * 2)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: r)

        // Label
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 16, weight: .bold),
            .foregroundColor: labelColor
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let size = str.size()
        str.draw(at: CGPoint(x: center.x - size.width/2, y: center.y - size.height/2))
    }

    private func drawMenuButton(_ ctx: CGContext, center: CGPoint, label: String) {
        let w = Layout.menuWidth
        let h = Layout.menuHeight
        let r = CGRect(x: center.x - w/2, y: center.y - h/2, width: w, height: h)
        let path = UIBezierPath(roundedRect: r, cornerRadius: h/2)
        ctx.setFillColor(menuColor.cgColor)
        ctx.addPath(path.cgPath)
        ctx.fillPath()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: labelColor
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let size = str.size()
        str.draw(at: CGPoint(x: center.x - size.width/2, y: center.y - size.height/2))
    }

    // MARK: - Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let pt = touch.location(in: self)
            if let zone = zone(for: pt) {
                touchZones[touch] = zone
            }
        }
        commitTouchState()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Re-evaluate D-pad touches as finger slides; action/menu zones are sticky.
        for touch in touches {
            let pt = touch.location(in: self)
            if let existing = touchZones[touch], existing == .dpad {
                // Re-map within D-pad zone
                _ = pt  // direction is computed from center in commitTouchState
            } else if touchZones[touch] == nil {
                if let zone = zone(for: pt) {
                    touchZones[touch] = zone
                }
            }
        }
        commitTouchState()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { touchZones.removeValue(forKey: touch) }
        commitTouchState()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { touchZones.removeValue(forKey: touch) }
        commitTouchState()
    }

    // MARK: - Zone classification

    /// Determine which zone a touch point belongs to, or nil if outside all zones.
    private func zone(for pt: CGPoint) -> Zone? {
        // D-pad: within outer radius from dpadCenter
        let dpadDist = hypot(pt.x - dpadCenter.x, pt.y - dpadCenter.y)
        if dpadDist <= Layout.dpadRadius { return .dpad }

        // Action buttons
        if hypot(pt.x - centerA.x, pt.y - centerA.y) <= Layout.buttonRadius { return .buttonA }
        if hypot(pt.x - centerB.x, pt.y - centerB.y) <= Layout.buttonRadius { return .buttonB }

        // Menu pills (rectangular hit-test)
        let mw = Layout.menuWidth / 2
        let mh = Layout.menuHeight / 2
        if abs(pt.x - centerStart.x)  <= mw && abs(pt.y - centerStart.y)  <= mh { return .start }
        if abs(pt.x - centerSelect.x) <= mw && abs(pt.y - centerSelect.y) <= mh { return .select }

        return nil
    }

    // MARK: - State commit

    /// Rebuild InputState from current active touches and push to GamepadManager.
    private func commitTouchState() {
        var state = InputState.neutral

        for (touch, zone) in touchZones {
            switch zone {
            case .dpad:
                let pt = touch.location(in: self)
                applyDpad(pt: pt, to: &state)
            case .buttonA:  state.buttonA = true
            case .buttonB:  state.buttonB = true
            case .start:    state.start   = true
            case .select:   state.select  = true
            }
        }

        // Write to GamepadManager on main thread (we're already here via UIResponder).
        GamepadManager.shared.touchInput = state
    }

    /// Convert a D-pad touch position to directional buttons using angle from center.
    /// Dead-zone in the center prevents accidental input.
    private func applyDpad(pt: CGPoint, to state: inout InputState) {
        let dx = pt.x - dpadCenter.x
        let dy = pt.y - dpadCenter.y
        let dist = hypot(dx, dy)
        guard dist > Layout.dpadDeadZone else { return }

        let angle = atan2(dy, dx)   // radians; +x=right, +y=down (UIKit coords)
        let pi    = CGFloat.pi

        // Divide into 4 quadrants with ±45° diagonals allowed.
        // Right: -45° to +45°   (angle in -π/4 … π/4)
        // Down:  +45° to +135°  (angle in π/4 … 3π/4)
        // Left: ±135° to ±180°  (|angle| > 3π/4)
        // Up:   -135° to -45°   (angle in -3π/4 … -π/4)
        if angle >= -pi/4  && angle <= pi/4  { state.dpadRight = true }
        if angle >   pi/4  && angle <  3*pi/4 { state.dpadDown  = true }
        if angle >= -3*pi/4 && angle <= -pi/4 { state.dpadUp    = true }
        if abs(angle) > 3*pi/4                { state.dpadLeft  = true }
    }
}
