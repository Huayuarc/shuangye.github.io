import SnapKit
import UIKit

/// The app's icon at 88 points, drawn as macOS draws one: a rounded square
/// over a soft shadow. Drawn from `AppIconMark`, never looked up as
/// `AppIcon` (`AGENTS.md` ▸ The app icon is never looked up by name).
final class AppIconView: UIView {
    static let side: CGFloat = 88
    /// macOS rounds an icon's corners by this share of its side.
    private static let cornerRadius = side * 0.2237

    private let image = UIImageView(image: UIImage(named: "AppIconMark"))

    init() {
        super.init(frame: .zero)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.06
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 1)
        image.contentMode = .scaleAspectFill
        image.layer.cornerRadius = Self.cornerRadius
        image.layer.cornerCurve = .continuous
        image.clipsToBounds = true
        addSubview(image)
        image.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }
        snp.makeConstraints { x in
            x.size.equalTo(Self.side)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // the shadow follows the rounded square, not the clipped image
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: Self.cornerRadius).cgPath
    }
}
