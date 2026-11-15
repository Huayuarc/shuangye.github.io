import SnapKit
import UIKit

/// The detail column while nothing is picked: the app's icon in the middle
/// of the pane.
final class NothingSelectedController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .pageBackground

        let icon = AppIconView()
        // the app, named once; the picture says nothing more
        icon.isAccessibilityElement = true
        icon.accessibilityLabel = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        icon.accessibilityTraits = .image
        view.addSubview(icon)
        icon.snp.makeConstraints { x in
            x.center.equalTo(view.safeAreaLayoutGuide)
        }
    }
}
