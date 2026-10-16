import AppKit
import ClaudeBubbleCore
import Combine
import SwiftUI

/// What one edge's light draws.
final class EdgeGlowModel: ObservableObject {
    @Published var strength: Double = 0
    /// The light's centre, measured along the panel from its start.
    @Published var centre: CGFloat = 0
    /// The edge's full length (sets the falloff).
    @Published var length: CGFloat = 1
    @Published var color: Color = .white
    @Published var state: BubbleState = .idle
}

/// A thin click-through strip along one screen edge, lit near the orb.
final class EdgeLightPanel: NSPanel {
    static let thickness: CGFloat = 16
    let edge: EdgeStrip.Edge
    let model = EdgeGlowModel()

    init(edge: EdgeStrip.Edge) {
        self.edge = edge
        super.init(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        contentView = NSHostingView(rootView: EdgeGlowView(model: model, edge: edge))
    }

    override var canBecomeKey: Bool { false }
}

/// Owns the four edge panels and places them each tick.
final class EdgeLightController {
    private var panels: [EdgeStrip.Edge: EdgeLightPanel] = [:]
    /// Strength shown per edge, eased so the light fades in and out while dragging.
    private var shown: [EdgeStrip.Edge: Double] = [:]

    /// `orb` is the orb panel; nil (orb hidden, popping out, or the light turned off) hides everything at once.
    /// `screen` is the visible frame the light runs along; `shared` are its edges that meet another display.
    func update(orb: NSWindow?, screen: CGRect?, shared: Set<EdgeStrip.Edge>, color: Color, state: BubbleState,
                opacity: Double, dt: Double) {
        guard let orb, let screen else {
            for (edge, panel) in panels where panel.isVisible { panel.orderOut(nil); shown[edge] = 0 }
            return
        }
        let centre = CGPoint(x: orb.frame.midX, y: orb.frame.midY)
        let strips = EdgeLight.strips(orbCentre: centre, orbRadius: orb.frame.width * 0.3, screen: screen, skipping: shared)
        let k = 1 - exp(-dt / 0.25)
        for edge in [EdgeStrip.Edge.left, .right, .bottom, .top] {
            let strip = strips.first { $0.edge == edge }
            let value = (shown[edge] ?? 0) + ((strip?.strength ?? 0) - (shown[edge] ?? 0)) * k
            shown[edge] = value
            guard value > 0.01 else {
                panels[edge]?.orderOut(nil)
                continue
            }
            let panel = panels[edge] ?? EdgeLightPanel(edge: edge)
            panels[edge] = panel
            guard let strip else {
                // Fading out after the orb moved away: stay where it was (even if the orb changed displays).
                if panel.isVisible { panel.model.strength = value * opacity } else { panel.orderOut(nil) }
                continue
            }
            let centre = strip.centre
            let length = edge == .left || edge == .right ? screen.height : screen.width
            let reach = length / 3 * 2
            let t = EdgeLightPanel.thickness
            let frame: CGRect
            switch edge {
            case .bottom: frame = CGRect(x: max(screen.minX, centre - reach), y: screen.minY, width: 0, height: t)
            case .top: frame = CGRect(x: max(screen.minX, centre - reach), y: screen.maxY - t, width: 0, height: t)
            case .left: frame = CGRect(x: screen.minX, y: max(screen.minY, centre - reach), width: t, height: 0)
            case .right: frame = CGRect(x: screen.maxX - t, y: max(screen.minY, centre - reach), width: t, height: 0)
            }
            var f = frame
            if edge == .bottom || edge == .top { f.size.width = min(screen.maxX, centre + reach) - f.minX }
            else { f.size.height = min(screen.maxY, centre + reach) - f.minY }
            guard f.width > 1, f.height > 1 else { panel.orderOut(nil); continue }
            if panel.frame != f { panel.setFrame(f, display: true) }
            let m = panel.model
            let along = edge == .bottom || edge == .top ? centre - f.minX : centre - f.minY
            if abs(m.centre - along) > 0.5 { m.centre = along }
            if m.length != length { m.length = length }
            if abs(m.strength - value * opacity) > 0.005 { m.strength = value * opacity }
            if m.state != state { m.state = state }
            if m.color != color { m.color = color }
            if !panel.isVisible {
                panel.orderFrontRegardless()
                panel.order(.below, relativeTo: orb.windowNumber)
            }
        }
    }
}

/// The light: a bright 2pt line on the edge with a soft glow fading inward, brightest at the orb and fading
/// along the edge. Its activity follows the orb's state.
struct EdgeGlowView: View {
    @ObservedObject var model: EdgeGlowModel
    let edge: EdgeStrip.Edge

    private var horizontal: Bool { edge == .bottom || edge == .top }

    var body: some View {
        // Working shimmers, needs breathes and error flickers, so those animate; idle is still.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: model.state == .idle)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let span = horizontal ? geo.size.width : geo.size.height
                let along = alongGradient(span: span, t: t)
                ZStack(alignment: inwardAlignment.opposite) {
                    // Soft glow fading inward from the edge.
                    Rectangle().fill(along)
                        .mask(LinearGradient(stops: [.init(color: .white, location: 0), .init(color: .white.opacity(0.35), location: 0.3),
                                                     .init(color: .clear, location: 1)],
                                             startPoint: inwardAlignment.opposite.unit, endPoint: inwardAlignment.unit))
                    // The line itself: the colour, with a hot near-white core like the orb's rim.
                    Rectangle().fill(along)
                        .frame(width: horizontal ? nil : 3, height: horizontal ? 3 : nil)
                    Rectangle().fill(along).blendMode(.plusLighter)
                        .frame(width: horizontal ? nil : 1.5, height: horizontal ? 1.5 : nil)
                        .overlay(Rectangle().fill(.white.opacity(0.35)).mask(Rectangle().fill(along)))
                }
            }
            .opacity(model.strength * level(t))
        }
    }

    /// Where the screen's inside is, from this edge.
    private var inwardAlignment: Alignment {
        switch edge {
        case .bottom: .top
        case .top: .bottom
        case .left: .trailing
        case .right: .leading
        }
    }

    private func level(_ t: Double) -> Double {
        switch model.state {
        case .working: 1
        case .needs: 0.45 + 0.55 * (0.5 + 0.5 * sin(t * 2 * .pi / 1.4))
        case .error: 0.8 * (Int(t * 14) % 7 == 0 ? 0.55 : 1)
        case .idle: 0.35
        }
    }

    private func alongGradient(span: CGFloat, t: Double) -> LinearGradient {
        // Enough stops to draw the shimmer's ~240pt waves smoothly across a whole edge.
        let n = max(24, Int(span / 16))
        let stops = (0...n).map { i -> Gradient.Stop in
            let pos = CGFloat(i) / CGFloat(n)
            let x = pos * span - model.centre
            var a = EdgeLight.falloff(x, length: model.length)
            // Working: a slow shimmer travelling outward from the orb.
            if model.state == .working { a *= 0.8 + 0.2 * sin(Double(abs(x)) / 38 - t * 3) }
            return Gradient.Stop(color: model.color.opacity(a), location: pos)
        }
        // Along a vertical edge `centre` is measured up from the panel's bottom, so the gradient runs bottom → top.
        return horizontal
            ? LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
            : LinearGradient(stops: stops, startPoint: .bottom, endPoint: .top)
    }
}

private extension Alignment {
    var opposite: Alignment {
        switch self {
        case .top: .bottom
        case .bottom: .top
        case .leading: .trailing
        default: .leading
        }
    }

    var unit: UnitPoint {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        default: .trailing
        }
    }
}
