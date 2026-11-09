import AppKit
import SwiftUI
import ServiceManagement

// MARK: - Views

struct StatusIcon: View {
    let state: CheckState
    var size: CGFloat = 18
    var body: some View {
        let (name, color): (String, Color) = {
            switch state {
            case .ok: return ("checkmark.circle.fill", .green)
            case .warning: return ("exclamationmark.triangle.fill", .orange)
            case .error: return ("xmark.octagon.fill", .red)
            case .inactive: return ("minus.circle", .gray)
            case .info: return ("info.circle.fill", .blue)
            }
        }()
        Image(systemName: name).foregroundColor(color).font(.system(size: size)).frame(width: size + 6)
    }
}

struct CheckRowView: View {
    let row: CheckRow
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusIcon(state: row.state).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title).font(.headline)
                Text(row.detail).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if let hint = row.hint {
                    (Text("Was tun? ").bold() + Text(hint))
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                if !row.actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(row.actions) { act in
                            if act.prominent {
                                Button(act.title) { act.run() }.buttonStyle(.borderedProminent).controlSize(.small)
                            } else {
                                Button(act.title) { act.run() }.controlSize(.small)
                            }
                        }
                    }.padding(.top, 2)
                }
                if let t = row.disclosureTitle, let text = row.disclosureText {
                    DisclosureGroup(t) {
                        Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8).background(Color.secondary.opacity(0.08)).cornerRadius(6)
                    }.font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
    }
}

// MARK: - Big connect button (Speedtest-"GO"-style)

private struct ConnectAnimationTimeKey: EnvironmentKey {
    static let defaultValue: Double? = nil
}

extension EnvironmentValues {
    /// Previews: freezes the button animations at this time (seconds) instead of the clock.
    var connectAnimationTime: Double? {
        get { self[ConnectAnimationTimeKey.self] }
        set { self[ConnectAnimationTimeKey.self] = newValue }
    }
}

private extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// Colours of the big button per state and appearance.
private struct ButtonPalette {
    var ring: [Color]
    var discTop: Color
    var discBottom: Color
    var glow: Color
    var glowStrength: Double
    var label: Color
    var lit: Bool          // filled, glossy disc (vs. outlined / neutral)

    static let mint = Color(hex: 0x9BFFCF)
    static let bright = Color(hex: 0x34E37E)
    static let mid = Color(hex: 0x12B85F)
    static let deep = Color(hex: 0x07894A)
    static let teal = Color(hex: 0x14C9A0)

    static func make(_ style: ConnectButtonInfo.Style, dark: Bool) -> ButtonPalette {
        let neutralTop = dark ? Color(white: 0.21) : Color(white: 0.995)
        let neutralBottom = dark ? Color(white: 0.15) : Color(white: 0.93)
        let gray = dark ? Color(white: 0.34) : Color(white: 0.80)
        switch style {
        case .ready:
            return ButtonPalette(ring: [mint, bright, teal, mid, bright, mint],
                                 discTop: Color(hex: 0x3BE688), discBottom: Color(hex: 0x0B9E50),
                                 glow: bright, glowStrength: dark ? 0.55 : 0.45, label: .white, lit: true)
        case .connected:
            return ButtonPalette(ring: [Color(hex: 0x7FF0B0), mid, deep, mid, Color(hex: 0x7FF0B0)],
                                 discTop: Color(hex: 0x27C26C), discBottom: Color(hex: 0x0A8040),
                                 glow: mid, glowStrength: dark ? 0.30 : 0.22, label: .white, lit: true)
        case .connecting:
            return ButtonPalette(ring: [bright.opacity(0.22)],
                                 discTop: Color(hex: 0x1C9E5A), discBottom: Color(hex: 0x0A6236),
                                 glow: mid, glowStrength: dark ? 0.28 : 0.20, label: .white.opacity(0.95), lit: true)
        case .waiting:
            return ButtonPalette(ring: [bright.opacity(0.75), teal.opacity(0.55), bright.opacity(0.75)],
                                 discTop: neutralTop, discBottom: neutralBottom,
                                 glow: bright, glowStrength: dark ? 0.12 : 0.08,
                                 label: dark ? bright : deep, lit: false)
        case .blocked:
            return ButtonPalette(ring: [Color.orange.opacity(0.9), Color(hex: 0xFFB340), Color.orange.opacity(0.9)],
                                 discTop: neutralTop, discBottom: neutralBottom,
                                 glow: .orange, glowStrength: dark ? 0.16 : 0.10, label: .orange, lit: false)
        case .unavailable, .off:
            return ButtonPalette(ring: [gray], discTop: neutralTop, discBottom: neutralBottom,
                                 glow: .clear, glowStrength: 0, label: .secondary, lit: false)
        }
    }
}

struct BigConnectButton: View {
    let info: ConnectButtonInfo
    /// false while the window is closed or covered → no animation work at all.
    var visible = true
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.connectAnimationTime) private var frozenTime
    @State private var hover = false
    static let diameter: CGFloat = 204
    private let ringWidth: CGFloat = 8
    private let gap: CGFloat = 7
    /// Room for glow and the pulse rings.
    static let canvas: CGFloat = 256

    private var animates: Bool {
        guard !reduceMotion, frozenTime == nil, visible else { return false }
        return info.style == .ready || info.style == .connecting || info.style == .waiting
    }

    var body: some View {
        Button(action: action) {
            face
                .frame(width: Self.canvas, height: Self.canvas)
                .contentShape(Circle().inset(by: (Self.canvas - Self.diameter) / 2))
        }
        .buttonStyle(BigCircleButtonStyle(hover: hover && info.enabled))
        .disabled(!info.enabled)
        .onHover { hover = $0 }
        .keyboardShortcut(info.enabled ? .defaultAction : nil)
        .accessibilityLabel(Text(info.enabled ? "Verbinden" : info.title))
        .accessibilityHint(Text(info.caption ?? ""))
    }

    /// Moving parts while live: Core Animation layers (animated by the render server, ~0 % app CPU).
    private var liveKind: ButtonAnimationLayerView.Kind? {
        guard animates else { return nil }
        switch info.style {
        case .ready: return .readyPulse
        case .connecting: return .spinner(dark: colorScheme == .dark)
        case .waiting: return .waitingRing(dark: colorScheme == .dark)
        default: return nil
        }
    }

    // Static values of the moving parts: previews (frozen time) or Reduce Motion / hidden window.
    private var breath: Double {
        frozenTime.map { 0.5 - 0.5 * cos($0 * 2 * .pi / 2.6) } ?? 0.5
    }
    private var spinAngle: Double {
        frozenTime.map { ($0 * 300).truncatingRemainder(dividingBy: 360) } ?? -90
    }
    private func dot(_ i: Int) -> Double {
        frozenTime.map { 0.3 + 0.7 * max(0, sin($0 * 2 * .pi / 1.2 - Double(i) * 0.7)) } ?? 0.85
    }

    private var face: some View {
        let p = ButtonPalette.make(info.style, dark: colorScheme == .dark)
        let d = Self.diameter
        let disc = d - 2 * (ringWidth + gap)
        return ZStack {
            // Glow (radial gradient – no blur filter, cheap and crisp in every renderer)
            if p.glowStrength > 0 {
                Circle()
                    .fill(RadialGradient(gradient: Gradient(stops: [
                        .init(color: p.glow.opacity(p.glowStrength * (info.style == .ready ? 1.1 : 1)), location: 0),
                        .init(color: p.glow.opacity(p.glowStrength * 0.45), location: 0.35),
                        .init(color: p.glow.opacity(0), location: 1),
                    ]), center: .center, startRadius: d * 0.44, endRadius: Self.canvas / 2))
                    .frame(width: Self.canvas, height: Self.canvas)
                    .opacity(info.style == .ready && frozenTime != nil ? 0.7 + 0.3 * breath : (info.style == .ready ? 0.85 : 1))
            }
            // Pulse rings expanding outwards (ready; previews only – live they are Core Animation layers)
            if info.style == .ready, let t = frozenTime {
                ForEach(0..<2, id: \.self) { i in
                    let ph = (t / 2.6 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .stroke(ButtonPalette.bright, lineWidth: 2.5)
                        .frame(width: d, height: d)
                        .scaleEffect(1 + 0.22 * ph)
                        .opacity(0.6 * (1 - ph))
                }
            }
            // Outer ring
            ring(p)
                .frame(width: d, height: d)
            if let kind = liveKind {
                ButtonAnimationLayerView(kind: kind, diameter: d, ringWidth: ringWidth)
                    .frame(width: Self.canvas, height: Self.canvas)
                    .allowsHitTesting(false)
            }
            // Inner disc
            Circle()
                .fill(LinearGradient(colors: [p.discTop, p.discBottom], startPoint: .top, endPoint: .bottom))
                .overlay(gloss(disc: disc, lit: p.lit, strength: info.style == .connecting ? 0.16 : 0.30))
                .overlay(Circle().strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(p.lit ? 0.45 : (colorScheme == .dark ? 0.10 : 0.9)),
                                            Color.black.opacity(p.lit ? 0.12 : 0.06)],
                                   startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .frame(width: disc, height: disc)
                .shadow(color: p.lit ? p.discBottom.opacity(0.45) : Color.black.opacity(colorScheme == .dark ? 0.35 : 0.10),
                        radius: p.lit ? 10 : 6, y: p.lit ? 5 : 3)
            label(p)
                .frame(width: disc - 22)
        }
    }

    @ViewBuilder
    private func ring(_ p: ButtonPalette) -> some View {
        switch info.style {
        case .connecting:
            ZStack {
                Circle().strokeBorder(p.ring[0], lineWidth: ringWidth)
                // Spinner arc with a fading tail; static with Reduce Motion.
                Circle()
                    .inset(by: ringWidth / 2)
                    .trim(from: 0, to: 0.32)
                    .stroke(AngularGradient(gradient: Gradient(colors: colorScheme == .dark
                                                                ? [ButtonPalette.bright.opacity(0), ButtonPalette.mint]
                                                                : [ButtonPalette.mid.opacity(0), ButtonPalette.bright, ButtonPalette.mid]),
                                            center: .center, startAngle: .degrees(0), endAngle: .degrees(0.32 * 360)),
                            style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(spinAngle))
                    .opacity(liveKind == nil ? 1 : 0) // live: rotating Core Animation arc instead
            }
        case .waiting:
            Circle()
                .strokeBorder(AngularGradient(gradient: Gradient(colors: p.ring), center: .center),
                              style: StrokeStyle(lineWidth: ringWidth - 3, dash: [10, 7]))
                .opacity(liveKind == nil ? 0.55 + 0.45 * breath : 0) // live: breathing Core Animation ring
        default:
            if p.ring.count > 1 {
                Circle().strokeBorder(AngularGradient(gradient: Gradient(colors: p.ring), center: .center,
                                                      angle: .degrees(-90)), lineWidth: ringWidth)
            } else {
                Circle().strokeBorder(p.ring[0], lineWidth: ringWidth)
            }
        }
    }

    /// Soft top highlight on lit discs (glassy, but subtle).
    @ViewBuilder
    private func gloss(disc: CGFloat, lit: Bool, strength: Double) -> some View {
        if lit {
            Ellipse()
                .fill(LinearGradient(colors: [Color.white.opacity(strength), Color.white.opacity(0)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: disc * 0.86, height: disc * 0.56)
                .offset(y: -disc * 0.22)
                .frame(width: disc, height: disc)
                .clipShape(Circle())
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func label(_ p: ButtonPalette) -> some View {
        let shout = info.style == .ready || info.style == .connecting || info.style == .connected
        // "VERBINDE …": the dots are drawn as an animated row below the word.
        let dots = info.style == .connecting && info.title.hasSuffix(" …")
        let title = dots ? String(info.title.dropLast(2)) : info.title
        VStack(spacing: 6) {
            if let s = info.symbol {
                Image(systemName: s)
                    .font(.system(size: shout ? 30 : 32, weight: shout ? .heavy : .medium))
            }
            Text(title)
                .font(.system(size: shout ? 25 : 18, weight: shout ? .heavy : .semibold, design: .rounded))
                .tracking(shout ? 1.4 : 0)
                .multilineTextAlignment(.center)
                .lineLimit(shout ? 1 : 2)
                .minimumScaleFactor(0.7)
            if dots {
                HStack(spacing: 7) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle().frame(width: 7, height: 7)
                            .opacity(dot(i))
                    }
                }
                .padding(.top, 2)
            }
        }
        .foregroundColor(p.label)
        .shadow(color: p.lit ? Color.black.opacity(0.18) : .clear, radius: 1, y: 1)
    }
}

/// The moving parts of the big button as Core Animation layers: repeat-forever CAAnimations run in the render
/// server, so the pulsing costs (almost) no CPU in the app – unlike a SwiftUI TimelineView/implicit animation
/// (measured: 11–20 % CPU). Removed (= stopped) when the window is hidden or with Reduce Motion.
struct ButtonAnimationLayerView: NSViewRepresentable {
    enum Kind: Equatable { case readyPulse, spinner(dark: Bool), waitingRing(dark: Bool) }
    let kind: Kind
    let diameter: CGFloat
    let ringWidth: CGFloat

    func makeNSView(context: Context) -> LayerHost { LayerHost() }

    func updateNSView(_ v: LayerHost, context: Context) {
        v.configure(kind: kind, diameter: diameter, ringWidth: ringWidth)
    }

    final class LayerHost: NSView {
        private var current: (Kind, CGFloat, CGFloat)?
        private let root = CALayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
            layer?.addSublayer(root)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            root.frame = bounds
            for l in root.sublayers ?? [] { l.position = CGPoint(x: bounds.midX, y: bounds.midY) }
            CATransaction.commit()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            setScale(root)
        }

        var animationSummary: String {
            func keys(_ l: CALayer) -> [String] { (l.animationKeys() ?? []) + (l.sublayers ?? []).flatMap(keys) }
            return keys(root).joined(separator: ",")
        }

        /// Previews: animations removed, a representative frame as model values (render(in:) ignores animations).
        func freezeForPreview() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            for (i, l) in (root.sublayers ?? []).enumerated() {
                l.removeAllAnimations()
                if let shape = l as? CAShapeLayer, current?.0 == .readyPulse {
                    shape.opacity = i == 1 ? 0.55 : 0.25
                    shape.setAffineTransform(CGAffineTransform(scaleX: i == 1 ? 1.04 : 1.15, y: i == 1 ? 1.04 : 1.15))
                } else {
                    l.opacity = 1
                }
            }
        }

        private func setScale(_ l: CALayer) {
            l.contentsScale = window?.backingScaleFactor ?? 2
            l.sublayers?.forEach(setScale)
            l.mask.map(setScale)
        }

        func configure(kind: Kind, diameter d: CGFloat, ringWidth w: CGFloat) {
            if let c = current, c.0 == kind, c.1 == d, c.2 == w { return }
            current = (kind, d, w)
            root.sublayers?.forEach { $0.removeFromSuperlayer() }
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let now = CACurrentMediaTime()
            func circle(_ diameter: CGFloat) -> CGPath {
                CGPath(ellipseIn: CGRect(x: 0, y: 0, width: diameter, height: diameter), transform: nil)
            }
            func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
                CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                        blue: CGFloat(hex & 0xFF) / 255, alpha: a)
            }
            switch kind {
            case .readyPulse:
                // Breathing glow (extra radial layer over the static one)
                let canvas = d * 1.255
                let glow = CAGradientLayer()
                glow.type = .radial
                glow.bounds = CGRect(x: 0, y: 0, width: canvas, height: canvas)
                glow.startPoint = CGPoint(x: 0.5, y: 0.5)
                glow.endPoint = CGPoint(x: 1, y: 1)
                glow.colors = [color(0x34E37E, 0.30), color(0x34E37E, 0.30), color(0x34E37E, 0.12), color(0x34E37E, 0)]
                glow.locations = [0, 0.70, 0.80, 1]
                glow.opacity = 0
                let breathe = CABasicAnimation(keyPath: "opacity")
                breathe.fromValue = 0
                breathe.toValue = 1
                breathe.duration = 1.3
                breathe.autoreverses = true
                breathe.repeatCount = .infinity
                breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                glow.add(breathe, forKey: "breathe")
                root.addSublayer(glow)
                // Two rings expanding and fading, half a period apart
                for i in 0..<2 {
                    let ring = CAShapeLayer()
                    ring.bounds = CGRect(x: 0, y: 0, width: d, height: d)
                    ring.path = circle(d)
                    ring.fillColor = nil
                    ring.strokeColor = color(0x34E37E)
                    ring.lineWidth = 2.5
                    ring.opacity = 0
                    let scale = CABasicAnimation(keyPath: "transform.scale")
                    scale.fromValue = 1
                    scale.toValue = 1.22
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = 0.6
                    fade.toValue = 0
                    let g = CAAnimationGroup()
                    g.animations = [scale, fade]
                    g.duration = 2.6
                    g.repeatCount = .infinity
                    g.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    g.beginTime = now + Double(i) * 1.3
                    g.fillMode = .backwards
                    ring.add(g, forKey: "pulse")
                    root.addSublayer(ring)
                }
            case .spinner(let dark):
                // "Comet" arc from angle 0 (tail) to −108° (head), rotating towards decreasing angles, so the head
                // leads. Colour: conic gradient masked by the arc. Whether the conic runs with or against the angle
                // depends on the layer's flip state – so it has a ramp for both cases; the mask shows only one of them.
                let box = CALayer()
                box.bounds = CGRect(x: 0, y: 0, width: d, height: d)
                let head = dark ? color(0x9BFFCF) : color(0x12B85F)
                let clear = head.copy(alpha: 0)!
                let grad = CAGradientLayer()
                grad.type = .conic
                grad.frame = box.bounds
                grad.startPoint = CGPoint(x: 0.5, y: 0.5)
                grad.endPoint = CGPoint(x: 1, y: 0.5)
                // head colour reaches a little past the arc end, so the round cap is not cut off
                grad.colors = [clear, head, head, clear, clear, head, head, clear]
                grad.locations = [0, 0.30, 0.32, 0.34, 0.66, 0.68, 0.70, 1]
                let arc = CAShapeLayer()
                arc.frame = box.bounds
                let p = CGMutablePath()
                p.addArc(center: CGPoint(x: d / 2, y: d / 2), radius: d / 2 - w / 2,
                         startAngle: 0, endAngle: -0.30 * 2 * .pi, clockwise: true)
                arc.path = p
                arc.fillColor = nil
                arc.strokeColor = CGColor(gray: 0, alpha: 1)
                arc.lineWidth = w
                arc.lineCap = .round
                grad.mask = arc
                box.addSublayer(grad)
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = -2 * Double.pi
                spin.duration = 1.1
                spin.repeatCount = .infinity
                box.add(spin, forKey: "spin")
                root.addSublayer(box)
            case .waitingRing(let dark):
                let ring = CAShapeLayer()
                let inset = (w - 3) / 2
                ring.bounds = CGRect(x: 0, y: 0, width: d, height: d)
                ring.path = CGPath(ellipseIn: CGRect(x: inset, y: inset, width: d - 2 * inset, height: d - 2 * inset), transform: nil)
                ring.fillColor = nil
                ring.strokeColor = color(0x34E37E, dark ? 0.85 : 0.75)
                ring.lineWidth = w - 3
                ring.lineDashPattern = [10, 7]
                let breathe = CABasicAnimation(keyPath: "opacity")
                breathe.fromValue = 0.45
                breathe.toValue = 1
                breathe.duration = 1.6
                breathe.autoreverses = true
                breathe.repeatCount = .infinity
                breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = -2 * Double.pi
                spin.duration = 60
                spin.repeatCount = .infinity
                ring.add(breathe, forKey: "breathe")
                ring.add(spin, forKey: "spin")
                root.addSublayer(ring)
            }
            for l in root.sublayers ?? [] { l.position = center }
            setScale(root)
        }
    }
}

private struct BigCircleButtonStyle: ButtonStyle {
    var hover: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : (hover ? 1.02 : 1))
            .brightness(configuration.isPressed ? -0.05 : (hover ? 0.03 : 0))
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hover)
    }
}

/// Top area of the setup window: the big button, a status line and "Trennen".
struct ConnectHero: View {
    @ObservedObject var model: SetupModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let info = model.button
        VStack(spacing: 2) {
            BigConnectButton(info: info, visible: model.windowVisible) { model.pressMainButton() }
                .padding(.top, 2)
            VStack(spacing: 3) {
                Text(info.caption ?? " ")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(captionColor(info.style))
                Text(info.detail ?? " ")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .padding(.horizontal, 24)
            HStack(spacing: 10) {
                if info.showDisconnect {
                    Button { model.actions?.disconnect() } label: {
                        Label("Trennen", systemImage: "xmark.circle").padding(.horizontal, 6)
                    }
                    .controlSize(.regular)
                    .help(info.style == .waiting ? "Nicht mehr automatisch verbinden" : "Virtuellen Bildschirm entfernen – der iMac zeigt wieder „Jetzt verbinden“")
                }
                if info.showEnableTransmission {
                    Button("Übertragung einschalten") { model.actions?.setTransmission(true) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(height: 30)
            .padding(.top, 6)
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(background(info.style))
    }

    private func captionColor(_ style: ConnectButtonInfo.Style) -> Color {
        switch style {
        case .ready, .connected: return colorScheme == .dark ? ButtonPalette.bright : ButtonPalette.deep
        case .blocked: return .orange
        default: return .primary
        }
    }

    @ViewBuilder
    private func background(_ style: ConnectButtonInfo.Style) -> some View {
        let tint: Color = {
            switch style {
            case .ready: return ButtonPalette.bright.opacity(colorScheme == .dark ? 0.13 : 0.10)
            case .connected, .connecting: return ButtonPalette.mid.opacity(colorScheme == .dark ? 0.09 : 0.06)
            case .blocked: return Color.orange.opacity(0.06)
            default: return .clear
            }
        }()
        RadialGradient(colors: [tint, tint.opacity(0)], center: UnitPoint(x: 0.5, y: 0.38), startRadius: 60, endRadius: 360)
            .animation(.easeInOut(duration: 0.4), value: style)
    }
}

/// "iMac-Helligkeit": slider + −/+; sends while dragging (throttled by the controller), shows what the iMac reports.
struct BrightnessSection: View {
    @ObservedObject var model: SetupModel
    /// Value under the mouse while dragging (the reported value must not fight the slider).
    @State private var dragValue: Double?

    var body: some View {
        let enabled = model.brightnessEnabled
        let value = dragValue ?? model.app.brightnessValue ?? 0.5
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Label("iMac-Helligkeit", systemImage: "sun.max")
                    .font(.headline)
                    .frame(width: 150, alignment: .leading)
                Button { model.stepBrightness(-1) } label: { Image(systemName: "minus").frame(width: 14, height: 14) }
                    .help("Dunkler (−6 %)")
                    .disabled(!enabled || value <= 0.001)
                Image(systemName: "sun.min").foregroundColor(.secondary)
                Slider(value: Binding(get: { value }, set: { v in
                    dragValue = v
                    model.actions?.setBrightness(v, final: false)
                }), in: 0...1, onEditingChanged: { editing in
                    if !editing {
                        if let v = dragValue { model.actions?.setBrightness(v, final: true) }
                        dragValue = nil
                    }
                })
                .disabled(!enabled)
                Image(systemName: "sun.max.fill").foregroundColor(.secondary)
                Button { model.stepBrightness(+1) } label: { Image(systemName: "plus").frame(width: 14, height: 14) }
                    .help("Heller (+6 %)")
                    .disabled(!enabled || value >= 0.999)
                Text(enabled || model.app.brightnessValue != nil ? "\(Int((value * 100).rounded())) %" : "–")
                    .font(.body.monospacedDigit())
                    .foregroundColor(enabled ? .primary : .secondary)
                    .frame(width: 46, alignment: .trailing)
            }
            if let hint = model.brightnessHint {
                Text(hint).font(.caption).foregroundColor(.secondary)
                    .padding(.leading, 160)
            }
        }
    }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel
    /// Previews: expand all "Was wird geändert?" sections is not possible with DisclosureGroup state, so ignore.
    var body: some View {
        let summary = model.summary
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "display").font(.system(size: 30)).foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("iMac Display – Einrichtung & Status").font(.title3).bold()
                    HStack(spacing: 4) {
                        StatusIcon(state: summary.0, size: 12)
                        Text(summary.1).font(.callout).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            if model.app.dryRun {
                Text("Testmodus (Dry-Run): Änderungen am System werden nur protokolliert, nicht ausgeführt.")
                    .font(.caption).frame(maxWidth: .infinity).padding(6).background(Color.yellow.opacity(0.35))
            }
            if let m = model.message {
                Text(m).font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.1)).textSelection(.enabled)
            }
            Divider()
            ConnectHero(model: model)
            BrightnessSection(model: model).padding(.horizontal, 18).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    let rows = model.rows
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                        CheckRowView(row: r)
                        if i < rows.count - 1 { Divider() }
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 4)
            }
            Divider()
            BottomBar(model: model).padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(minWidth: 620, idealWidth: SetupWindowController.defaultSize.width,
               minHeight: 700, idealHeight: SetupWindowController.defaultSize.height)
        .sheet(isPresented: $model.showUninstall) { UninstallView(model: model) }
    }
}

struct BottomBar: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 24) {
                Toggle("Übertragung aktiv", isOn: Binding(get: { model.app.transmissionEnabled },
                                                          set: { model.actions?.setTransmission($0) }))
                    .toggleStyle(.switch)
                Toggle("Bei Anmeldung starten", isOn: Binding(get: { model.app.loginStatus == .enabled },
                                                              set: { model.actions?.setLoginItem($0) }))
                    .toggleStyle(.switch)
                    .disabled(!model.app.inApplications && !model.app.dryRun && model.app.loginStatus != .enabled)
                Spacer()
            }
            HStack {
                Text(loginText).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.app.loginStatus == .requiresApproval {
                    Button("Bestätigen …") { model.actions?.openSettings(SettingsURL.loginItems) }.controlSize(.small)
                }
                Spacer()
                Button("Protokoll anzeigen") { model.actions?.showLog() }
                Button("Deinstallieren …") { model.openUninstall() }
            }
        }
    }

    private var loginText: String {
        switch model.app.loginStatus {
        case .enabled: return "Startet automatisch bei der Anmeldung."
        case .requiresApproval: return "Start bei Anmeldung wartet auf deine Bestätigung in den Systemeinstellungen."
        case _ where !model.app.inApplications:
            return "Automatischer Start geht erst, wenn die App im Ordner „Programme“ liegt."
        default: return "Startet nicht automatisch – einschalten, damit der iMac nach jedem Neustart gleich Bild bekommt."
        }
    }
}

struct UninstallView: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        let backups = model.networkBackups
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "trash").font(.system(size: 26)).foregroundColor(.red)
                Text("iMac Display deinstallieren").font(.title3).bold()
            }
            Text("Die angehakten Punkte werden rückgängig gemacht bzw. entfernt. Danach beendet sich iMac Display.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                item($model.uninstall.loginItem, "Automatischen Start abmelden", "„Bei Anmeldung starten“ wird ausgeschaltet.")
                item($model.uninstall.screenCapture, "Erlaubnis „Bildschirmaufnahme“ entfernen",
                     "Nur der Eintrag dieser App, kein Passwort nötig (tccutil reset ScreenCapture de.local.imac-display).")
                if !backups.isEmpty {
                    item($model.uninstall.network,
                         backups.count == 1 ? "Netzwerkeinstellung von „\(backups[0])“ zurücksetzen" : "Netzwerkeinstellungen zurücksetzen",
                         backups.map { "„\($0)“ zurück auf: \(NetworkSetup.restoreDescription(service: $0))" }.joined(separator: "\n")
                            + "\nFragt nach dem Administrator-Passwort.")
                } else {
                    notChanged("Netzwerkeinstellung", "Wurde von der App nicht geändert – bleibt, wie sie ist.")
                }
                if model.firewallEntry {
                    item($model.uninstall.firewall, "Firewall-Eintrag entfernen",
                         "Den Eintrag „iMac Display“ in der Firewall-Liste – fragt nach dem Administrator-Passwort.")
                }
                item($model.uninstall.prefsAndLog, "Einstellungen und Protokoll löschen",
                     "Einstellungen (de.local.imac-display) und ~/Library/Logs/iMacDisplay.log")
                item($model.uninstall.app, "Die App in den Papierkorb legen", model.app.bundlePath)
            }
            .padding(12).background(Color.secondary.opacity(0.07)).cornerRadius(8)
            if model.app.dryRun {
                Text("Testmodus (Dry-Run): es wird nichts entfernt, nur protokolliert.").font(.caption).foregroundColor(.orange)
            }
            HStack {
                Spacer()
                Button("Abbrechen") { model.showUninstall = false }.keyboardShortcut(.cancelAction)
                Button("Entfernen und beenden") {
                    model.showUninstall = false
                    let o = model.uninstall
                    DispatchQueue.main.async { model.actions?.performUninstall(o) }
                }
                .buttonStyle(.borderedProminent).tint(.red)
            }
        }
        .padding(20).frame(width: 520)
    }

    private func notChanged(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "minus.circle").foregroundColor(.gray)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundColor(.secondary)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func item(_ b: Binding<Bool>, _ title: String, _ detail: String) -> some View {
        Toggle(isOn: b) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
    }
}

// MARK: - Window

@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    let model: SetupModel
    private var window: NSWindow?

    init(model: SetupModel) { self.model = model }

    var isVisible: Bool { window?.isVisible == true }

    /// v2: taller (big connect button + brightness above the checklist).
    static let defaultSize = NSSize(width: 680, height: 960)

    func show(activate: Bool = true) {
        if window == nil {
            var size = Self.defaultSize
            if let vis = NSScreen.main?.visibleFrame { size.height = min(size.height, vis.height - 40) }
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "iMac Display – Einrichtung & Status"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SetupView(model: model))
            w.setContentSize(size)
            w.contentMinSize = NSSize(width: 620, height: 700)
            w.center()
            w.delegate = self
            // New name: the frame saved by 1.1 (660×820) would be too small for the new layout.
            w.setFrameAutosaveName("SetupWindowV2")
            window = w
        }
        if activate {
            if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFrontRegardless() // tests: no focus change
        }
        model.windowVisible = true
    }

    func close() { window?.close() }

    /// Tests: which Core Animation animations run in the big button right now.
    func animationLayerSummary() -> String {
        func find(_ v: NSView) -> [ButtonAnimationLayerView.LayerHost] {
            (v as? ButtonAnimationLayerView.LayerHost).map { [$0] } ?? v.subviews.flatMap(find)
        }
        guard let content = window?.contentView else { return "kein Fenster" }
        let hosts = find(content)
        if hosts.isEmpty { return "keine (statisch)" }
        return hosts.map { $0.animationSummary }.joined(separator: "; ")
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let w = window else { return }
        let v = w.isVisible && w.occlusionState.contains(.visible)
        if model.windowVisible != v { model.windowVisible = v }
    }

    func windowWillClose(_ notification: Notification) {
        model.windowVisible = false
    }
}

// MARK: - Preview rendering (development: --render-setup-preview <dir>)

@MainActor
final class NoopActions: SetupActions {
    func moveToApplications() {}
    func requestScreenCapture() {}
    func revokeScreenCapture() {}
    func resetScreenCaptureEntry() {}
    func relaunchApp() {}
    func configureNetwork(service: String) {}
    func restoreNetwork(service: String) {}
    func openSettings(_ url: String) {}
    func setTransmission(_ on: Bool) {}
    func setLoginItem(_ on: Bool) {}
    func showLog() {}
    func performUninstall(_ o: UninstallOptions) {}
    func connect() {}
    func disconnect() {}
    func setBrightness(_ value: Double, final: Bool) {}
}

enum SetupPreview {
    @MainActor
    static func render(to dir: String) -> Int32 {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let actions = NoopActions()
        func usb(active: Bool, addr: Bool) -> WiredInterface {
            WiredInterface(device: "en11", portName: "USB 10/100/1000 LAN", serviceName: "USB 10/100/1000 LAN",
                           linkActive: active, media: active ? "1000baseT <full-duplex>" : "none",
                           ipv4: addr && active ? [NetworkSetup.macIP] : [])
        }
        func cfg(_ manual: Bool) -> ServiceIPv4Config {
            manual ? ServiceIPv4Config(service: "USB 10/100/1000 LAN", mode: .manual, ip: NetworkSetup.macIP,
                                       subnet: NetworkSetup.netmask, router: nil, raw: "")
                : ServiceIPv4Config(service: "USB 10/100/1000 LAN", mode: .dhcp, ip: nil, subnet: nil, router: nil, raw: "")
        }
        var base = AppStatus()
        base.bundlePath = "/Applications/iMac Display.app"
        base.inApplications = true
        base.screenCaptureGranted = true
        base.serverRunning = true
        base.loginStatus = .enabled

        var good = ProbeResult(); good.wired = [usb(active: true, addr: true)]; good.chosen = good.wired.first
        good.chosenConfig = cfg(true); good.pingOK = true; good.firewallOn = true; good.firewallBlockAll = false

        var states: [(String, AppStatus, ProbeResult)] = []

        // 1) Normal: everything running (connected)
        var a = base
        a.clients = 1; a.clientIP = "10.77.0.2"; a.displayActive = true; a.capturing = true; a.fps = 52; a.mbit = 48
        a.clientStats = ["fps": 51.9, "hw": "prefer-hardware", "dropped": 0, "decodeMs": 4.1]
        a.phase = .connected; a.connectWanted = true; a.receiverVersion = "1.3"
        a.brightnessSupported = true; a.brightnessValue = 0.62
        var p = good
        states.append(("1-normal", a, p))

        // 2) Missing Screen Recording permission, app still in Downloads, iMac reachable but not connected
        a = base; a.screenCaptureGranted = false; a.inApplications = false
        a.bundlePath = NSHomeDirectory() + "/Downloads/iMac Display.app"; a.loginStatus = .notFound
        a.phase = .unavailable
        p.pingOK = true
        states.append(("2-keine-berechtigung", a, p))

        // 3) No cable, address not set yet
        a = base; a.phase = .unavailable
        p = ProbeResult(); p.wired = [usb(active: false, addr: false)]; p.chosen = p.wired.first
        p.chosenConfig = cfg(false); p.firewallOn = false; p.firewallBlockAll = false
        states.append(("3-kein-kabel", a, p))

        // 4) Cable plugged in, address missing (error), local network hint, dry run
        a = base; a.dryRun = true; a.loginStatus = .requiresApproval; a.phase = .unavailable
        p = ProbeResult(); p.wired = [usb(active: true, addr: false)]; p.chosen = p.wired.first
        p.chosenConfig = cfg(false); p.firewallOn = true; p.firewallBlockAll = false
        states.append(("4-adresse-fehlt", a, p))

        // 5) Transmission off
        a = base; a.transmissionEnabled = false; a.serverRunning = false; a.phase = .off
        p = good; p.firewallOn = false
        states.append(("5-uebertragung-aus", a, p))

        var ok = true
        for (name, app, probe) in states {
            let m = SetupModel(actions: actions)
            m.update(app: app, probe: probe)
            ok = write(NSHostingView(rootView: SetupView(model: m).environment(\.connectAnimationTime, 0.9)),
                       size: SetupWindowController.defaultSize, to: "\(dir)/setup-\(name).png") && ok
        }
        // Local network hint variant
        do {
            var a = base; a.clients = 0; a.phase = .unavailable
            let m = SetupModel(actions: actions)
            m.update(app: a, probe: good)
            m.forceLocalNetworkHint = true
            ok = write(NSHostingView(rootView: SetupView(model: m).environment(\.connectAnimationTime, 0.9)),
                       size: SetupWindowController.defaultSize, to: "\(dir)/setup-6-lokales-netzwerk.png") && ok
        }

        // Every state of the big button, light + dark: whole window and the top area alone.
        var connected = base
        connected.clients = 1; connected.clientIP = "10.77.0.2"; connected.displayActive = true; connected.capturing = true
        connected.fps = 52; connected.mbit = 48; connected.phase = .connected; connected.connectWanted = true
        connected.receiverVersion = "1.3"; connected.brightnessSupported = true; connected.brightnessValue = 0.62
        connected.clientStats = ["fps": 51.9, "hw": "prefer-hardware", "dropped": 0, "decodeMs": 4.1]
        var ready = base
        ready.clients = 1; ready.clientIP = "10.77.0.2"; ready.phase = .ready; ready.receiverVersion = "1.3"
        ready.brightnessSupported = true; ready.brightnessValue = 0.75
        var connecting = ready
        connecting.phase = .connecting; connecting.connectWanted = true; connecting.displayActive = true
        var blocked = connecting
        blocked.displayActive = false; blocked.screenCaptureGranted = false
        blocked.connectProblem = "Bildschirmaufnahme ist nicht erlaubt"
        var waiting = base
        waiting.phase = .waitingForIMac; waiting.connectWanted = true
        var unavailable = base
        unavailable.phase = .unavailable
        var off = base
        off.transmissionEnabled = false; off.serverRunning = false; off.phase = .off
        var noCable = ProbeResult(); noCable.wired = [usb(active: false, addr: false)]; noCable.chosen = noCable.wired.first
        noCable.chosenConfig = cfg(true); noCable.firewallOn = false; noCable.firewallBlockAll = false
        var unsupported = ready
        unsupported.brightnessSupported = false; unsupported.brightnessValue = nil

        let buttonStates: [(String, AppStatus, ProbeResult, Double)] = [
            ("a-ready", ready, good, 0.9),
            ("b-connecting", connecting, good, 0.35),
            ("c-connected", connected, good, 0),
            ("d-waiting", waiting, noCable, 0.6),
            ("e-unavailable-kabel", unavailable, noCable, 0),
            ("f-unavailable-app", unavailable, good, 0),
            ("g-off", off, good, 0),
            ("h-blocked", blocked, good, 0),
            ("i-ready-helligkeit-nicht-unterstuetzt", unsupported, good, 2.2),
        ]
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            for (name, app, probe, t) in buttonStates {
                let m = SetupModel(actions: actions)
                m.update(app: app, probe: probe)
                ok = write(NSHostingView(rootView: SetupView(model: m).environment(\.connectAnimationTime, t)),
                           size: SetupWindowController.defaultSize, to: "\(dir)/window-\(name)-\(mode).png", dark: dark) && ok
                let hero = VStack(spacing: 0) {
                    ConnectHero(model: m)
                    BrightnessSection(model: m).padding(.horizontal, 18).padding(.vertical, 10)
                }
                .environment(\.connectAnimationTime, t)
                ok = write(NSHostingView(rootView: hero), size: NSSize(width: 680, height: 420),
                           to: "\(dir)/hero-\(name)-\(mode).png", dark: dark) && ok
            }
        }
        // Live composition (SwiftUI + Core Animation layers), animations frozen: geometry/orientation check.
        for dark in [false, true] {
            for (name, style) in [("ready", ConnectButtonInfo.Style.ready), ("spinner", .connecting), ("waiting", .waiting)] {
                var app = base
                app.phase = style == .ready ? .ready : (style == .connecting ? .connecting : .waitingForIMac)
                app.clients = style == .waiting ? 0 : 1
                app.connectWanted = style != .ready
                let m = SetupModel(actions: actions)
                m.update(app: app, probe: good)
                let view = NSHostingView(rootView: BigConnectButton(info: m.button, visible: true) {}.frame(width: 300, height: 300))
                ok = write(view, size: NSSize(width: 300, height: 300), to: "\(dir)/ca-\(name)-\(dark ? "dark" : "light").png",
                           dark: dark, prepare: { v in
                    @MainActor func find(_ v: NSView) -> ButtonAnimationLayerView.LayerHost? {
                        if let h = v as? ButtonAnimationLayerView.LayerHost { return h }
                        for s in v.subviews { if let h = find(s) { return h } }
                        return nil
                    }
                    if let h = find(v) { h.freezeForPreview() } else { print("FEHLER: keine Animationsebene gefunden (\(name))") }
                }) && ok
            }
        }
        // Pulse animation frames (ready): a short strip to judge the motion.
        for (i, t) in [0.0, 0.65, 1.3, 1.95].enumerated() {
            let m = SetupModel(actions: actions)
            m.update(app: ready, probe: good)
            ok = write(NSHostingView(rootView: ConnectHero(model: m).environment(\.connectAnimationTime, t)),
                       size: NSSize(width: 680, height: 340), to: "\(dir)/pulse-\(i)-dark.png", dark: true) && ok
        }

        // Uninstall sheet
        let m = SetupModel(actions: actions)
        m.update(app: base, probe: nil)
        m.networkBackups = ["USB 10/100/1000 LAN"]
        m.firewallEntry = true
        ok = write(NSHostingView(rootView: UninstallView(model: m)), size: NSSize(width: 520, height: 520),
                   to: "\(dir)/uninstall-sheet.png") && ok
        return ok ? 0 : 1
    }

    @MainActor
    private static func write(_ view: NSView, size: NSSize, to path: String, dark: Bool = false,
                              prepare: (@MainActor (NSView) -> Void)? = nil) -> Bool {
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.backgroundColor = .windowBackgroundColor
        w.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        w.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        view.layoutSubtreeIfNeeded()
        prepare?(view)
        defer { w.orderOut(nil) }
        // CALayer rendering: cacheDisplay(in:to:) misses the macOS 26 controls and transparency.
        let scale = 2.0
        guard let layer = view.layer,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return false }
        rep.size = size
        w.effectiveAppearance.performAsCurrentDrawingAppearance {
            ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
        }
        ctx.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        ctx.translateBy(x: 0, y: size.height * scale)
        ctx.scaleBy(x: scale, y: -scale)
        layer.render(in: ctx)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        let ok = (try? png.write(to: URL(fileURLWithPath: path))) != nil
        print((ok ? "Gespeichert: " : "FEHLER: ") + path)
        return ok
    }
}
