import AppKit
import ClaudeBubbleCore
import Combine
import SwiftUI

/// What the toast panel draws.
final class ToastModel: ObservableObject {
    @Published var placements: [ToastPlacement] = []
    /// Toasts sit above the orb (no room below): newest nearest the orb, stack growing upward.
    @Published var flipped = false
    @Published var palette: OrbPalette = .agentsView
    /// Toasts hug the orb's side of the panel when the stack sits beside it.
    @Published var align: ToastLayout.Align = .center
}

extension ToastKind {
    func color(in palette: OrbPalette) -> Color {
        let c: SIMD3<Float> = switch self {
        case .started, .resumed: palette[.working].swatch
        case .needs, .review, .usageLow: palette[.needs].swatch
        case .error, .usageCritical: palette[.error].swatch
        case .finished, .usageRefreshed, .catchUp, .update: palette[.idle].swatch
        case .allDone: palette.done.swatch
        }
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }
}

struct ToastStackView: View {
    @ObservedObject var model: ToastModel
    static let pillHeight: CGFloat = 30

    private var horizontal: Alignment {
        switch model.align {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private var anchor: UnitPoint {
        switch model.align {
        case .leading: model.flipped ? .bottomLeading : .topLeading
        case .center: model.flipped ? .bottom : .top
        case .trailing: model.flipped ? .bottomTrailing : .topTrailing
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                ForEach(model.placements, id: \.id) { t in
                    let y = model.flipped ? geo.size.height - t.top - Self.pillHeight : t.top
                    ToastPill(toast: t, color: t.kind.color(in: model.palette), alignment: horizontal)
                        .scaleEffect(t.scale, anchor: anchor)
                        .blur(radius: t.blur)
                        .opacity(t.opacity)
                        .offset(y: t.showing ? 0 : -8)
                        .frame(width: geo.size.width, alignment: horizontal)
                        .position(x: geo.size.width / 2, y: y + Self.pillHeight / 2)
                        .zIndex(Double(t.z))
                        .animation(.spring(response: 0.55, dampingFraction: 0.72), value: t.top)
                        .animation(.spring(response: 0.55, dampingFraction: 0.72), value: t.scale)
                        .animation(.easeOut(duration: 0.45), value: t.opacity)
                        .animation(.easeOut(duration: 0.45), value: t.blur)
                        .animation(.easeOut(duration: 0.45), value: t.showing)
                }
            }
        }
    }
}

/// One toast pill, with the design's decode entrance (scrambled glyphs, colour fringes, scanlines, flash, reveal).
struct ToastPill: View {
    let toast: ToastPlacement
    let color: Color
    var alignment: Alignment = .center

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: CACurrentMediaTime() - toast.born > 1)) { _ in
            DecodingPill(toast: toast, color: color, frame: DecodeFrame(toast: toast, now: CACurrentMediaTime()), alignment: alignment)
        }
    }
}

/// The decode's state at one instant.
struct DecodeFrame {
    let progress: Double
    let tick: Int
    let glitch: Bool
    let fringe: CGFloat
    let reveal: CGFloat
    let name: String
    let text: String

    init(toast: ToastPlacement, now: Double) {
        let age = now - toast.born
        let p = min(1, max(0, age / ToastDecode.duration))
        let ip = 1 - p
        let tick = Int(now / 0.045)
        let glitch = p < 0.55 && ToastDecode.text("x", progress: 0, seed: toast.id, tick: tick) == "▓"
        progress = p
        self.tick = tick
        self.glitch = glitch
        fringe = CGFloat(ip * ip * 3.2) + (glitch ? 1.5 : 0)
        let r = min(1, age / 0.8)
        reveal = CGFloat(1 - pow(1 - r, 3))
        name = ToastDecode.text(toast.name, progress: p, seed: toast.id, tick: tick)
        text = ToastDecode.text(toast.text, progress: p, seed: toast.id, tick: tick, offset: 50)
    }
}

struct DecodingPill: View {
    let toast: ToastPlacement
    let color: Color
    let frame: DecodeFrame
    var alignment: Alignment = .center

    private var inverse: Double { 1 - frame.progress }
    private var dotOpacity: Double { frame.progress < 0.4 && frame.tick % 2 == 0 ? 0.25 : 1 }
    private var jitter: CGFloat { frame.glitch ? CGFloat(frame.tick % 5 - 2) * 1.2 : 0 }

    var body: some View {
        content
            .overlay(Scanlines().opacity(max(0, inverse * 1.1 - 0.1)).clipShape(Capsule()))
            .overlay(Capsule().fill(color).blendMode(.screen).opacity(pow(inverse, 4) * 0.35))
            .overlay(Sweep(progress: frame.progress).clipShape(Capsule()))
            .offset(x: jitter)
            .mask { RevealMask(reveal: frame.reveal) }
            .frame(maxWidth: 280, alignment: alignment)
    }

    private var content: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 6, height: 6).shadow(color: color, radius: 3).opacity(dotOpacity)
            FringedText(text: frame.name, size: 12, weight: .medium, color: .white, amount: frame.fringe, strength: inverse)
                .lineLimit(1).truncationMode(.tail)
            FringedText(text: frame.text, size: 12, weight: .regular, color: color, amount: frame.fringe, strength: inverse)
                .fixedSize()
        }
        .padding(.leading, 11)
        .padding(.trailing, 14)
        .frame(height: ToastStackView.pillHeight)
        .background(Capsule().fill(Color(red: 22 / 255, green: 20 / 255, blue: 30 / 255).opacity(0.92)))
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}

/// Text with red and cyan copies either side: the decode's chromatic fringe.
private struct FringedText: View {
    let text: String
    let size: CGFloat
    let weight: Font.Weight
    let color: Color
    let amount: CGFloat
    let strength: Double

    var body: some View {
        let font = Font.system(size: size, weight: weight, design: .monospaced)
        Text(text).font(font).foregroundColor(color)
            .background(Text(text).font(font).foregroundColor(Color(red: 1, green: 0.24, blue: 0.43))
                .offset(x: amount).opacity(0.85 * strength))
            .background(Text(text).font(font).foregroundColor(Color(red: 0.24, green: 0.86, blue: 1))
                .offset(x: -amount).opacity(0.85 * strength))
    }
}

/// A light band sweeping across while the toast decodes.
private struct Sweep: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, .white.opacity(0.22), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width * 0.24)
                .offset(x: geo.size.width * CGFloat(progress * 1.4 - 0.32))
                .opacity(progress < 1 ? 1 : 0)
        }
    }
}

/// The reveal: an ellipse centred on the top edge, growing until it covers the whole pill (every corner),
/// then out of the way entirely.
private struct RevealMask: View {
    let reveal: CGFloat

    var body: some View {
        GeometryReader { geo in
            if reveal >= 1 {
                Rectangle()
            } else {
                Ellipse()
                    .frame(width: geo.size.width * 2.6 * reveal, height: geo.size.height * 3 * reveal)
                    .position(x: geo.size.width / 2, y: 0)
            }
        }
    }
}

private struct Scanlines: View {
    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 0
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.white.opacity(0.14)))
                y += 3
            }
        }
    }
}

/// Click-through floating panel for the toast stack, attached to the orb like the hover list.
final class ToastPanel: NSPanel {
    static let size = CGSize(width: 320, height: 230)
    weak var bubble: NSWindow?

    init(model: ToastModel) {
        super.init(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
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
        appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: ToastStackView(model: model))
        host.sizingOptions = []   // sized by hand
        contentView = host
    }

    override var canBecomeKey: Bool { false }

    override func orderOut(_ sender: Any?) {
        bubble?.removeChildWindow(self)
        super.orderOut(sender)
    }

    func show(at frame: CGRect) {
        if self.frame != frame { setFrame(frame, display: true) }
        if !isVisible { orderFrontRegardless() }
        if parent == nil { bubble?.addChildWindow(self, ordered: .above) }
    }
}
