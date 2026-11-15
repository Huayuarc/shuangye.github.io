import SnapKit
import Then
import UIKit

/// What a list shows while its first answer is on the way: the daemon may
/// not be up yet, and a miss is never an error (`AGENTS.md`).
final class LoadingView: UIView {
    init() {
        super.init(frame: .zero)
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        let label = UILabel().then {
            $0.text = String(localized: "Connecting…")
            $0.font = .preferredFont(forTextStyle: .body)
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = .secondaryLabel
        }
        let stack = UIStackView(arrangedSubviews: [spinner, label]).then {
            $0.axis = .vertical
            $0.alignment = .center
            $0.spacing = 12
        }
        addSubview(stack)
        stack.snp.makeConstraints { x in
            x.center.equalToSuperview()
        }
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityLabel = label.text
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }
}
