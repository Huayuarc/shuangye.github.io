import ApelinProtocol
import UIKit

/// One skill from Settings ▸ Skills: its description, the instructions the
/// agent reads with `apelin_skill_read`, and the other files its folder serves.
/// Selectable, wrapping text, as a license's page is.
final class SkillTextController: UIViewController {
    private let skill: AgentSkill

    init(skill: AgentSkill) {
        self.skill = skill
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = skill.name
        view.backgroundColor = .systemGroupedBackground
        let body = UIFont.preferredFont(forTextStyle: .body)
        let footnote = UIFont.preferredFont(forTextStyle: .footnote)
        let monospaced = UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .monospacedSystemFont(ofSize: footnote.pointSize, weight: .regular),
        )
        let text = NSMutableAttributedString(string: skill.description + "\n\n", attributes: [
            .font: body, .foregroundColor: UIColor.secondaryLabel,
        ])
        text.append(NSAttributedString(string: skill.body, attributes: [
            .font: monospaced, .foregroundColor: UIColor.label,
        ]))
        if !skill.files.isEmpty {
            text.append(NSAttributedString(
                string: "\n\n" + String(localized: "Files") + "\n",
                attributes: [.font: UIFont.preferredFont(forTextStyle: .headline), .foregroundColor: UIColor.label],
            ))
            text.append(NSAttributedString(string: skill.files.joined(separator: "\n"), attributes: [
                .font: monospaced, .foregroundColor: UIColor.secondaryLabel,
            ]))
        }

        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.attributedText = text
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        ])
    }
}
