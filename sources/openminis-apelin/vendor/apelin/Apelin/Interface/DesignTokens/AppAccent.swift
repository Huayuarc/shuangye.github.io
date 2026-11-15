import UIKit

/// The app's accent. With Liquid Glass (iOS 26 and later) it is the
/// system's blue, left as UIKit gives it. Before it, the blue on flat bars
/// looked out of place (owner, 2026-10-22), so there the accent is the
/// text's own colour: black in the light, white in the dark. The window
/// takes it as its tint (`SceneDelegate`), so every view that follows the
/// tint follows it; what names a colour instead asks here.
enum AppAccent {
    /// Black and white: before iOS 26, or, to look at it on a later system,
    /// with `debug.monochromeAccent` set (`defaults write wiki.qaq.apelin
    /// debug.monochromeAccent -bool true` as mobile, then a relaunch).
    static let isMonochrome: Bool = if #available(iOS 26, *) {
        UserDefaults.standard.bool(forKey: "debug.monochromeAccent")
    } else {
        true
    }

    /// The window's tint; nil leaves the system's.
    static var windowTint: UIColor? {
        isMonochrome ? .label : nil
    }

    /// `glass` where the accent is the system's, black or white otherwise.
    static func color(glass: UIColor) -> UIColor {
        isMonochrome ? .label : glass
    }

    /// Text and symbols on a fill of the accent: `glass` on the system's,
    /// and on black or white whichever of the two the fill is not.
    static func foreground(glass: UIColor) -> UIColor {
        isMonochrome ? UIColor(light: .white, dark: .black) : glass
    }
}
