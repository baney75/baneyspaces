import SwiftUI

/// Offers its one child at most `max` points of width and takes the child's own size. Short
/// text hugs itself; long text truncates at the cap. A plain `.frame(maxWidth:)` does neither
/// in the dock: under the panel's `fixedSize` no width is offered, so text drew past the frame,
/// and when a width is offered the frame stretches to the cap (review of #95, 2026-10-31).
public struct WidthCap: Layout {
    public let max: CGFloat

    public init(max: CGFloat) { self.max = max }

    private func capped(_ width: CGFloat?) -> CGFloat { Swift.min(width ?? max, max) }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        return child.sizeThatFits(ProposedViewSize(width: capped(proposal.width), height: proposal.height))
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                              proposal: ProposedViewSize(width: capped(bounds.width), height: bounds.height))
    }
}
