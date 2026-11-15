// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import UIKit

/// Over the composer's card, where a drop lands. It takes a drag and
/// nothing else: a touch, a pointer or VoiceOver passes through to the
/// bands under it.
class ComposerDropView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard bounds.contains(point) else {
            return super.hitTest(point, with: event)
        }
        return if let event,
                  NSStringFromClass(type(of: event)) == "UIDragEvent",
                  bounds.contains(point)
        {
            self
        } else {
            nil
        }
    }
}
