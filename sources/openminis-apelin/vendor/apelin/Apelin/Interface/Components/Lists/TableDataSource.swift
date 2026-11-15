import UIKit

/// Owns a table's snapshots and the values they render. Identifiers describe
/// rows, while equality describes whether their visible contents changed.
/// Keeping those separate preserves selection and swipe state across updates.
@MainActor
final class TableDataSource<Section: Hashable, Item: Hashable, Content: Equatable>:
    UITableViewDiffableDataSource<Section, Item>
{
    private let content: TableContent<Item, Content>
    private let identifier: (Content) -> Item
    private weak var table: FirstFillTableView?
    private let pacing = ListPacing()
    /// Counts the changes applied, so only the newest one trims the values
    /// back to its own rows.
    private var generation = 0
    private var sectionText: [Section: SectionText] = [:]
    var headerTitle: ((Section) -> String?)?
    var footerTitle: ((Section) -> String?)?
    var allowsEditing = false

    init(
        tableView: UITableView,
        identifier: @escaping (Content) -> Item,
        cellProvider: @escaping (UITableView, IndexPath, Content) -> UITableViewCell?,
    ) {
        let content = TableContent<Item, Content>()
        self.content = content
        self.identifier = identifier
        table = tableView as? FirstFillTableView
        assert(table != nil, "A TableDataSource's table is a FirstFillTableView")
        // UIKit aborts on a nil cell. A row with no value, which `update`
        // never leaves, is drawn empty instead.
        super.init(tableView: tableView) { table, indexPath, id in
            guard let value = content.values[id] else { return UITableViewCell() }
            return cellProvider(table, indexPath, value) ?? UITableViewCell()
        }
        defaultRowAnimation = .automatic
    }

    func value(at indexPath: IndexPath) -> Content? {
        itemIdentifier(for: indexPath).flatMap { content.values[$0] }
    }

    /// A load for this list starts now: rows it brings within
    /// `ListPacing.quietInterval`, and the first load's whenever they come,
    /// appear without animation.
    func beginLoad() {
        pacing.beginLoad()
    }

    /// The first fill waits for the table's width (`applyFirst`); updates
    /// until then replace it. Later changes animate only as `ListPacing`
    /// allows. Unchanged refreshes never disturb an open row action.
    func update(
        _ sections: [(Section, [Content])],
        reconfigure: Bool = false,
        changedItems: Set<Item> = [],
        animatingDifferences: Bool? = nil,
        completion: (() -> Void)? = nil,
    ) {
        let previous = snapshot()
        var next = NSDiffableDataSourceSnapshot<Section, Item>()
        var values: [Item: Content] = [:]
        var text: [Section: SectionText] = [:]
        for (section, rows) in sections {
            next.appendSections([section])
            next.appendItems(rows.map(identifier), toSection: section)
            text[section] = SectionText(header: headerTitle?(section), footer: footerTitle?(section))
            for row in rows {
                values[identifier(row)] = row
            }
        }
        guard let table, table.isFilled else {
            fillFirst(next, values: values, text: text, completion: completion)
            return
        }
        let oldItems = Set(previous.itemIdentifiers)
        let changedSections = next.sectionIdentifiers.filter { section in
            sectionText[section] != nil && sectionText[section] != text[section]
        }
        let changedSectionItems = Set(changedSections.flatMap { next.itemIdentifiers(inSection: $0) })
        let changed = next.itemIdentifiers.filter { id in
            oldItems.contains(id) && !changedSectionItems.contains(id)
                && (content.values[id] != values[id] || changedItems.contains(id))
        }
        let structureChanged = previous.sectionIdentifiers != next.sectionIdentifiers
            || previous.sectionIdentifiers.contains { section in
                next.sectionIdentifiers.contains(section)
                    && previous.itemIdentifiers(inSection: section) != next.itemIdentifiers(inSection: section)
            }
        guard structureChanged || !changed.isEmpty || !changedSections.isEmpty else {
            completion?()
            return
        }
        // UIKit can still ask for a row this change removes while it applies
        // the change: iOS 17, reloading a section whose header or footer
        // changed, asks for the cells of the rows the section had before.
        // Those rows' values stay readable until the change is in.
        content.values.merge(values) { _, new in new }
        generation += 1
        let generation = generation
        sectionText = text
        next.reloadSections(changedSections)
        if reconfigure {
            next.reconfigureItems(changed)
        } else {
            next.reloadItems(changed)
        }
        let animated = animatingDifferences ?? pacing.animatesChange(in: table)
        let selected = (table.indexPathsForSelectedRows ?? []).compactMap { itemIdentifier(for: $0) }
        applyChange(next, to: table, animated: animated) { [weak self, weak table] in
            if let self, self.generation == generation {
                content.values = values
            }
            if let self, let table {
                let current = (table.indexPathsForSelectedRows ?? []).compactMap { self.itemIdentifier(for: $0) }
                // UIKit drops selection when a row moves into a newly inserted
                // section. Restore it unless the user selected another row.
                if current.allSatisfy({ selected.contains($0) }) {
                    for id in selected {
                        if let path = indexPath(for: id) {
                            table.selectRow(at: path, animated: false, scrollPosition: .none)
                        }
                    }
                }
            }
            completion?()
        }
    }

    /// The rows the table opens to, put in once it has its width; the
    /// values change with them, so the rows shown and the values the cell
    /// provider reads never disagree.
    private func fillFirst(
        _ snapshot: NSDiffableDataSourceSnapshot<Section, Item>,
        values: [Item: Content],
        text: [Section: SectionText],
        completion: (() -> Void)?,
    ) {
        guard let table else {
            completion?()
            return
        }
        let content = content
        let fill = { [weak self] in
            guard let self else { return }
            content.values = values
            sectionText = text
            applySnapshotUsingReloadData(snapshot)
            pacing.begin()
        }
        table.firstFill.schedule(fill, completion: completion, in: table)
    }

    override func tableView(_: UITableView, canEditRowAt _: IndexPath) -> Bool {
        allowsEditing
    }

    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        sectionIdentifier(for: section).flatMap { sectionText[$0]?.header }
    }

    override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
        sectionIdentifier(for: section).flatMap { sectionText[$0]?.footer }
    }
}

private final class TableContent<Item: Hashable, Content> {
    var values: [Item: Content] = [:]
}

private struct SectionText: Equatable {
    let header: String?
    let footer: String?
}
