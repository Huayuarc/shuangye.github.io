import UIKit

// The views the app lays out by hand work their frames out left to right.
// They pass them through here: left to right a frame comes back exactly as
// it went in, right to left (Arabic) it is mirrored across the span it was
// laid out in, so leading and trailing swap sides as the system's own
// views do.

extension CGRect {
    /// This rect mirrored across the vertical centre line of `span`.
    func mirrored(across span: CGRect) -> CGRect {
        var rect = self
        rect.origin.x = span.minX + span.maxX - maxX
        return rect
    }
}

extension UIView {
    /// Whether this view lays out right to left. Not SwifterSwift's
    /// `isRightToLeft`, which would make the name ambiguous across the
    /// target once anything imports it.
    var laysOutRightToLeft: Bool {
        effectiveUserInterfaceLayoutDirection == .rightToLeft
    }

    /// `frame`, worked out left to right across `span` (these bounds unless
    /// given), for one of this view's subviews in this view's direction.
    func directionalFrame(_ frame: CGRect, across span: CGRect? = nil) -> CGRect {
        laysOutRightToLeft ? frame.mirrored(across: span ?? bounds) : frame
    }

    /// Mirrors `subviews`, already laid out left to right, when this view
    /// lays out right to left. It moves their centres, so a scale on one
    /// stays where it was.
    func mirrorForLayoutDirection(_ subviews: [UIView]) {
        guard laysOutRightToLeft else { return }
        for subview in subviews {
            subview.center.x = bounds.minX + bounds.maxX - subview.center.x
        }
    }

    /// A horizontal distance worked out left to right, in this view's
    /// direction: as it is left to right, reversed right to left.
    func directionalOffset(_ dx: CGFloat) -> CGFloat {
        laysOutRightToLeft ? -dx : dx
    }
}
