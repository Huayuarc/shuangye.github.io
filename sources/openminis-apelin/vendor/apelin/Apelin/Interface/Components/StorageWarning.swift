import ApelinCore
import UIKit

/// Says once that conversations are not being saved, while they go on in
/// memory: when a save fails, or the device is nearly out of space at launch
/// or on coming back. Not again until a save gets through, so a full disk
/// is one notice rather than one for every streamed event.
@MainActor
enum StorageWarning {
    /// Below this, a save may fail at any moment.
    static let lowSpaceBytes: Int64 = 512 * 1024 * 1024

    private static var hasWarned = false

    /// Warns if the data folder's volume has less than `lowSpaceBytes` free.
    static func checkFreeSpace(from controller: UIViewController) {
        guard let free = freeBytes(), free < lowSpaceBytes else { return }
        warn(from: controller)
    }

    /// A conversation could not be written; it is still in memory.
    static func saveFailed(_ error: Error, from controller: UIViewController) {
        if let free = freeBytes(), free < lowSpaceBytes {
            warn(from: controller)
        } else {
            warn(
                title: "Unable to Save Chats",
                message: String(localized: "\(error.readableMessage) Your chats keep working, and Apelin tries again with the next change."),
                from: controller,
            )
        }
    }

    /// Saving works again; the next failure is worth a notice.
    static func saveRecovered() {
        hasWarned = false
    }

    private static func warn(from controller: UIViewController) {
        warn(
            title: "Storage Almost Full",
            message: String(localized: "Your chats keep working, but Apelin can’t save them on this device until you free up space."),
            from: controller,
        )
    }

    private static func warn(title: String.LocalizationValue, message: String, from controller: UIViewController) {
        guard !hasWarned else { return }
        hasWarned = true
        var top = controller
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        top.presentNotice(title: title, message: message)
    }

    private static func freeBytes() -> Int64? {
        let values = try? DataFolder.app.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
