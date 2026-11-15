// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import UIKit

extension ComposerView {
    protocol Delegate: AnyObject {
        /// Send was asked for with `draft`, its text trimmed, not empty.
        /// The composer empties itself at once; call `completion` when the
        /// send is answered, either way: until then it takes no other Send.
        func onComposerSubmit(draft: ComposerDraft, completion: @escaping @MainActor () -> Void)
        /// What is typed changed, untrimmed: the conversation's draft.
        func onComposerUpdateDraft(_ draft: ComposerDraft)
        /// The text field took the keyboard.
        func onComposerBeginEditing()
        func onComposerCameraTapped()
        func onComposerPhotoTapped()
        func onComposerFileTapped()
        func onComposerWebTapped()
        func onComposerPreviewAttachment(_ attachment: ComposerAttachment)
        func onComposerPasteAsAttachmentTapped()
        /// A paste past `ComposerBehavior.longPasteThreshold`, kept out of
        /// the text.
        func onComposerPastedLongText(_ text: String)
        func onComposerPastedImage(_ image: UIImage)
        /// Items dropped on the composer, each with a file to read.
        func onComposerDropped(_ providers: [NSItemProvider])
    }
}
