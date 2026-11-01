import AppKit
import BaneySpacesCore
import QuartzCore
import SwiftUI

/// A transparent layer-hosting view over the overview, for the snapshot layers that carry the cards.
/// It takes no clicks. Its layer is flipped, so a card's place is its top-left offset, as in the layout.
final class OverviewOverlay: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let root = CALayer()
        root.isGeometryFlipped = true
        layer = root
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The overview's own panel content: the SwiftUI view with the overlay for snapshot layers above it.
final class OverviewContainer: NSView {
    let hosting: NSView
    let overlay = OverviewOverlay(frame: .zero)

    init(hosting: NSView) {
        self.hosting = hosting
        super.init(frame: .zero)
        hosting.autoresizingMask = [.width, .height]
        overlay.autoresizingMask = [.width, .height]
        addSubview(hosting)
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        hosting.frame = bounds
        overlay.frame = bounds
    }
}

/// How cards come and go (spec/overview.md, Motion). A snapshot layer moves, never the window itself:
/// each card is a Core Animation layer sprung from its window's real place into its tile (and back),
/// so the render server animates it and no layout pass runs per frame. A theme that never scales
/// or slides, or Reduce Motion, doesn't use it (`OverviewMotion.plan`). A new target mid-flight
/// continues from where each layer is on screen now.
final class OverviewMotionRunner {
    private var layers: [WindowID: CALayer] = [:]
    private var generation = 0

    /// Layers are in flight.
    var isMoving: Bool { !layers.isEmpty }

    // MARK: Coming in

    /// Cards spring from their windows into their tiles, or fade and scale in. `done` runs once they have settled
    /// (not when a later transition took over).
    func open(plan: OverviewMotion, model: ViewerModel, layout: OverviewLayout, container: OverviewContainer, done: @escaping () -> Void) {
        generation += 1
        let mine = generation
        let spec = Chrome.spec
        switch plan {
        case .travel:
            model.cardsHidden = true
            let spring = OverviewSpring.opening(spec: spec)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            var adds: [(layer: CALayer, from: (pos: CGPoint, scale: CGSize, opacity: Float))] = []
            for card in layout.cards {
                guard let entry = model.entry(card.id) else { continue }
                // A close still in flight hands over where each layer is on screen; else each starts at its window.
                let existing = layers[card.id]
                let layer = existing ?? makeLayer(card, entry: entry, model: model, in: container)
                var from: (pos: CGPoint, scale: CGSize, opacity: Float)
                if let existing {
                    from = Self.onScreen(existing)
                } else {
                    let start = entry.frame ?? card.frame
                    from = (CGPoint(x: start.midX, y: start.midY),
                            CGSize(width: Self.ratio(start.width, card.frame.width), height: Self.ratio(start.height, card.frame.height)), 0)
                }
                layer.removeAllAnimations()
                adds.append((layer, from))
                // Where it ends up; the animations below start from `from`.
                layer.position = CGPoint(x: card.frame.midX, y: card.frame.midY)
                layer.transform = CATransform3DIdentity
                layer.opacity = 1
            }
            CATransaction.commit()
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.generation == mine else { return }
                    self.finish(model: model)
                    done()
                }
            }
            for a in adds {
                let to = a.layer.position
                a.layer.add(Self.spring("position", from: NSValue(point: a.from.pos), to: NSValue(point: to), spring), forKey: "position")
                a.layer.add(Self.spring("transform.scale.x", from: a.from.scale.width, to: 1, spring), forKey: "scale.x")
                a.layer.add(Self.spring("transform.scale.y", from: a.from.scale.height, to: 1, spring), forKey: "scale.y")
                a.layer.add(Self.fade(from: a.from.opacity, to: 1, seconds: 0.1), forKey: "opacity")
            }
            CATransaction.commit()
            if adds.isEmpty { finish(model: model); done() }
        case .scale(let from):
            scaleContent(container.hosting, from: from, to: 1, spring: OverviewSpring.opening(spec: spec))
            done()
        case .fade, .none:
            done()
        }
    }

    // MARK: Going out

    /// Cards return to their windows (those of the workspace chosen) and the rest fade.
    func close(plan: OverviewMotion, model: ViewerModel, layout: OverviewLayout, toward chosen: Int?, container: OverviewContainer,
               done: @escaping () -> Void) {
        generation += 1
        let mine = generation
        let spec = Chrome.spec
        switch plan {
        case .travel:
            model.cardsHidden = true
            let spring = OverviewSpring.closing(spec: spec)
            var moves: [(layer: CALayer, from: (pos: CGPoint, scale: CGSize, opacity: Float), to: (pos: CGPoint, scale: CGSize, opacity: Float))] = []
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for tile in layout.tiles {
                for card in tile.cards {
                    guard let entry = model.entry(card.id) else { continue }
                    let layer = layers[card.id] ?? makeLayer(card, entry: entry, model: model, in: container)
                    let now = Self.onScreen(layer)
                    var to = (pos: CGPoint(x: card.frame.midX, y: card.frame.midY), scale: CGSize(width: 1, height: 1), opacity: Float(0))
                    if tile.n == chosen, let r = entry.frame {
                        to = (CGPoint(x: r.midX, y: r.midY), CGSize(width: Self.ratio(r.width, card.frame.width), height: Self.ratio(r.height, card.frame.height)), 1)
                    } else {
                        to.scale = CGSize(width: OverviewMotion.scaleFrom, height: OverviewMotion.scaleFrom)
                    }
                    layer.removeAllAnimations()
                    layer.position = to.pos
                    layer.transform = CATransform3DMakeScale(to.scale.width, to.scale.height, 1)
                    layer.opacity = to.opacity
                    moves.append((layer, now, to))
                }
            }
            CATransaction.commit()
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.generation == mine else { return }
                    self.finish(model: model)
                    done()
                }
            }
            for m in moves {
                m.layer.add(Self.spring("position", from: NSValue(point: m.from.pos), to: NSValue(point: m.to.pos), spring), forKey: "position")
                m.layer.add(Self.spring("transform.scale.x", from: m.from.scale.width, to: m.to.scale.width, spring), forKey: "scale.x")
                m.layer.add(Self.spring("transform.scale.y", from: m.from.scale.height, to: m.to.scale.height, spring), forKey: "scale.y")
                m.layer.add(Self.fade(from: m.from.opacity, to: m.to.opacity, seconds: spring.response / 2), forKey: "opacity")
            }
            CATransaction.commit()
            if moves.isEmpty { finish(model: model); done() }
        case .scale(let to):
            scaleContent(container.hosting, from: 1, to: to, spring: OverviewSpring.closing(spec: spec))
            done()
        case .fade, .none:
            done()
        }
    }

    /// Drops every layer and lets the cards themselves show.
    func finish(model: ViewerModel) {
        for layer in layers.values { layer.removeFromSuperlayer() }
        layers = [:]
        model.cardsHidden = false
    }

    /// Stops what is in flight where it is.
    func cancel(model: ViewerModel, container: OverviewContainer) {
        generation += 1
        container.hosting.layer?.removeAllAnimations()
        container.hosting.layer?.transform = CATransform3DIdentity
        finish(model: model)
    }

    // MARK: Layers

    /// A card as one layer at its final size: the preview if there is one, else the icon on the card's fill.
    private func makeLayer(_ card: OverviewLayout.Card, entry: Spaces.Entry, model: ViewerModel, in container: OverviewContainer) -> CALayer {
        let layer = CALayer()
        layer.bounds = CGRect(origin: .zero, size: card.frame.size)
        layer.position = CGPoint(x: card.frame.midX, y: card.frame.midY)
        layer.cornerRadius = Chrome.radius(.overviewCard)
        layer.masksToBounds = true
        layer.backgroundColor = NSColor(Chrome.cell(0.06)).cgColor
        layer.borderColor = NSColor(Chrome.edge(0.1)).cgColor
        layer.borderWidth = Chrome.width(.overviewCard)
        layer.contentsScale = container.window?.backingScaleFactor ?? 2
        if let image = model.previews[entry.id], let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            layer.contents = cg
            layer.contentsGravity = .resizeAspectFill
        } else if let icon = model.image(for: entry), let cg = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let side = min(max(min(card.frame.width, card.frame.height) * 0.45, 14), 72)
            let sub = CALayer()
            sub.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            sub.position = CGPoint(x: card.frame.width / 2, y: card.frame.height / 2)
            sub.contents = cg
            sub.contentsGravity = .resizeAspect
            layer.addSublayer(sub)
        }
        container.overlay.layer?.addSublayer(layer)
        layers[entry.id] = layer
        return layer
    }

    /// Where a layer is on screen right now: its presentation, so a new target starts from there.
    private static func onScreen(_ layer: CALayer) -> (pos: CGPoint, scale: CGSize, opacity: Float) {
        let p = layer.presentation() ?? layer
        let t = p.transform
        return (p.position, CGSize(width: t.m11, height: t.m22), p.opacity)
    }

    private static func ratio(_ a: CGFloat, _ b: CGFloat) -> CGFloat { b > 0 ? min(max(a / b, 0.05), 8) : 1 }

    private static func spring(_ keyPath: String, from: Any, to: Any, _ s: OverviewSpring) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = to
        a.mass = 1
        a.stiffness = s.stiffness
        a.damping = s.dampingCoefficient
        a.duration = a.settlingDuration
        return a
    }

    private static func fade(from: Float, to: Float, seconds: Double) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = to
        a.duration = max(seconds, 0.05)
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return a
    }

    /// The whole content scaled about its center by a spring: cards fade and scale from 0.96 when there are no previews.
    private func scaleContent(_ view: NSView, from: Double, to: Double, spring s: OverviewSpring) {
        guard let layer = view.layer else { return }
        func transform(_ k: Double) -> CATransform3D {
            // About the center, whatever the layer's anchor: t = (1 - k)(center - anchor).
            let size = layer.bounds.size, a = layer.anchorPoint
            let t = CGPoint(x: (1 - k) * (size.width / 2 - a.x * size.width), y: (1 - k) * (size.height / 2 - a.y * size.height))
            return CATransform3DConcat(CATransform3DMakeScale(k, k, 1), CATransform3DMakeTranslation(t.x, t.y, 0))
        }
        let anim = CASpringAnimation(keyPath: "transform")
        anim.fromValue = NSValue(caTransform3D: transform(from))
        anim.toValue = NSValue(caTransform3D: transform(to))
        anim.mass = 1
        anim.stiffness = s.stiffness
        anim.damping = s.dampingCoefficient
        anim.duration = anim.settlingDuration
        layer.transform = transform(to)
        layer.add(anim, forKey: "scale")
    }
}
