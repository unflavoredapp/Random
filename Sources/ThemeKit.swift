//
//  ThemeKit.swift
//  Live theme state (accent · appearance · background), the palette dropdown
//  shown from the top bar, and the particle-network background.
//

import SwiftUI

// MARK: - State

enum ThemeBackground: String, CaseIterable, Identifiable {
    case particles, grid, none
    var id: String { rawValue }
    var title: String {
        switch self { case .particles: return "Particles"; case .grid: return "Grid"; case .none: return "Plain" }
    }
    var icon: String {
        switch self { case .particles: return "sparkles"; case .grid: return "square.grid.3x3"; case .none: return "rectangle" }
    }
}

enum CycleMode: String, CaseIterable, Identifiable {
    case off, background, app
    var id: String { rawValue }
    var title: String { switch self { case .off: return "Off"; case .background: return "Background"; case .app: return "Whole app" } }
    var icon: String { switch self { case .off: return "nosign"; case .background: return "sparkles"; case .app: return "paintpalette.fill" } }
}

/// Rotates a color's hue by `turns` (1 = full circle). Cheap enough to call per frame.
nonisolated func hueShifted(_ c: Color, by turns: Double) -> Color {
    var h: CGFloat = 0, sa: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    UIColor(c).getHue(&h, saturation: &sa, brightness: &b, alpha: &a)
    var nh = Double(h) + turns
    nh -= floor(nh)
    return Color(hue: nh, saturation: Double(sa), brightness: Double(b), opacity: Double(a))
}

enum ParticleTouchMode: String, CaseIterable, Identifiable {
    case grab, repulse, attract, off
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self { case .grab: return "hand.point.up.left.fill"; case .repulse: return "arrow.up.left.and.arrow.down.right"
                      case .attract: return "arrow.down.right.and.arrow.up.left"; case .off: return "nosign" }
    }
}

/// Finger position shared with the particle layer (read every frame, no SwiftUI invalidation).
final class ParticleTouch: @unchecked Sendable {
    nonisolated(unsafe) static var point: CGPoint?
    nonisolated(unsafe) static var pulse: (p: CGPoint, t: TimeInterval)?
}

@MainActor
final class AppTheme: ObservableObject {
    static let shared = AppTheme()
    private let d = UserDefaults.standard

    /// Bumped on every change; RootView re-ids the tab content so every view re-reads Theme.*.
    @Published private(set) var revision = 0
    @Published var panelShown = false

    @Published var accentHex: String { didSet { d.set(accentHex, forKey: Theme.keyAccent); bump() } }
    @Published var isDark: Bool { didSet { d.set(isDark, forKey: Theme.keyDark); bump() } }
    @Published var background: ThemeBackground { didSet { d.set(background.rawValue, forKey: Theme.keyBackground); bump() } }

    /// Particle tuning. Not part of `revision`, so dragging a slider never re-skins the app.
    @Published var particleDensity: Double { didSet { d.set(particleDensity, forKey: "as_p_density") } }
    @Published var particleSpeed: Double { didSet { d.set(particleSpeed, forKey: "as_p_speed") } }
    @Published var particleTouch: ParticleTouchMode { didSet { d.set(particleTouch.rawValue, forKey: "as_p_touch") } }

    /// Auto-cycle: `.background` drifts only the particle/grid layer (smooth, no re-skin);
    /// `.app` steps the real accent every 10 s, recoloring live without closing anything you have open.
    @Published var cycleMode: CycleMode { didSet { d.set(cycleMode.rawValue, forKey: "as_cycle"); restartCycle() } }
    private var cycleTask: Task<Void, Never>?

    /// While true, accent changes do not bump `revision` (no view rebuild) — views that observe the
    /// theme simply re-read the new color, so open sheets, screens and scroll positions are kept.
    private var cycling = false

    private func restartCycle() {
        cycleTask?.cancel(); cycleTask = nil
        guard cycleMode == .app else { return }
        cycleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, let self else { return }
                let next = hueShifted(Color(hex: self.accentHex), by: 0.03)
                if let h = next.hexString() {
                    self.cycling = true
                    self.accentHex = h.replacingOccurrences(of: "#", with: "").uppercased()
                    self.cycling = false
                }
            }
        }
    }

    private init() {
        cycleMode = CycleMode(rawValue: d.string(forKey: "as_cycle") ?? "") ?? .off
        particleDensity = (d.object(forKey: "as_p_density") as? Double) ?? 1.0
        particleSpeed   = (d.object(forKey: "as_p_speed") as? Double) ?? 1.0
        particleTouch   = ParticleTouchMode(rawValue: d.string(forKey: "as_p_touch") ?? "") ?? .grab
        accentHex  = Theme.accentHex
        isDark     = Theme.isDark
        background = ThemeBackground(rawValue: d.string(forKey: Theme.keyBackground) ?? "") ?? .particles
    }
    private func bump() { if !cycling { revision &+= 1 } }
    func startCycleIfNeeded() { if cycleMode == .app && cycleTask == nil { restartCycle() } }

    var accent: Color { Color(hex: accentHex) }
    var colorScheme: ColorScheme { isDark ? .dark : .light }

    static let presets: [String] = ["FF9A1F", "2ED9C3", "FFA773", "64CCFF", "B366FF", "FF66B2", "90EE90", "FFCC00", "FF453A", "FFFFFF"]
}

// MARK: - Palette button (top bar)

struct ThemePaletteButton: View {
    @ObservedObject private var theme = AppTheme.shared
    var body: some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            theme.panelShown.toggle()
        } label: {
            Image(systemName: "paintpalette.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Theme")
    }
}

// MARK: - Dropdown panel (compact)

struct ThemePanel: View {
    @ObservedObject private var theme = AppTheme.shared
    @State private var wheelShown = false
    @State private var hexText = ""
    @State private var hue: Double = 0
    @State private var sat: Double = 1
    @State private var bri: Double = 1
    @FocusState private var hexFocus: Bool
    @State private var lastLive = Date.distantPast

    private var draft: Color { Color(hue: hue, saturation: sat, brightness: bri) }

    var body: some View {
        VStack(spacing: 8) {
            // Square color box · hex input · chevron
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(wheelShown ? draft : theme.accent)
                    .frame(width: 30, height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.35), lineWidth: 1))
                HStack(spacing: 2) {
                    Text("#").font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(Theme.subtle)
                    TextField("FF9A1F", text: $hexText)
                        .font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(Theme.text)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .focused($hexFocus).submitLabel(.done)
                        .onSubmit { commitHex() }
                        .onChange(of: hexText) { v in
                            let c = String(v.uppercased().filter { $0.isHexDigit }.prefix(6))
                            if c != v { hexText = c }
                        }
                }
                .padding(.horizontal, 8).frame(height: 30)
                .background(Color.white.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Button {
                    hexFocus = false
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { wheelShown.toggle() }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent)
                        .rotationEffect(.degrees(wheelShown ? 180 : 0)).frame(width: 28, height: 30)
                }
                .buttonStyle(.plain)
            }

            if wheelShown {
                VStack(spacing: 10) {
                    HueWheel(hue: $hue, sat: $sat, bri: bri, onChange: { commitLive() }, onEnd: { commitDraft() })
                        .frame(width: 150, height: 150)
                    HStack(spacing: 8) {
                        Image(systemName: "sun.min").font(.system(size: 11)).foregroundStyle(Theme.subtle)
                        Slider(value: $bri, in: 0.15...1) { editing in if !editing { commitDraft() } }.tint(Theme.accent)
                            .onChange(of: bri) { _ in commitLive() }
                        Image(systemName: "sun.max.fill").font(.system(size: 11)).foregroundStyle(Theme.subtle)
                    }
                    HStack(spacing: 7) {
                        ForEach(AppTheme.presets.prefix(8), id: \.self) { hex in
                            Button { theme.accentHex = hex; sync() } label: {
                                Circle().fill(Color(hex: hex)).frame(width: 16, height: 16)
                                    .overlay(Circle().stroke(Color.white.opacity(theme.accentHex.uppercased() == hex ? 0.95 : 0.15), lineWidth: 1.5))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Auto-cycle hue
            Menu {
                ForEach(CycleMode.allCases) { m in
                    Button { theme.cycleMode = m } label: { Label(m.title, systemImage: m == theme.cycleMode ? "checkmark" : m.icon) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 18)
                    Text("Auto-cycle").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.subtle)
                    Spacer(minLength: 4)
                    Text(theme.cycleMode.title).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.subtle)
                }
                .padding(.horizontal, 6).frame(height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().overlay(Theme.stroke)

            // Dynamic backgrounds dropdown
            Menu {
                ForEach(ThemeBackground.allCases) { b in
                    Button { theme.background = b } label: {
                        Label(b.title, systemImage: b == theme.background ? "checkmark" : b.icon)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: theme.background.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 18)
                    Text("Background").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.subtle)
                    Spacer(minLength: 4)
                    Text(theme.background.title).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.subtle)
                }
                .padding(.horizontal, 6).frame(height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if theme.background == .particles || theme.background == .grid {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "circle.grid.3x3.fill").font(.system(size: 11)).foregroundStyle(Theme.subtle).frame(width: 18)
                        Text("Density").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.subtle).frame(width: 52, alignment: .leading)
                        Slider(value: $theme.particleDensity, in: 0.3...2).tint(Theme.accent)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "speedometer").font(.system(size: 11)).foregroundStyle(Theme.subtle).frame(width: 18)
                        Text("Speed").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.subtle).frame(width: 52, alignment: .leading)
                        Slider(value: $theme.particleSpeed, in: 0.2...3).tint(Theme.accent)
                    }
                    Menu {
                        ForEach(ParticleTouchMode.allCases) { m in
                            Button { theme.particleTouch = m } label: { Label(m.title, systemImage: m == theme.particleTouch ? "checkmark" : m.icon) }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: theme.particleTouch.icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 18)
                            Text("Touch").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.subtle)
                            Spacer(minLength: 4)
                            Text(theme.particleTouch.title).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.subtle)
                        }
                        .padding(.horizontal, 0).frame(height: 26).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .transition(.opacity)
            }

            // Light / dark
            HStack(spacing: 8) {
                Image(systemName: theme.isDark ? "moon.fill" : "sun.max.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 18)
                Text(theme.isDark ? "Dark" : "Light").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.subtle)
                Spacer()
                Toggle("", isOn: $theme.isDark).labelsHidden().tint(Theme.accent).scaleEffect(0.8)
            }
            .padding(.horizontal, 6).frame(height: 26)
        }
        .padding(12)
        .frame(width: 230)
        .background(Theme.bg)
        .onAppear { sync() }
    }

    private func sync() {
        hexText = theme.accentHex.uppercased()
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(Color(hex: theme.accentHex)).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        hue = Double(h); sat = Double(s); bri = Double(b)
    }

    private func commitHex() {
        hexFocus = false
        let c = hexText.uppercased()
        guard c.count == 6 || c.count == 3 else { hexText = theme.accentHex.uppercased(); return }
        let full = c.count == 3 ? c.map { "\($0)\($0)" }.joined() : c
        theme.accentHex = full
        sync()
    }

    /// Live update while dragging (throttled to ~20/s so the re-skin stays smooth).
    private func commitLive() {
        let now = Date()
        guard now.timeIntervalSince(lastLive) > 0.05 else { return }
        lastLive = now
        commitDraft()
    }

    private func commitDraft() {
        if let h = draft.hexString() {
            theme.accentHex = h.replacingOccurrences(of: "#", with: "").uppercased()
            hexText = theme.accentHex
        }
    }
}

/// Hue (angle) / saturation (radius) wheel. Updates the accent live while dragging.
private struct HueWheel: View {
    @Binding var hue: Double
    @Binding var sat: Double
    let bri: Double
    let onChange: () -> Void
    let onEnd: () -> Void

    var body: some View {
        GeometryReader { g in
            let d = Swift.min(g.size.width, g.size.height), r = d / 2
            ZStack {
                Circle().fill(AngularGradient(gradient: Gradient(colors: (0...12).map { Color(hue: Double($0) / 12, saturation: 1, brightness: 1) }), center: .center))
                Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: r))
                Circle().fill(Color.black.opacity(1 - bri))
                Circle().fill(Color(hue: hue, saturation: sat, brightness: bri)).frame(width: 18, height: 18)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .position(x: r + CGFloat(sat) * r * CGFloat(cos(hue * 2 * .pi)),
                              y: r + CGFloat(sat) * r * CGFloat(sin(hue * 2 * .pi)))
            }
            .frame(width: d, height: d)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let dx = v.location.x - r, dy = v.location.y - r
                    var a = atan2(dy, dx) / (2 * .pi); if a < 0 { a += 1 }
                    hue = Double(a)
                    sat = Double(Swift.min(sqrt(dx * dx + dy * dy) / r, 1))
                    onChange()
                }
                .onEnded { _ in onEnd() })
        }
    }
}

// MARK: - Backgrounds

// MARK: - Shared timeline

struct BGTick { let date: Date }

/// One clock for the background. Pauses (still frame) only when the app is
/// inactive or the user has Reduce Motion on (an accessibility preference,
/// always respected). Low Power Mode used to hard-pause this too — that's
/// exactly what "dynamic backgrounds stopped working" (frozen/static) turned
/// out to be: the layer still rendered, it just never ticked again while
/// Low Power Mode was on. Now it just throttles to a much lower frame rate
/// instead of stopping outright, so it still visibly drifts/animates while
/// using meaningfully less power. Rasterized on the GPU so scrolling stays
/// smooth either way.
struct BGTimeline<Content: View>: View {
    @Environment(\.scenePhase) private var phase
    var fps: Double = 30
    @ViewBuilder let content: (BGTick) -> Content
    private var paused: Bool {
        phase != .active || UIAccessibility.isReduceMotionEnabled
    }
    private var effectiveFPS: Double {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? Swift.min(fps, 10) : fps
    }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / effectiveFPS, paused: paused)) { tl in
            content(BGTick(date: tl.date))
        }
        .drawingGroup()
    }
}

// MARK: - Particles (advanced)

/// particles.js-style network: depth layers (size / speed / brightness), twinkle, density by screen area,
/// distance-faded links, and finger interaction (grab / repulse / attract) plus a tap burst.
struct ParticleBackground: View {
    var accent: Color = Theme.accent
    var density: Double = 1
    var speed: Double = 1
    var touch: ParticleTouchMode = .grab
    var cycle: Bool = false
    var linkDistance: CGFloat = 120

    private final class Sim {
        struct Node { var x: CGFloat; var y: CGFloat; var vx: CGFloat; var vy: CGFloat
                      var ox: CGFloat = 0; var oy: CGFloat = 0      // finger-driven offset velocity (decays)
                      var z: CGFloat; var phase: Double }
        var nodes: [Node] = []
        var last: Date = .now
        var lastPulse: TimeInterval = 0

        func step(to date: Date, size: CGSize, count: Int, speed: CGFloat, touch: ParticleTouchMode) -> [Node] {
            if nodes.count != count {
                if nodes.count > count { nodes.removeLast(nodes.count - count) }
                while nodes.count < count {
                    nodes.append(Node(x: .random(in: 0...Swift.max(size.width, 1)), y: .random(in: 0...Swift.max(size.height, 1)),
                                      vx: .random(in: -16...16), vy: .random(in: -16...16),
                                      z: .random(in: 0.35...1), phase: .random(in: 0...(2 * .pi))))
                }
            }
            let dt = CGFloat(Swift.min(Swift.max(date.timeIntervalSince(last), 0), 0.1))
            last = date
            let tp = ParticleTouch.point
            var burst: (p: CGPoint, t: TimeInterval)? = nil
            if let pl = ParticleTouch.pulse, pl.t != lastPulse { burst = pl; lastPulse = pl.t }
            let decay = CGFloat(exp(-2.2 * Double(dt)))
            for i in nodes.indices {
                var n = nodes[i]
                if touch != .off, let tp {
                    let dx = n.x - tp.x, dy = n.y - tp.y
                    let dist = sqrt(dx * dx + dy * dy)
                    if dist < 140 && dist > 0.5 {
                        let f = (1 - dist / 140) * 420 * dt
                        if touch == .repulse { n.ox += dx / dist * f; n.oy += dy / dist * f }
                        else if touch == .attract { n.ox -= dx / dist * f * 0.8; n.oy -= dy / dist * f * 0.8 }
                    }
                }
                if let burst {
                    let dx = n.x - burst.p.x, dy = n.y - burst.p.y
                    let dist = Swift.max(sqrt(dx * dx + dy * dy), 1)
                    if dist < 190 { let f = (1 - dist / 190) * 260; n.ox += dx / dist * f; n.oy += dy / dist * f }
                }
                n.ox *= decay; n.oy *= decay
                n.x += (n.vx * n.z * speed + n.ox) * dt
                n.y += (n.vy * n.z * speed + n.oy) * dt
                // wrap softly off-screen instead of hard bouncing
                if n.x < -10 { n.x = size.width + 10 } else if n.x > size.width + 10 { n.x = -10 }
                if n.y < -10 { n.y = size.height + 10 } else if n.y > size.height + 10 { n.y = -10 }
                nodes[i] = n
            }
            return nodes
        }
    }
    @State private var sim = Sim()

    var body: some View {
        BGTimeline(fps: 30) { tl in
            Canvas { ctx, size in
                let accent = cycle ? hueShifted(self.accent, by: tl.date.timeIntervalSinceReferenceDate / 60) : self.accent
                let area = size.width * size.height
                let count = Swift.max(12, Swift.min(110, Int(area / 9000 * CGFloat(density))))
                let ns = sim.step(to: tl.date, size: size, count: count, speed: CGFloat(speed), touch: touch)
                let t = tl.date.timeIntervalSinceReferenceDate
                let ld2 = linkDistance * linkDistance
                // links, faded by distance, drawn in two opacity buckets (cheap)
                var near = Path(), far = Path()
                for i in 0..<ns.count {
                    for j in (i + 1)..<ns.count {
                        let dx = ns[i].x - ns[j].x, dy = ns[i].y - ns[j].y
                        let d2 = dx * dx + dy * dy
                        guard d2 < ld2 else { continue }
                        if d2 < ld2 * 0.42 { near.move(to: CGPoint(x: ns[i].x, y: ns[i].y)); near.addLine(to: CGPoint(x: ns[j].x, y: ns[j].y)) }
                        else { far.move(to: CGPoint(x: ns[i].x, y: ns[i].y)); far.addLine(to: CGPoint(x: ns[j].x, y: ns[j].y)) }
                    }
                }
                ctx.stroke(far, with: .color(accent.opacity(0.10)), lineWidth: 0.5)
                ctx.stroke(near, with: .color(accent.opacity(0.26)), lineWidth: 0.7)
                // grab: links from the finger to nearby nodes
                if touch == .grab, let tp = ParticleTouch.point {
                    var g = Path()
                    for n in ns {
                        let dx = n.x - tp.x, dy = n.y - tp.y
                        if dx * dx + dy * dy < 170 * 170 { g.move(to: tp); g.addLine(to: CGPoint(x: n.x, y: n.y)) }
                    }
                    ctx.stroke(g, with: .color(accent.opacity(0.55)), lineWidth: 0.9)
                    ctx.fill(Path(ellipseIn: CGRect(x: tp.x - 3, y: tp.y - 3, width: 6, height: 6)), with: .color(accent.opacity(0.9)))
                }
                // nodes: depth-scaled size, twinkle
                for n in ns {
                    let tw = 0.75 + 0.25 * sin(t * 1.4 + n.phase)
                    let r = 1.2 + n.z * 1.8
                    ctx.fill(Path(ellipseIn: CGRect(x: n.x - r * 2.4, y: n.y - r * 2.4, width: r * 4.8, height: r * 4.8)), with: .color(accent.opacity(0.07 * tw * n.z)))
                    ctx.fill(Path(ellipseIn: CGRect(x: n.x - r, y: n.y - r, width: r * 2, height: r * 2)), with: .color(accent.opacity((0.35 + 0.6 * n.z) * tw)))
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// Living grid: lines bend away from / toward your finger, tap sends a ripple through it,
/// intersections glow near the touch, 
struct GridBackground: View {
    var accent: Color = Theme.accent
    var density: Double = 1
    var speed: Double = 1
    var touch: ParticleTouchMode = .grab
    var cycle: Bool = false

    var body: some View {
        BGTimeline(fps: 30) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let accent = cycle ? hueShifted(self.accent, by: t / 60) : self.accent
                let now = Date.timeIntervalSinceReferenceDate
                let step = Swift.min(Swift.max(CGFloat(40 / density), 22), 64)
                let cols = Int(size.width / step) + 2, rows = Int(size.height / step) + 2
                let tp = touch == .off ? nil : ParticleTouch.point
                let pulse = touch == .off ? nil : ParticleTouch.pulse

                var pts = [CGPoint](repeating: .zero, count: cols * rows)
                var heat = [Double](repeating: 0, count: cols * rows)
                for r in 0..<rows {
                    for c in 0..<cols {
                        var x = CGFloat(c) * step, y = CGFloat(r) * step
                        var h = 0.0
                        // ambient shimmer
                        x += CGFloat(sin(t * 0.6 * speed + Double(y) / 90) * 1.6)
                        y += CGFloat(cos(t * 0.5 * speed + Double(x) / 110) * 1.6)
                        // finger
                        if let tp {
                            let dx = x - tp.x, dy = y - tp.y
                            let d = sqrt(dx * dx + dy * dy)
                            let f = exp(-Double(d * d) / (110 * 110))
                            if d > 0.5 {
                                switch touch {
                                case .repulse: x += dx / d * CGFloat(f) * 26; y += dy / d * CGFloat(f) * 26
                                case .attract: x -= dx / d * CGFloat(f) * 22; y -= dy / d * CGFloat(f) * 22
                                case .grab:    x -= dx / d * CGFloat(f) * 10; y -= dy / d * CGFloat(f) * 10
                                case .off: break
                                }
                            }
                            h += f
                        }
                        // tap ripple
                        if let pulse {
                            let age = now - pulse.t
                            if age >= 0 && age < 1.8 {
                                let dx = x - pulse.p.x, dy = y - pulse.p.y
                                let d = Swift.max(sqrt(dx * dx + dy * dy), 1)
                                let ring = Double(d) - age * 340
                                let w = exp(-(ring * ring) / (46 * 46)) * (1 - age / 1.8)
                                x += dx / d * CGFloat(w) * 15; y += dy / d * CGFloat(w) * 15
                                h += w * 0.9
                            }
                        }
                        pts[r * cols + c] = CGPoint(x: x, y: y)
                        heat[r * cols + c] = h
                    }
                }
                var base = Path(), mid = Path(), hot = Path()
                func seg(_ i: Int, _ j: Int) {
                    let h = (heat[i] + heat[j]) / 2
                    if h > 0.45 { hot.move(to: pts[i]); hot.addLine(to: pts[j]) }
                    else if h > 0.14 { mid.move(to: pts[i]); mid.addLine(to: pts[j]) }
                    else { base.move(to: pts[i]); base.addLine(to: pts[j]) }
                }
                for r in 0..<rows {
                    for c in 0..<cols {
                        let i = r * cols + c
                        if c + 1 < cols { seg(i, i + 1) }
                        if r + 1 < rows { seg(i, i + cols) }
                    }
                }
                ctx.stroke(base, with: .color(accent.opacity(0.08)), lineWidth: 0.5)
                ctx.stroke(mid, with: .color(accent.opacity(0.22)), lineWidth: 0.7)
                ctx.stroke(hot, with: .color(accent.opacity(0.55)), lineWidth: 0.9)
                for i in 0..<pts.count where heat[i] > 0.25 {
                    let r: CGFloat = 1 + CGFloat(Swift.min(heat[i], 1)) * 1.8
                    ctx.fill(Path(ellipseIn: CGRect(x: pts[i].x - r, y: pts[i].y - r, width: r * 2, height: r * 2)),
                             with: .color(accent.opacity(Swift.min(heat[i], 1) * 0.9)))
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// Picks the configured background overlay.
struct ThemeBackgroundLayer: View {
    @ObservedObject private var theme = AppTheme.shared
    var body: some View {
        switch theme.background {
        case .particles: ParticleBackground(accent: theme.accent, density: theme.particleDensity, speed: theme.particleSpeed, touch: theme.particleTouch, cycle: theme.cycleMode == .background)
        case .grid:      GridBackground(accent: theme.accent, density: theme.particleDensity, speed: theme.particleSpeed, touch: theme.particleTouch, cycle: theme.cycleMode == .background)
        case .none:      EmptyView()
        }
    }
}

// MARK: - Touch probe (non-blocking)

/// Watches touches app-wide through a passive recognizer on the window. It never cancels, delays or
/// intercepts touches, so every button, scroll view and sheet keeps working normally.
struct TouchProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeView { ProbeView() }
    func updateUIView(_ uiView: ProbeView, context: Context) {}

    final class ProbeView: UIView, UIGestureRecognizerDelegate {
        private var installedOn: UIWindow?
        private var start: CGPoint = .zero

        override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false; backgroundColor = .clear }
        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let w = window, installedOn !== w else { return }
            installedOn = w
            let g = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
            g.minimumPressDuration = 0
            g.allowableMovement = .greatestFiniteMagnitude
            g.cancelsTouchesInView = false
            g.delaysTouchesBegan = false
            g.delaysTouchesEnded = false
            g.delegate = self
            w.addGestureRecognizer(g)
        }

        @objc private func handle(_ g: UILongPressGestureRecognizer) {
            let p = g.location(in: nil)
            switch g.state {
            case .began: start = p; ParticleTouch.point = p
            case .changed: ParticleTouch.point = p
            case .ended, .cancelled, .failed:
                ParticleTouch.point = nil
                if g.state == .ended, abs(p.x - start.x) < 10, abs(p.y - start.y) < 10 {
                    ParticleTouch.pulse = (p, Date.timeIntervalSinceReferenceDate)
                }
            default: break
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRequireFailureOf o: UIGestureRecognizer) -> Bool { false }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy o: UIGestureRecognizer) -> Bool { false }
    }
}
