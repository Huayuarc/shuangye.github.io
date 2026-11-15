import SnapKit
import SPIndicator
import Then
import UIKit

/// A device flow's code: large and monospaced on a rounded plate; a tap
/// copies it.
final class DeviceCodeView: UIControl {
    init(code: String) {
        super.init(frame: .zero)
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        let label = UILabel().then {
            $0.attributedText = NSAttributedString(string: code, attributes: [
                .kern: 4,
                .font: UIFont.monospacedSystemFont(ofSize: 34, weight: .semibold),
            ])
            $0.adjustsFontSizeToFitWidth = true
            $0.minimumScaleFactor = 0.5
            $0.textAlignment = .center
            $0.isUserInteractionEnabled = false
        }
        addSubview(label)
        label.snp.makeConstraints {
            $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 24, left: 20, bottom: 24, right: 20))
        }
        addAction(UIAction { _ in
            UIPasteboard.general.string = code
            SPIndicator.present(title: String(localized: "Copied"), preset: .done, haptic: .success)
        }, for: .touchUpInside)
        // one stop: what it is, the code spelled out, and that it copies
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = String(localized: "Code")
        accessibilityValue = code.map(String.init).joined(separator: " ")
        accessibilityHint = String(localized: "Copies the code.")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(code:)")
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }
}
