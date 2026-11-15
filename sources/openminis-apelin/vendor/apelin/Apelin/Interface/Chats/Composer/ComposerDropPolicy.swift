// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import Foundation
import UniformTypeIdentifiers

/// Which drops the composer takes, FlowDown's rule: items from another
/// app, each with a file to read and none a folder. Foundation alone, so
/// the harness checks it on the Mac.
enum ComposerDropPolicy {
    /// `fromThisApp` is a drag that started in Apelin; `inputCovered`, a
    /// request in place of the input, which the drop would land under.
    static func accepts(_ providers: [NSItemProvider], fromThisApp: Bool, inputCovered: Bool) -> Bool {
        guard !fromThisApp, !inputCovered else { return false }
        return providers.allSatisfy { provider in
            !provider.hasItemConformingToTypeIdentifier(UTType.folder.identifier)
                && provider.hasItemConformingToTypeIdentifier(UTType.item.identifier)
        }
    }
}
