// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import UIKit

extension UIView {
    /// Runs `execute` on FlowDown's spring and lays the whole window out
    /// inside the same block, so whatever the change moves goes with it: a
    /// band that grows moves the page above it too, the list included.
    /// Inside another animation the change joins it, and that block's one
    /// layout places everything: laying out here as well would show a
    /// half-made state the outer block then pulls back.
    func doWithAnimation(
        duration: TimeInterval = 0.5,
        _ execute: @escaping () -> Void,
        completion: @escaping () -> Void = {},
    ) {
        let root = window ?? self
        let nested = UIView.inheritedAnimationDuration > 0
        if !nested {
            root.layoutIfNeeded()
        }
        UIView.animate(
            withDuration: duration,
            delay: 0,
            usingSpringWithDamping: 0.9,
            initialSpringVelocity: 1.0,
            // `allowUserInteraction` is what keeps a continuous gesture alive:
            // by default UIKit ignores input aimed at a hierarchy that is being
            // animated, so a drag that animates the layout on every sample gets
            // its own remaining events swallowed and freezes until the animation
            // ends. `beginFromCurrentState` then lets each new sample retarget
            // the animation already in flight, instead of discarding what is on
            // screen and restarting from a target nothing ever displayed.
            options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction],
        ) {
            execute()
            if !nested {
                root.layoutIfNeeded()
            }
        } completion: { _ in
            completion()
        }
    }

    /// Shows or hides this view where another takes its place: it leaves at
    /// once and arrives only once the other has gone, so two views sharing
    /// a spot never show through each other while the layout springs.
    func handOver(visible: Bool) {
        let alpha: CGFloat = visible ? 1 : 0
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else {
            self.alpha = alpha
            return
        }
        // Called from inside the layout's spring, which a nested animation
        // would otherwise follow, stretching the hand-over back into a
        // cross-fade.
        UIView.animate(
            withDuration: visible ? 0.2 : 0.1,
            delay: visible ? 0.15 : 0,
            options: [
                .curveEaseInOut, .beginFromCurrentState, .allowUserInteraction,
                .overrideInheritedDuration, .overrideInheritedCurve,
            ],
        ) {
            self.alpha = alpha
        }
    }

    /// A tap's answer: a light impact and a small squeeze that springs back.
    func puddingAnimate() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        transform = CGAffineTransform(scaleX: 0.975, y: 0.975)
        doWithAnimation { self.transform = .identity }
    }
}
