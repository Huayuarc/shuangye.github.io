// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import UIKit

extension ComposerInputView {
    protocol Delegate: AnyObject {
        func onComposerInputCameraButtonTapped()
        func onComposerInputMoreButtonTapped()
        func onComposerInputBeginEditing()
        func onComposerInputEndEditing()
        func onComposerInputSubmitButtonTapped()
        func onComposerInputPasteAsAttachmentTapped()
        func onComposerInputTextChanged(text: String)
        func onComposerInputPastingLargeTextAsDocument(content: String)
        func onComposerInputPastingImage(image: UIImage)
    }
}
