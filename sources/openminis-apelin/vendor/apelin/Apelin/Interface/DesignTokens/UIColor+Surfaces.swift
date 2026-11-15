import UIKit

/// The grounds a screen is built on, lowest first: the iPad sidebar, then
/// the page beside it. Irisin's, so the two apps' columns match.
extension UIColor {
    /// The lowest ground in both modes: the iPad sidebar, with the detail
    /// column beside it (`.pageBackground`) a step brighter.
    static let panelBackground = UIColor(light: UIColor(hex: 0xF2F2F7), dark: .black)

    /// Page background, a step above `.panelBackground` in both modes: in
    /// the dark, black on a page of its own and `elevatedGround` in the iPad
    /// detail column (`RootInterfaceController` elevates it) and in a sheet.
    static let pageBackground = ground(light: UIColor(hex: 0xFAFAFA))

    /// A page's ground one level up in the dark, well below the system's
    /// `#1C1C1E`: just off the black sidebar.
    private static let elevatedGround = UIColor(hex: 0x111111)

    /// `light` in light mode; in the dark, black at the base level and
    /// `elevatedGround` above it.
    private static func ground(light: UIColor) -> UIColor {
        UIColor { trait in
            guard trait.userInterfaceStyle == .dark else { return light.resolvedColor(with: trait) }
            return trait.userInterfaceLevel == .elevated ? elevatedGround : .black
        }
    }
}
