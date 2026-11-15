import UIKit

extension UIViewController {
    /// Shows `path` selected in its folder in Fila, as Irisin does. Without
    /// Fila the open fails, and the sheet offers Fila's page in Irisin, which
    /// Apelin depends on, so it is there to install it from.
    func revealInFila(path: String) {
        var components = URLComponents()
        components.scheme = "fila"
        components.host = "reveal"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = components.url else { return }
        // canOpenURL would need the scheme listed in Info.plist; the open's
        // own answer says the same
        UIApplication.shared.open(url) { [weak self] opened in
            guard !opened else { return }
            self?.presentConfirmation(
                title: "Install Fila",
                message: "Open files and folders with Fila. Install it from the OwnGoal Studio repository in Irisin.",
                confirmTitle: "Open Irisin",
            ) {
                guard let irisin = URL(string: "irisin://package/wiki.qaq.fila") else { return }
                UIApplication.shared.open(irisin)
            }
        }
    }
}
