import SnapKit
import UIKit

/// What a list shows in place of rows: a description, optionally titled, with a symbol above
/// it, or the symbol alone with the text left to VoiceOver. Fills whatever it is put in and centres the content, so it serves as
/// a table's `backgroundView` as is. Irisin's, with SF Symbols.
final class EmptyStateView: UIView {
    private let icon = UIImageView()
    private let caption = UILabel()

    init(symbolName: String, title: String? = nil, text: String, showsText: Bool = true) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        icon.image = UIImage(systemName: symbolName)
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 36, weight: .light)
        icon.tintColor = .tertiaryLabel
        icon.contentMode = .scaleAspectFit
        caption.font = .preferredFont(forTextStyle: .body)
        caption.adjustsFontForContentSizeCategory = true
        caption.textColor = .secondaryLabel
        caption.textAlignment = .center
        caption.numberOfLines = 0
        caption.text = text
        caption.isHidden = !showsText
        // Read the text once; the symbol adds no separate information.
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityLabel = [title, text].compactMap(\.self).joined(separator: ". ")
        let stack = UIStackView(arrangedSubviews: [icon])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        if let title {
            let heading = UILabel()
            heading.text = title
            heading.font = .preferredFont(forTextStyle: .headline)
            heading.textColor = .label
            heading.textAlignment = .center
            heading.numberOfLines = 1
            heading.adjustsFontForContentSizeCategory = true
            heading.isHidden = !showsText
            stack.addArrangedSubview(heading)
            stack.setCustomSpacing(8, after: heading)
        }
        stack.addArrangedSubview(caption)
        addSubview(stack)
        stack.snp.makeConstraints { x in
            x.center.equalToSuperview()
            x.width.lessThanOrEqualToSuperview().inset(32)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(symbolName:text:showsText:)")
    }
}
