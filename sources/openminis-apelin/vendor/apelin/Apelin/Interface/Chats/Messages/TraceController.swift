import UIKit

/// The trace behind a summary, in a sheet; the conversation shows one
/// summary. Each step in order — a thought, a call, an approval — is a row,
/// its kind over a line of its detail (`TraceStep`), and a row with more
/// opens that step whole (`TraceStepController`). It follows the run:
/// steps are added and rows reconfigured in place, so the reader's scroll
/// and open page stay, and the open page shows its step as it grows.
final class TraceController: TableController {
    let messageID: UUID
    private var message: ChatMessage
    /// Each row as last shown, with the step it was made from: a step that
    /// did not change is not read again, so a call's arguments — a whole
    /// file, say — are decoded once, not on every update of the run.
    private var shown: [UUID: (step: ChatMessage, row: TraceStep)] = [:]
    private static let cellIdentifier = "Step"

    private lazy var dataSource = TableDataSource<Int, UUID, TraceStep>(
        tableView: tableView,
        identifier: \.id,
    ) { table, indexPath, row in
        Self.cell(in: table, at: indexPath, row: row)
    }

    init(message: ChatMessage) {
        self.message = message
        messageID = message.id
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(message:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Trace")
        navigationItem.backButtonDisplayMode = .minimal
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellIdentifier)
        show(message)
    }

    func show(_ message: ChatMessage) {
        self.message = message
        guard isViewLoaded else { return }
        var shown: [UUID: (step: ChatMessage, row: TraceStep)] = [:]
        let rows = TraceStep.messages(of: message).map { step in
            let row = if let known = self.shown[step.id], known.step == step {
                known.row
            } else {
                TraceStep(step)
            }
            shown[step.id] = (step, row)
            return row
        }
        self.shown = shown
        dataSource.update([(0, rows)], reconfigure: true)
        for case let page as TraceStepController in navigationController?.viewControllers ?? [] {
            if let step = shown[page.stepID]?.step {
                page.show(step)
            }
        }
    }

    private static func cell(in table: UITableView, at indexPath: IndexPath, row: TraceStep) -> UITableViewCell {
        let cell = table.dequeueReusableCell(withIdentifier: cellIdentifier, for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        content.text = row.title
        content.textProperties.numberOfLines = 1
        content.secondaryText = row.subtitle.isEmpty ? nil : row.subtitle
        content.secondaryTextProperties.numberOfLines = 1
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = row.hasDetail ? .disclosureIndicator : .none
        cell.selectionStyle = row.hasDetail ? .default : .none
        return cell
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        dataSource.value(at: indexPath)?.hasDetail == true
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath), row.hasDetail,
              let step = shown[row.id]?.step
        else { return }
        navigationController?.pushViewController(TraceStepController(step: step, title: row.title), animated: true)
    }
}
