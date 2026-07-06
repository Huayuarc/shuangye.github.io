import Foundation
import UIKit

@objc(CPUthermalCCModuleViewController)
public final class CPUthermalCCModuleViewController: CCUIMenuModuleViewController {
    @objc public var modeValues: [String] = ["lowPower", "fullPower"] {
        didSet { setupModeButtons() }
    }
    @objc public var modeTitles: [String] = ["低功耗", "防温控"] {
        didSet { setupModeButtons() }
    }
    @objc public var selectedIndex: Int = 1 {
        didSet { setupModeButtons() }
    }

    public override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        updateSelectedIndexFromCurrentMode()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        updateSelectedIndexFromCurrentMode()
    }

    public convenience init() {
        self.init(nibName: nil, bundle: nil)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "CPUthermal"

        let config = UIImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        if let glyphImage = UIImage(systemName: "thermometer.sun.fill", withConfiguration: config), responds(to: NSSelectorFromString("setGlyphImage:")) {
            setGlyphImage(glyphImage)
        }
        if responds(to: NSSelectorFromString("setSelectedGlyphColor:")) {
            setSelectedGlyphColor(.systemOrange)
        }
        useTrailingCheckmarkLayout = false
        useTallLayout = false
        hideGlyphInHeader = false
        if responds(to: NSSelectorFromString("setShouldProvideOwnPlatter:")) {
            setValue(false, forKey: "shouldProvideOwnPlatter")
        }

        setupView()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshState()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        centerMenuItemLabelsAfterLayout()
    }

    @objc public func refreshState() {
        updateSelectedIndexFromCurrentMode()
        setupModeButtons()
        if responds(to: NSSelectorFromString("setSelected:")) {
            setSelected(selectedIndex != 0)
        }
    }

    @objc public override func shouldBeginTransitionToExpandedContentModule() -> Bool {
        false
    }

    @objc public override func willTransition(toExpandedContentMode animated: Bool) {
        super.willTransition(toExpandedContentMode: animated)
        refreshState()
    }

    @objc public override func preferredExpandedContentHeight() -> CGFloat {
        214.0
    }

    @objc public override func preferredExpandedContentWidth() -> CGFloat {
        280.0
    }

    @objc public override func providesOwnPlatter() -> Bool {
        false
    }

    @objc public func _toggleModuleExpanded() -> Bool {
        false
    }

    private func currentPowerMode() -> String {
        CPUthermalShared.currentPowerMode()
    }

    private func savePowerMode(_ mode: String?) {
        CPUthermalShared.savePowerMode(mode)
        CPUthermalShared.restartThermalmonitordSoon()
    }

    private func setupView() {
        updateSelectedIndexFromCurrentMode()
        setupModeButtons()
        if responds(to: NSSelectorFromString("setSelected:")) {
            setSelected(selectedIndex != 0)
        }
    }

    private func setupModeButtons() {
        let currentMode = currentPowerMode()
        let isFullPower = currentMode == "fullPower"
        let itemCount = min(modeValues.count, modeTitles.count)
        var items = [CCUIMenuModuleItem]()

        for index in 0..<itemCount {
            let title = modeTitles[index]
            let isSelected = index == selectedIndex
            let displayTitle = menuTitle(for: title, selected: isSelected)
            let identifier = "cpu-item-\(index)"
            let item = CCUIMenuModuleItem(title: displayTitle, identifier: identifier) { [weak self] in
                self?.selectPowerMode(at: index)
            }
            item.isSelected = false
            if isSelected, item.responds(to: NSSelectorFromString("setSelectedGlyphColor:")) {
                item.setSelectedGlyphColor(isFullPower ? .systemOrange : .systemGreen)
            }
            items.append(item)
        }

        minimumMenuItems = itemCount
        visibleMenuItems = itemCount
        menuItems = items
        centerMenuItemLabelsAfterLayout()
    }

    private func menuTitle(for title: String, selected: Bool) -> String {
        selected ? title + "  ✓" : title
    }

    private func centerMenuItemLabelsAfterLayout() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.layoutIfNeeded()
            self.centerMenuItemLabels(in: self.view)
        }
    }

    private func isModeTitle(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        return modeTitles.contains { title in
            text == title || text == menuTitle(for: title, selected: true)
        }
    }

    private func centerMenuItemLabels(in view: UIView?) {
        guard let view else { return }
        let className = NSStringFromClass(type(of: view))
        if className.contains("MenuModuleItem") {
            if view.responds(to: NSSelectorFromString("setUseTrailingCheckmarkLayout:")) {
                view.setValue(false, forKey: "useTrailingCheckmarkLayout")
            }
            if view.responds(to: NSSelectorFromString("setUseTrailingInset:")) {
                view.setValue(false, forKey: "useTrailingInset")
            }
            if view.responds(to: NSSelectorFromString("setIndentation:")) {
                view.setValue(0.0, forKey: "indentation")
            }
            view.preservesSuperviewLayoutMargins = false
            view.layoutMargins = .zero

            var labels = [UILabel]()
            if view.responds(to: NSSelectorFromString("titleLabel")), let titleLabel = view.value(forKey: "titleLabel") as? UILabel {
                labels.append(titleLabel)
            }
            if view.responds(to: NSSelectorFromString("subtitleLabel")), let subtitleLabel = view.value(forKey: "subtitleLabel") as? UILabel, !labels.contains(where: { $0 === subtitleLabel }) {
                labels.append(subtitleLabel)
            }
            collectLabels(from: view, into: &labels)

            for label in labels where isModeTitle(label.text) {
                label.textAlignment = .center
                label.numberOfLines = 1
                label.translatesAutoresizingMaskIntoConstraints = true
                label.autoresizingMask = [.flexibleWidth, .flexibleLeftMargin, .flexibleRightMargin]

                let labelContainer = label.superview ?? view
                let targetWidth = view.bounds.width
                let frameInContainer = view.convert(view.bounds, to: labelContainer)
                var frame = label.frame
                frame.origin.x = frameInContainer.origin.x
                frame.size.width = targetWidth
                label.frame = frame
            }
        }

        for subview in view.subviews {
            centerMenuItemLabels(in: subview)
        }
    }

    private func collectLabels(from view: UIView, into labels: inout [UILabel]) {
        for subview in view.subviews {
            if let label = subview as? UILabel, !labels.contains(where: { $0 === label }) {
                labels.append(label)
            }
            collectLabels(from: subview, into: &labels)
        }
    }

    private func updateSelectedIndexFromCurrentMode() {
        let currentMode = currentPowerMode()
        selectedIndex = modeValues.firstIndex(of: currentMode) ?? 1
    }

    @objc public override func buttonTapped(_ arg: Any?, forEvent event: Any?) {
        togglePowerMode()
    }

    private func togglePowerMode() {
        updateSelectedIndexFromCurrentMode()
        let nextIndex = selectedIndex == 0 ? 1 : 0
        selectPowerMode(at: nextIndex, dismissAfterSelection: false)
    }

    @objc public func buttonModeTapped(_ sender: CCUIMenuModuleItem) {
        let index = menuItems.firstIndex { $0 === sender } ?? NSNotFound
        selectPowerMode(at: index)
    }

    private func selectPowerMode(at index: Int) {
        selectPowerMode(at: index, dismissAfterSelection: true)
    }

    private func selectPowerMode(at index: Int, dismissAfterSelection: Bool) {
        guard index != NSNotFound, index >= 0, index < modeValues.count else { return }
        selectedIndex = index
        savePowerMode(modeValues[index])
        setupModeButtons()
        if responds(to: NSSelectorFromString("setSelected:")) {
            setSelected(selectedIndex != 0)
        }
        guard dismissAfterSelection else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.dismiss(animated: true)
        }
    }
}
