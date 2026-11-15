import UIKit

/// Build-generated notices, including the components inside binary packages.
private struct LicenseEntry: Decodable, Equatable {
    let name: String
    let version: String?
    let license: String
    let url: String
    let text: String

    var summary: String {
        switch license {
        case "MIT": String(localized: "MIT License")
        case "Apache-2.0": String(localized: "Apache 2.0")
        default: license
        }
    }
}

/// Settings ▸ About ▸ Licenses, read from the `Licenses.json` the Collect
/// Licenses build phase writes.
final class LicensesViewController: TableController {
    private var entries: [LicenseEntry] = []

    private lazy var dataSource = TableDataSource<Int, String, LicenseEntry>(
        tableView: tableView,
        identifier: { $0.name + "\u{1f}" + $0.url + "\u{1f}" + $0.license },
    ) { [weak self] table, _, entry in
        self?.cell(in: table, entry: entry)
    }

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Open Source Licenses")
        navigationItem.backButtonDisplayMode = .minimal
        if let url = Bundle.main.url(forResource: "Licenses", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([LicenseEntry].self, from: data)
        {
            entries = decoded
        }
        dataSource.update([(0, entries)])
        if entries.isEmpty {
            let label = UILabel()
            label.text = String(localized: "No license information is available. Reinstall Apelin to restore it.")
            label.font = .preferredFont(forTextStyle: .body)
            label.textColor = .secondaryLabel
            label.numberOfLines = 0
            label.textAlignment = .center
            label.adjustsFontForContentSizeCategory = true
            tableView.backgroundView = label
        }
    }

    private func cell(in tableView: UITableView, entry: LicenseEntry) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "license")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "license")
        var content = UIListContentConfiguration.stackedValueCell()
        content.text = entry.name
        content.secondaryText = entry.summary
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let entry = dataSource.value(at: indexPath) else { return }
        navigationController?.pushViewController(
            LicenseTextViewController(entry: entry),
            animated: true,
        )
    }
}

/// Selectable, wrapping full text; links use UITextView's native interaction.
private final class LicenseTextViewController: UIViewController {
    private let entry: LicenseEntry

    init(entry: LicenseEntry) {
        self.entry = entry
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = entry.name
        view.backgroundColor = .systemGroupedBackground
        let footnote = UIFont.preferredFont(forTextStyle: .footnote)
        let text = NSMutableAttributedString(string: entry.name + "\n", attributes: [
            .font: UIFont.preferredFont(forTextStyle: .title2), .foregroundColor: UIColor.label,
        ])
        text.append(NSAttributedString(string: entry.summary + "\n\n", attributes: [
            .font: footnote, .foregroundColor: UIColor.secondaryLabel,
        ]))
        if let url = URL(string: entry.url), ["https", "http"].contains(url.scheme) {
            text.append(NSAttributedString(string: entry.url + "\n\n", attributes: [
                .font: footnote, .link: url,
            ]))
        }
        let monospaced = UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .monospacedSystemFont(ofSize: footnote.pointSize, weight: .regular),
        )
        text.append(NSAttributedString(string: entry.text, attributes: [
            .font: monospaced, .foregroundColor: UIColor.label,
        ]))

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
