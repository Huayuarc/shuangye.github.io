import Litext
import UIKit

/// The text a step's page in the trace shows (`TraceStepController`): a
/// thought's text, a call by `ToolCallDetail` with each name set apart from
/// its value, or what an approval asked. A long call (a whole file written)
/// is decoded and laid out once for each text, size and width, not again on
/// every layout pass of the page.
@MainActor
enum TraceBody {
    struct Key: Hashable {
        /// The thought's text, the call's detail, or the approval's card text.
        let source: String
        /// A call's title, whose repeat as `reason` is left out; nil for
        /// plain text, a thought's or an approval's.
        let callTitle: String?
        let size: UIContentSizeCategory
    }

    private struct Measure: Hashable {
        let key: Key
        let width: CGFloat
    }

    private static var texts: [Key: NSAttributedString] = [:]
    private static var heights: [Measure: CGFloat] = [:]
    private static let sizing = TextLabelView()
    /// Past this many texts, or four times as many heights, the caches
    /// start again: a step that streams is a new text each time it grows,
    /// and a long one's text is the size of the file it wrote.
    private static let capacity = 64

    /// A step's key, or nil for a step with nothing to show.
    static func key(for message: ChatMessage) -> Key? {
        let size = UIApplication.shared.preferredContentSizeCategory
        switch message.role {
        case .thinking:
            return message.text.isEmpty ? nil : Key(source: message.text, callTitle: nil, size: size)
        case .approval:
            let detail = message.approvalDetail
            return detail.isEmpty ? nil : Key(source: detail, callTitle: nil, size: size)
        default:
            return message.detail.isEmpty ? nil : Key(source: message.detail, callTitle: message.text, size: size)
        }
    }

    static func text(for key: Key) -> NSAttributedString {
        if let text = texts[key] {
            return text
        }
        if texts.count >= capacity {
            texts.removeAll()
        }
        let text = build(key)
        texts[key] = text
        return text
    }

    /// The height the text takes at `width`, as a `TextLabelView` lays it out.
    static func height(for key: Key, width: CGFloat) -> CGFloat {
        let measure = Measure(key: key, width: width)
        if let height = heights[measure] {
            return height
        }
        if heights.count >= capacity * 4 {
            heights.removeAll()
        }
        sizing.attributedText = text(for: key)
        let height = ceil(sizing.sizeThatFits(CGSize(width: width, height: 0)).height)
        heights[measure] = height
        return height
    }

    private static func build(_ key: Key) -> NSAttributedString {
        let body: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor.label,
        ]
        guard let title = key.callTitle else {
            return NSAttributedString(string: key.source, attributes: body)
        }
        let footnote = UIFont.preferredFont(forTextStyle: .footnote)
        let name: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: footnote.pointSize, weight: .semibold),
            .foregroundColor: UIColor.secondaryLabel,
        ]
        let result = NSMutableAttributedString()
        for (index, section) in ToolCallDetail(detail: key.source, title: title).sections.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n\n", attributes: body))
            }
            if let label = section.name {
                result.append(NSAttributedString(string: label + "\n", attributes: name))
            }
            result.append(NSAttributedString(string: section.value, attributes: body))
        }
        return result
    }
}
