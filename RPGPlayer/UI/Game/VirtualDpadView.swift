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
//   ExitButtonView      — SwiftUI View; always visible top-left; dismiss with confirm.
//
// Layout (landscape):
//   Bottom-left:  Digital D-pad cross (four triangular touch zones)
//   Bottom-right: 4-button diamond  Y(top) X(left) B(bottom) A(right)
//                 — matching standard gamepad face-button layout
//   Top-center:   START and SELECT pill buttons
//   Top-left:     Exit button (shown separately via setupExitButton, not gated by gamepad)

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
        v.isMultipleTouchEnabled = true
        return v
    }
    func updateUIView(_ uiView: VirtualDpadHostView, context: Context) {}
}

// MARK: - ExitButtonView

/// Floating exit button placed top-left. Always visible over the game viewport
/// (not hidden when a physical gamepad is connected).
/// Used by both GamePlayerViewController and RGSSViewController.
struct ExitButtonView: View {

    /// Called when the user confirms they want to quit.
    var onExit: () -> Void

    @State private var showConfirm = false

    var body: some View {
        VStack {
            HStack {
                Button {
                    showConfirm = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.80), .black.opacity(0.45))
                        .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
                }
                .buttonStyle(.plain)
                .padding(.leading, 18)
                .padding(.top, 14)
                .confirmationDialog(
                    "Thoát game?",
                    isPresented: $showConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Thoát", role: .destructive) { onExit() }
                    Button("Huỷ",   role: .cancel)      {}
                } message: {
                    Text("Tiến trình chưa lưu có thể mất.")
                }

                Spacer()
            }
            Spacer()
        }
        .ignoresSafeArea()
        .allowsHitTesting(true)
    }
}

// MARK: - VirtualDpadHostView

/// UIView that renders the on-screen controls and translates raw touches into
/// InputState updates written to GamepadManager.shared.touchInput.
///
/// Touch zones (all in landscape coordinate space):
///   D-pad     — bottom-left area, angle from center determines direction
///   A/B/X/Y   — bottom-right diamond: Y(top) X(left) B(bottom) A(right)
///   Start     — top-center, small pill button
///   Select    — top-center, small pill button (to the left of Start)
final class VirtualDpadHostView: UIView {

    // MARK: - Layout constants (points)
    private enum Layout {
        static let dpadRadius:    CGFloat = 52   // Outer radius of entire D-pad
        static let dpadDeadZone:  CGFloat = 14   // Ignore touches within this radius from center
        static let buttonRadius:  CGFloat = 26   // Face button radius
        static let buttonSpacing: CGFloat = 10   // Edge-to-edge gap between adjacent diamond buttons
        static let edgePadding:   CGFloat = 24   // Margin from screen edges
        static let menuHeight:    CGFloat = 28
        static let menuWidth:     CGFloat = 64
        static let menuSpacing:   CGFloat = 12
        static let alpha:         CGFloat = 0.50 // Overall control opacity
    }

    // MARK: - Colors
    private let dpadColor       = UIColor(white: 1, alpha: 0.18)
    // PlayStation-style face button colors
    private let buttonAColor    = UIColor(red: 0.25, green: 0.72, blue: 0.35, alpha: 0.55)  // A green  (South)
    private let buttonBColor    = UIColor(red: 0.90, green: 0.28, blue: 0.28, alpha: 0.55)  // B red    (East)
    private let buttonXColor    = UIColor(red: 0.25, green: 0.55, blue: 0.90, alpha: 0.55)  // X blue   (West)
    private let buttonYColor    = UIColor(red: 0.88, green: 0.68, blue: 0.12, alpha: 0.55)  // Y yellow (North)
    private let menuColor       = UIColor(white: 1, alpha: 0.22)
    private let labelColor      = UIColor.white

    // MARK: - Computed centers (recalculated on layout)
    private var dpadCenter    = CGPoint.zero
    private var diamondCenter = CGPoint.zero   // geometric centre of 4 face buttons
    // Diamond positions: A=right, B=bottom, X=left, Y=top
    private var centerA       = CGPoint.zero   // South — buttonA  (RGSS C / confirm)
    private var centerB       = CGPoint.zero   // East  — buttonB  (RGSS B / cancel)
    private var centerX       = CGPoint.zero   // West  — buttonC  (RGSS A / shift)
    private var centerY       = CGPoint.zero   // North — buttonD  (RGSS X)
    private var centerStart   = CGPoint.zero
    private var centerSelect  = CGPoint.zero

    // MARK: - Active touch tracking
    private enum Zone { case dpad, buttonA, buttonB, buttonX, buttonY, start, select }
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
        let r = Layout.buttonRadius

        // D-pad: bottom-left
        dpadCenter = CGPoint(x: p + Layout.dpadRadius, y: h - p - Layout.dpadRadius)

        // Diamond step = center-to-center distance between adjacent buttons
        let step = r * 2 + Layout.buttonSpacing

        // Place diamond so B (bottom) sits at bottom-right corner, same bottom-margin as D-pad
        // Diamond center is step/2 above B center, and step/2 to the left of A center
        let bCenterX = w - p - r                // A is at right edge; B is directly below diamond center
        let bCenterY = h - p - r                // bottom-most button baseline
        diamondCenter = CGPoint(x: bCenterX - step / 2, y: bCenterY - step / 2)

        centerB = CGPoint(x: diamondCenter.x,             y: diamondCenter.y + step / 2)  // bottom
        centerA = CGPoint(x: diamondCenter.x + step / 2,  y: diamondCenter.y)             // right
        centerX = CGPoint(x: diamondCenter.x - step / 2,  y: diamondCenter.y)             // left
        centerY = CGPoint(x: diamondCenter.x,             y: diamondCenter.y - step / 2)  // top

        // START and SELECT: top-center
        let menuY:  CGFloat = p + Layout.menuHeight / 2
        let totalW: CGFloat = Layout.menuWidth * 2 + Layout.menuSpacing
        let menuX:  CGFloat = (w - totalW) / 2
        centerSelect = CGPoint(x: menuX + Layout.menuWidth / 2,
                               y: menuY)
        centerStart  = CGPoint(x: menuX + Layout.menuWidth + Layout.menuSpacing + Layout.menuWidth / 2,
                               y: menuY)
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        ctx.setAlpha(Layout.alpha)

        drawDpad(ctx)
        // Diamond face buttons
        drawRoundButton(ctx, center: centerY, radius: Layout.buttonRadius, color: buttonYColor, label: "Y")
        drawRoundButton(ctx, center: centerX, radius: Layout.buttonRadius, color: buttonXColor, label: "X")
        drawRoundButton(ctx, center: centerB, radius: Layout.buttonRadius, color: buttonBColor, label: "B")
        drawRoundButton(ctx, center: centerA, radius: Layout.buttonRadius, color: buttonAColor, label: "A")
        drawMenuButton(ctx, center: centerSelect, label: "SELECT")
        drawMenuButton(ctx, center: centerStart,  label: "START")

        ctx.restoreGState()
    }

    private func drawDpad(_ ctx: CGContext) {
        let c  = dpadCenter
        let r  = Layout.dpadRadius
        let arm: CGFloat = r * 0.42

        let crossRect  = CGRect(x: c.x - arm, y: c.y - r,   width: arm * 2, height: r * 2)
        let crossRect2 = CGRect(x: c.x - r,   y: c.y - arm, width: r * 2,   height: arm * 2)
        ctx.setFillColor(dpadColor.cgColor)
        ctx.fill(crossRect)
        ctx.fill(crossRect2)

        ctx.setFillColor(UIColor(white: 1, alpha: 0.6).cgColor)
        let arrowSize: CGFloat  = 10
        let arrowInset: CGFloat = r * 0.55

        drawTriangle(ctx, tip: CGPoint(x: c.x, y: c.y - arrowInset),
                     base1: CGPoint(x: c.x - arrowSize/2, y: c.y - arrowInset + arrowSize),
                     base2: CGPoint(x: c.x + arrowSize/2, y: c.y - arrowInset + arrowSize))
        drawTriangle(ctx, tip: CGPoint(x: c.x, y: c.y + arrowInset),
                     base1: CGPoint(x: c.x - arrowSize/2, y: c.y + arrowInset - arrowSize),
                     base2: CGPoint(x: c.x + arrowSize/2, y: c.y + arrowInset - arrowSize))
        drawTriangle(ctx, tip: CGPoint(x: c.x - arrowInset, y: c.y),
                     base1: CGPoint(x: c.x - arrowInset + arrowSize, y: c.y - arrowSize/2),
                     base2: CGPoint(x: c.x - arrowInset + arrowSize, y: c.y + arrowSize/2))
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

        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 15, weight: .bold),
            .foregroundColor: labelColor
        ]
        let str  = NSAttributedString(string: label, attributes: attrs)
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
        let str  = NSAttributedString(string: label, attributes: attrs)
        let size = str.size()
        str.draw(at: CGPoint(x: center.x - size.width/2, y: center.y - size.height/2))
    }

    // MARK: - Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let pt = touch.location(in: self)
            if let zone = zone(for: pt) { touchZones[touch] = zone }
        }
        commitTouchState()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let pt = touch.location(in: self)
            if let existing = touchZones[touch], existing == .dpad {
                _ = pt  // direction computed from center in commitTouchState
            } else if touchZones[touch] == nil {
                if let zone = zone(for: pt) { touchZones[touch] = zone }
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

    private func zone(for pt: CGPoint) -> Zone? {
        let dpadDist = hypot(pt.x - dpadCenter.x, pt.y - dpadCenter.y)
        if dpadDist <= Layout.dpadRadius { return .dpad }

        let r = Layout.buttonRadius
        if hypot(pt.x - centerA.x, pt.y - centerA.y) <= r { return .buttonA }
        if hypot(pt.x - centerB.x, pt.y - centerB.y) <= r { return .buttonB }
        if hypot(pt.x - centerX.x, pt.y - centerX.y) <= r { return .buttonX }
        if hypot(pt.x - centerY.x, pt.y - centerY.y) <= r { return .buttonY }

        let mw = Layout.menuWidth / 2
        let mh = Layout.menuHeight / 2
        if abs(pt.x - centerStart.x)  <= mw && abs(pt.y - centerStart.y)  <= mh { return .start }
        if abs(pt.x - centerSelect.x) <= mw && abs(pt.y - centerSelect.y) <= mh { return .select }

        return nil
    }

    // MARK: - State commit

    private func commitTouchState() {
        var state = InputState.neutral

        for (touch, zone) in touchZones {
            switch zone {
            case .dpad:
                let pt = touch.location(in: self)
                applyDpad(pt: pt, to: &state)
            case .buttonA:  state.buttonA = true
            case .buttonB:  state.buttonB = true
            case .buttonX:  state.buttonC = true   // West → RGSS A (shift-like)
            case .buttonY:  state.buttonD = true   // North → RGSS X
            case .start:    state.start   = true
            case .select:   state.select  = true
            }
        }

        GamepadManager.shared.touchInput = state
    }

    private func applyDpad(pt: CGPoint, to state: inout InputState) {
        let dx   = pt.x - dpadCenter.x
        let dy   = pt.y - dpadCenter.y
        let dist = hypot(dx, dy)
        guard dist > Layout.dpadDeadZone else { return }

        let angle = atan2(dy, dx)
        let pi    = CGFloat.pi

        if angle >= -pi/4   && angle <= pi/4  { state.dpadRight = true }
        if angle >   pi/4   && angle <  3*pi/4 { state.dpadDown  = true }
        if angle >= -3*pi/4 && angle <= -pi/4 { state.dpadUp    = true }
        if abs(angle) > 3*pi/4                { state.dpadLeft  = true }
    }
}
