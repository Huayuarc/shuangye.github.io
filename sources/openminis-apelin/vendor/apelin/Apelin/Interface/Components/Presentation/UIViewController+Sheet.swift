import Then
import UIKit

extension UIViewController {
    /// Every sheet this app presents, sized here and nowhere else, so one
    /// replacing another does not step: Xrash's. The *window's* width class
    /// decides, not the presenter's: a screen inside a split view's primary
    /// column is compact on an iPad whose window is not, and a sheet sized
    /// for that came out twice as wide as the one beside it.
    ///
    /// A sheet presented from inside another sheet takes no size at all.
    /// UIKit does not hold a nested form sheet to its preferred size: the
    /// card jumps on presentation and again on every push, so it keeps the
    /// system's own form sheet size instead.
    ///
    /// What is presented is a `SheetNavigationController`, which holds the
    /// size it opens at. A stock navigation controller adds its bar's height
    /// on every read, and the sheet followed the bar on a push that changed it.
    func presentAsFormSheet(
        _ viewController: SheetNavigationController,
        size: CGSize = CGSize(width: 555, height: 555),
        usesDetents: Bool = true,
    ) {
        viewController.modalPresentationStyle = .formSheet
        let window = viewIfLoaded?.window?.traitCollection ?? traitCollection
        if window.horizontalSizeClass == .compact, usesDetents {
            viewController.sheetPresentationController?.do {
                $0.detents = [.large()]
                $0.prefersGrabberVisible = true
                $0.prefersScrollingExpandsWhenScrolledToEdge = true
                $0.prefersEdgeAttachedInCompactHeight = true
                $0.widthFollowsPreferredContentSizeWhenEdgeAttached = true
            }
        } else if presentingViewController == nil {
            // Fila's and Irisin's card. Set on what is presented — the
            // navigation controller — and only here: a page that sized itself
            // would resize the sheet on every push and pop. A presenter that
            // is itself presented is a sheet, and this one would be nested.
            viewController.holdPreferredContentSize(size)
        }
        present(viewController, animated: true)
    }

    /// `page` as a form sheet, closed by the cross at the leading end of its
    /// bar; with `deeper`, opened at that page, already pushed on `page`.
    func presentPageAsFormSheet(_ page: UIViewController, openedAt deeper: UIViewController? = nil) {
        let navigation = SheetNavigationController(rootViewController: page)
        page.navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "xmark"),
            primaryAction: UIAction { [weak navigation] _ in navigation?.dismiss(animated: true) },
        ).then { $0.accessibilityLabel = String(localized: "Close") }
        if let deeper {
            navigation.pushViewController(deeper, animated: false)
        }
        presentAsFormSheet(navigation)
    }
}
