import UIKit

extension UIListContentConfiguration {
    /// A name above a value or diagnostic that needs full body-sized text.
    static func stackedValueCell() -> Self {
        var content = valueCell()
        content.prefersSideBySideTextAndSecondaryText = false
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .body)
        content.secondaryTextProperties.color = .secondaryLabel
        return content
    }

    /// Supporting explanations sit one Dynamic Type style below the title.
    static func explanatoryCell() -> Self {
        var content = stackedValueCell()
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .callout)
        return content
    }
}

/// A table view controller whose table is a `FirstFillTableView`: every
/// page that is one table derives from this rather than from
/// `UITableViewController` itself.
class TableController: UITableViewController {
    private let tableStyle: UITableView.Style

    override init(style: UITableView.Style) {
        tableStyle = style
        super.init(style: style)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(style:)")
    }

    override func loadView() {
        let table = FirstFillTableView(frame: .zero, style: tableStyle)
        table.dataSource = self
        table.delegate = self
        tableView = table
    }
}
